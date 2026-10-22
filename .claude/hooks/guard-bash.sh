#!/usr/bin/env bash
# PreToolUse hook for Bash.
#
# Refuses commands that this project forbids:
#   - broad git staging (git add -A / . / -a / *, git commit -a / -am)
#   - a bare `temper` (not on PATH; use bin/temper, which sets JAVA_HOME)
# Exit 2 + stderr blocks the call and tells the model why.
set -uo pipefail
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

if printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(add[[:space:]]+(-A|--all|-a|\.|\*)([[:space:]]|$)|commit[[:space:]]+(-a|-am|--all)([[:space:]]|$))'; then
  echo "Blocked: broad git staging. Stage files by name: git add src/x.temper.md .deciduous/graph.json" >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])temper[[:space:]]+(build|test|run|repl|watch|doc|init|version|help)' \
   && ! printf '%s' "$cmd" | grep -qE '(bin/temper|TEMPER=|cli/build/install)'; then
  echo "Blocked: bare 'temper' is not on PATH. Use bin/temper (it finds the CLI in ../temper and sets JAVA_HOME)." >&2
  exit 2
fi
exit 0
