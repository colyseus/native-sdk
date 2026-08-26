#!/usr/bin/env bash
# Wire a GameMaker project to this SDK checkout.
#
# The wrapper .gml scripts and the extension binaries are LINKED (not
# copied), so an SDK change lands in the project without a sync step.
# Colyseus_SDK.yy is GENERATED from the SDK's copy, retargeted at the
# project: it declares the native bindings the .gml calls, and a committed
# copy goes stale the first time the SDK adds one. A project that copies both
# by hand ends up with a .gml/.yy pair from different revisions, which is a
# compile error on the next binding.
#
# Usage:
#   link-sdk.sh <project-dir> <Project.yyp>          link (default)
#   link-sdk.sh --copy <project-dir> <Project.yyp>   copy instead (for a
#                                                    toolchain that refuses
#                                                    to follow symlinks)
#   link-sdk.sh --check <project-dir> <Project.yyp>  verify: every artefact
#                                                    resolves and matches
#                                                    this checkout; exit 1
#                                                    if not
#
# Links point into this checkout, so gitignore them in the project:
#   scripts/<Script>/<Script>.gml for each script gen-bindings lists
#   extensions/Colyseus_SDK/{Colyseus_SDK.yy,<native>,colyseus_wasm.js}
# (the script .yy files are tiny and project-specific: commit those.)
set -euo pipefail

SDK="$(cd "$(dirname "$0")" && pwd)"
BP="$SDK/example/BlankProject"
GEN="$SDK/gen-bindings.mjs"
EXT=extensions/Colyseus_SDK

MODE=link
CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy)  MODE=copy; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -eq 2 ]] || { echo "usage: $0 [--copy|--check] <project-dir> <Project.yyp>" >&2; exit 64; }
DIR="$(cd "$1" && pwd)"
YYP="$2"

log() { echo "[link-sdk] $*"; }
die() { echo "[link-sdk] error: $*" >&2; exit 1; }
[[ -f "$DIR/$YYP" ]] || die "$DIR/$YYP not found"
command -v node >/dev/null || die "node is required (gen-bindings.mjs writes the .yy)"

first_existing() { for c in "$@"; do [[ -f "$c" ]] && { echo "$c"; return; }; done; return 1; }

# the host binary: prefer a fresh `zig build`, fall back to the example's
case "$(uname -s)" in
  Darwin) NATIVE=libcolyseus.dylib; PLAT="macos/$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)" ;;
  Linux)  NATIVE=libcolyseus.so;    PLAT=linux/x64 ;;
  *)      NATIVE=colyseus.dll;      PLAT=windows/x64 ;;
esac
DYLIB=$(first_existing "$SDK/zig-out/lib/$PLAT/$NATIVE" "$BP/$EXT/$NATIVE") \
  || die "no $NATIVE; run 'zig build' in $SDK"
WASM=$(first_existing "$SDK/wasm-out/colyseus_wasm.js" "$BP/$EXT/colyseus_wasm.js") \
  || die "no colyseus_wasm.js; run './build-wasm.sh' in $SDK"
SCRIPTS=($(node "$GEN" --list-scripts))

if (( CHECK )); then
  rc=0
  for s in "${SCRIPTS[@]}"; do
    f="scripts/$s/$s.gml"
    if [[ ! -e "$DIR/$f" ]]; then echo "  MISSING $f"; rc=1
    elif ! cmp -s "$DIR/$f" "$BP/$f"; then echo "  STALE   $f"; rc=1
    else echo "  ok      $f"; fi
  done
  for f in "$EXT/$NATIVE" "$EXT/colyseus_wasm.js"; do
    if [[ -e "$DIR/$f" ]]; then echo "  ok      $f"; else echo "  MISSING $f"; rc=1; fi
  done
  # the manifest is a pure function of the SDK's copy: regenerate and compare
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  node "$GEN" emit-yy "$tmp" "$YYP" "$NATIVE" >/dev/null
  if [[ ! -e "$DIR/$EXT/Colyseus_SDK.yy" ]]; then echo "  MISSING $EXT/Colyseus_SDK.yy"; rc=1
  elif ! cmp -s "$DIR/$EXT/Colyseus_SDK.yy" "$tmp/$EXT/Colyseus_SDK.yy"; then echo "  STALE   $EXT/Colyseus_SDK.yy"; rc=1
  else echo "  ok      $EXT/Colyseus_SDK.yy"; fi
  (( rc == 0 )) || die "run $0 $DIR $YYP"
  log "all SDK artefacts resolve and match $SDK"
  exit 0
fi

place() {  # place <src> <dest-relative>
  local src="$1" dst="$DIR/$2"
  mkdir -p "$(dirname "$dst")"
  rm -f "$dst"
  if [[ "$MODE" == copy ]]; then cp "$src" "$dst"; else ln -s "$src" "$dst"; fi
}

log "mode: $MODE  project: $DIR ($YYP)"
for s in "${SCRIPTS[@]}"; do place "$BP/scripts/$s/$s.gml" "scripts/$s/$s.gml"; done
place "$DYLIB" "$EXT/$NATIVE"
place "$WASM"  "$EXT/colyseus_wasm.js"
log "  gml    <- $BP/scripts/{$(IFS=,; echo "${SCRIPTS[*]}")}"
log "  native <- $DYLIB"
log "  wasm   <- $WASM"
node "$GEN" emit-yy "$DIR" "$YYP" "$NATIVE" | sed 's/^/[link-sdk]   /'
log "done"
