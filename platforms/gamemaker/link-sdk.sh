#!/usr/bin/env bash
# Wire a GameMaker project to this SDK checkout.
#
# The two .gml wrappers and the extension binaries are LINKED (not copied),
# so an SDK change lands in the project without a sync step. Colyseus_SDK.yy
# is GENERATED from the SDK's own copy, retargeted at the project: it
# declares the native bindings the .gml calls, and a committed copy goes
# stale the first time the SDK adds one. A project that copies both files by
# hand ends up with a .gml/.yy pair from different revisions, which is a
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
#   scripts/Colyseus/Colyseus.gml
#   scripts/ColyseusPredict/ColyseusPredict.gml
#   extensions/Colyseus_SDK/{Colyseus_SDK.yy,libcolyseus.dylib,colyseus_wasm.js}
# (the two script .yy files are tiny and project-specific: commit those.)
set -euo pipefail

SDK="$(cd "$(dirname "$0")" && pwd)"
BP="$SDK/example/BlankProject"
EXT_SRC="$BP/extensions/Colyseus_SDK/Colyseus_SDK.yy"

MODE=link
CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy)  MODE=copy; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -eq 2 ]] || { echo "usage: $0 [--copy|--check] <project-dir> <Project.yyp>" >&2; exit 64; }
DIR="$(cd "$1" && pwd)"
YYP="$2"
PROJECT="${YYP%.yyp}"
[[ -f "$DIR/$YYP" ]] || { echo "[link-sdk] error: $DIR/$YYP not found" >&2; exit 1; }

log() { echo "[link-sdk] $*"; }
die() { echo "[link-sdk] error: $*" >&2; exit 1; }

# --- the host binary: prefer a fresh `zig build`, fall back to the example's --
case "$(uname -s)" in
  Darwin) NATIVE=libcolyseus.dylib; ARCH=$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)
          CANDIDATES=("$SDK/zig-out/lib/macos/$ARCH/$NATIVE" "$BP/extensions/Colyseus_SDK/$NATIVE") ;;
  Linux)  NATIVE=libcolyseus.so
          CANDIDATES=("$SDK/zig-out/lib/linux/x64/$NATIVE" "$BP/extensions/Colyseus_SDK/$NATIVE") ;;
  *)      NATIVE=colyseus.dll
          CANDIDATES=("$SDK/zig-out/lib/windows/x64/$NATIVE" "$BP/extensions/Colyseus_SDK/$NATIVE") ;;
esac
DYLIB=""
for c in "${CANDIDATES[@]}"; do [[ -f "$c" ]] && { DYLIB="$c"; break; }; done
[[ -n "$DYLIB" ]] || die "no $NATIVE; run 'zig build' in $SDK"

WASM=""
for c in "$SDK/wasm-out/colyseus_wasm.js" "$BP/extensions/Colyseus_SDK/colyseus_wasm.js"; do
  [[ -f "$c" ]] && { WASM="$c"; break; }
done
[[ -n "$WASM" ]] || die "no colyseus_wasm.js; run './build-wasm.sh' in $SDK"

SCRIPTS=(Colyseus ColyseusPredict)
EXT_OUT="$DIR/extensions/Colyseus_SDK/Colyseus_SDK.yy"

strip_commas() { perl -0777 -pe '1 while s/,(\s*[\]\}])/$1/g' "$1"; }

# --- --check: every artefact must exist, resolve, and match this checkout --
if (( CHECK )); then
  rc=0
  ok()   { echo "  ok      $1"; }
  bad()  { echo "  $1"; rc=1; }
  for s in "${SCRIPTS[@]}"; do
    f="scripts/$s/$s.gml"
    if [[ ! -e "$DIR/$f" ]]; then bad "MISSING $f"
    elif ! cmp -s "$DIR/$f" "$BP/$f"; then bad "STALE   $f (differs from $BP/$f)"
    else ok "$f"; fi
  done
  for f in "extensions/Colyseus_SDK/$NATIVE" extensions/Colyseus_SDK/colyseus_wasm.js; do
    if [[ -e "$DIR/$f" ]]; then ok "$f"; else bad "MISSING $f"; fi
  done
  if [[ ! -e "$EXT_OUT" ]]; then
    bad "MISSING extensions/Colyseus_SDK/Colyseus_SDK.yy"
  else
    want=$(strip_commas "$EXT_SRC" | jq -c '[.files[0].functions[] | [.name, .argCount, .returnType]]')
    have=$(strip_commas "$EXT_OUT" | jq -c '[.files[0].functions[] | [.name, .argCount, .returnType]]')
    parent=$(strip_commas "$EXT_OUT" | jq -r '.parent.path')
    if [[ "$want" != "$have" ]]; then bad "STALE   extensions/Colyseus_SDK/Colyseus_SDK.yy (bindings differ from $EXT_SRC)"
    elif [[ "$parent" != "$YYP" ]]; then bad "WRONG   extensions/Colyseus_SDK/Colyseus_SDK.yy parent is $parent, want $YYP"
    else ok "extensions/Colyseus_SDK/Colyseus_SDK.yy ($(echo "$have" | jq length) bindings)"; fi
  fi
  (( rc == 0 )) || die "run $0 $DIR $YYP"
  log "all SDK artefacts resolve and match $SDK"
  exit 0
fi

place() {  # place <src> <dest-relative>
  local src="$1" dst="$DIR/$2"
  mkdir -p "$(dirname "$dst")"
  rm -f "$dst"
  if [[ "$MODE" == "copy" ]]; then cp "$src" "$dst"; else ln -s "$src" "$dst"; fi
}

log "mode: $MODE  project: $DIR ($YYP)"
for s in "${SCRIPTS[@]}"; do place "$BP/scripts/$s/$s.gml" "scripts/$s/$s.gml"; done
place "$DYLIB" "extensions/Colyseus_SDK/$NATIVE"
place "$WASM"  extensions/Colyseus_SDK/colyseus_wasm.js
log "  gml    <- $BP/scripts/{Colyseus,ColyseusPredict}"
log "  native <- $DYLIB"
log "  wasm   <- $WASM"

# The script .yy resources only carry the parent; write them if missing so a
# fresh project gets a complete resource.
for s in "${SCRIPTS[@]}"; do
  yy="$DIR/scripts/$s/$s.yy"
  [[ -f "$yy" ]] && continue
  strip_commas "$BP/scripts/$s/$s.yy" \
    | jq --arg name "$PROJECT" --arg path "$YYP" '.parent = {name: $name, path: $path}' > "$yy"
  log "  wrote  scripts/$s/$s.yy"
done

# --- the extension manifest, retargeted at this project ---------------------
# files[0] must name the host binary: GameMaker loads only the FIRST kind:1
# entry and ignores copyToTargets at runtime. Every entry carries the full
# function list (an entry with an empty list binds nothing).
command -v jq >/dev/null || die "jq is required to generate Colyseus_SDK.yy"
strip_commas "$EXT_SRC" \
  | jq --arg name "$PROJECT" --arg path "$YYP" --arg native "$NATIVE" '
      .parent = {name: $name, path: $path}
      | .files[0].filename = $native
      | .files[0].ProxyFiles = []
      | .files[0].functions as $fns
      | .files |= map(if (.functions | length) == 0 then .functions = $fns else . end)' \
  > "$EXT_OUT"
log "  ext.yy generated from $EXT_SRC ($(strip_commas "$EXT_OUT" | jq '.files[0].functions | length') bindings)"
log "done"
