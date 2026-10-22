#!/usr/bin/env bash
# Build and test a small standalone Temper library on one or more backends,
# and show what came out. This is how a claim about Temper or a backend gets
# verified against the real thing instead of against the docs.
#
#   scripts/probe.sh <dir> [backend...]        # default backends: interp js
#   scripts/probe.sh <dir> js --show           # also print the generated js
#
# <dir> holds src/config.temper.md plus source files (a tiny library). The
# scratchpad is a good home for throwaway probes; keep a probe under probes/
# only when its finding is load-bearing for the project.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:?usage: scripts/probe.sh <dir> [backend...] [--show]}; shift
dir=$(cd "$dir" && pwd)
show=0
backends=()
for a in "$@"; do
  case "$a" in --show) show=1 ;; *) backends+=("$a") ;; esac
done
[ ${#backends[@]} -eq 0 ] && backends=(interp js)
[ -f "$dir/src/config.temper.md" ] || { echo "probe.sh: $dir/src/config.temper.md missing" >&2; exit 2; }
ign=$dir/.temperignore
[ -f "$ign" ] || printf 'temper.out/\n' > "$ign"

status=0
for b in "${backends[@]}"; do
  echo "=== $b"
  if [ "$b" = interp ]; then
    "$root/bin/temper" test -w "$dir" -ign "$ign" -b interp 2>&1 | grep -vE '^\s*$' || status=1
    continue
  fi
  "$root/bin/temper" build -w "$dir" -ign "$ign" -b "$b" 2>&1 | grep -vE '^\s*$'
  "$root/bin/temper" test -w "$dir" -ign "$ign" -b "$b" 2>&1 | grep -vE '^\s*$' || status=1
  if [ $show = 1 ]; then
    name=$(sed -nE 's/^\s*export let name = "([^"]+)";.*/\1/p' "$dir/src/config.temper.md" | head -1)
    echo "--- generated ($b):"
    find "$dir/temper.out/$b/$name" -type f \( -name '*.js' -o -name '*.py' -o -name '*.rs' -o -name '*.lua' -o -name '*.cs' -o -name '*.java' -o -name '*.ex' -o -name '*.blimp' \) \
      -not -name '*.map' -not -path '*test*' | while read -r f; do
      echo "----- ${f#"$dir"/}"; cat "$f"
    done
  fi
done
exit $status
