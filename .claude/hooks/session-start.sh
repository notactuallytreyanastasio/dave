#!/usr/bin/env bash
# SessionStart hook: one screen of toolchain state, so the first temper
# command of the session is not a surprise. stdout is added to context.
set -uo pipefail
root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$root" || exit 0

temper_home=${TEMPER_HOME:-$root/../temper}
echo "## Temper toolchain"
if [ -x bin/temper ]; then
  v=$(bin/temper version 2>&1 | head -1)
  echo "- bin/temper: $v"
else
  echo "- bin/temper missing"
fi
if [ -d "$temper_home/.git" ]; then
  head=$(git -C "$temper_home" rev-parse --short HEAD 2>/dev/null)
  echo "- ../temper HEAD: $head ($(git -C "$temper_home" log -1 --format=%ad --date=short 2>/dev/null))"
  case "${v:-}" in
    *"$head"*) ;;
    *) echo "- CLI is not built from HEAD; run /temper-upgrade if you need newer Temper" ;;
  esac
fi
avail=""
for t in node python3 cargo dotnet lua mvn; do command -v "$t" >/dev/null 2>&1 && avail="$avail $t"; done
echo "- host tools on PATH:${avail:- none}"
echo "- backends that pass tests here: interp js py lua rust csharp elixir (java needs a JDK whose version parses; see CLAUDE.md)"
if [ -f src/config.temper.md ]; then
  mods=$(grep -cE '^\s+import\("' src/config.temper.md 2>/dev/null || echo 0)
  echo "- library: src/config.temper.md, $mods module import(s); $(find src -name '*.temper*' | wc -l | tr -d ' ') source files"
fi
exit 0
