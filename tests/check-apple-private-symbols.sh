#!/bin/bash
# Fail if an Apple binary references private libSystem functions, which App
# Store review flags by reading the import table, reachable or not.
#
#   tests/check-apple-private-symbols.sh <binary|archive|bundle-dir>...
#
# Directories (frameworks, xcframeworks, zig-out/lib) are searched for Mach-O
# files and archives.
set -euo pipefail

# Zig std's futex. Only its default panic handler reaches it, so http.zig
# replaces that handler on Apple targets.
PRIVATE='^_+ulock_'

[ "$#" -gt 0 ] || { echo "usage: check-apple-private-symbols.sh <binary|archive|bundle-dir>..." >&2; exit 2; }

files=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    while IFS= read -r f; do
      if file -b "$f" | grep -qE 'Mach-O|ar archive'; then files+=("$f"); fi
    done < <(find "$arg" -type f)
  elif [ -f "$arg" ]; then
    files+=("$arg")
  else
    echo "error: $arg does not exist" >&2
    exit 2
  fi
done
[ "${#files[@]}" -gt 0 ] || { echo "error: no Mach-O files under $*" >&2; exit 2; }

failed=0
for f in "${files[@]}"; do
  hits="$(nm -A -u "$f" 2>/dev/null | awk -v re="$PRIVATE" '$NF ~ re { print "  " $0 }' | sort -u)"
  if [ -n "$hits" ]; then
    echo "FAIL  $f references private symbols:"
    echo "$hits"
    failed=1
  fi
done

[ "$failed" -eq 0 ] && echo "PASS  no private symbols in ${#files[@]} Apple binaries"
exit "$failed"
