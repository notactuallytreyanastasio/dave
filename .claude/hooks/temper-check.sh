#!/usr/bin/env bash
# PostToolUse hook for Edit|Write|MultiEdit.
#
# After a Temper source file changes, build the library on the js backend
# (the fastest full pipeline: ~3s) and feed compile errors back to the model.
# Exit 2 + stderr is how a PostToolUse hook talks to Claude; the edit itself
# has already happened, so this is feedback, not a block.
#
# DAVE_NO_CHECK=1 disables it (for bulk edits that are mid-refactor).
set -uo pipefail
[ "${DAVE_NO_CHECK:-}" = "1" ] && exit 0

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -n "$path" ] || exit 0
case "$path" in
  *.temper|*.temper.md) ;;
  *) exit 0 ;;
esac
case "$path" in
  */temper.out/*|*/probes/*) exit 0 ;;
esac

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -x "$root/bin/temper" ] || exit 0
[ -f "$root/src/config.temper.md" ] || exit 0

log=$(mktemp)
trap 'rm -f "$log"' EXIT
if ( cd "$root" && timeout 180 bin/temper build -b js -w "$root" -ign "$root/.temperignore" ) >"$log" 2>&1; then
  exit 0
fi

{
  echo "temper build -b js failed after editing ${path#"$root"/}:"
  # Keep the diagnostics: source line, caret art, [file:line+col]: message.
  grep -vE '^\s*$' "$log" | grep -vE '^(Build failed|\s+at )' | head -60
  echo "Fix these before moving on, or run /temper-build for the full log."
} >&2
exit 2
