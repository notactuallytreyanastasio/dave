---
description: Run the Temper test suite on interp then js (or the given backends) and explain failures
argument-hint: "[backend ...]  default: interp js"
allowed-tools: Bash(bin/temper:*), Bash(scripts/*), Read, Grep
---

# Test

Tests are `test("name") { ... }` blocks beside the code. Run them with
`bin/temper test`, one backend per invocation (`-b` is required):

```bash
bin/temper test -w "$PWD" -ign .temperignore -b interp   # Temper's own interpreter, fastest
bin/temper test -w "$PWD" -ign .temperignore -b js       # translated, run under node + mocha
```

Backends from $ARGUMENTS; default is `interp` then `js`. Run them one after
another, not in parallel: they share `temper.out/`.

## Reading the output

```
Test failed (js): deliberate failure shape - custom message
Tests passed: 2 of 3
Test failed
```

- `Test failed (<backend>): <test name> - <messages>`: one line per failing
  test; soft asserts mean several messages can be joined by `, `.
- The default assert message is `expected <expr> == (<actual>) not (<expected>)`.
- No `Tests passed:` line at all means the run never got to the tests:
  compile error, missing host toolchain, or a CLI crash. Read the log.

## When a backend disagrees with interp

That is the finding, not noise. Temper's promise is that every backend
behaves the same; a test that passes on interp and fails on py is either a
backend bug or a feature that backend lacks (async on lua, for example).
Write a minimal probe (`/temper-probe`), confirm it, and record it: in the
commit message, in MATRIX.md via `/temper-matrix`, and as an `observation`
node in the decision graph.

## Before a commit

`/temper-matrix` across every backend that runs on this machine. A change
is not done when it passes on interp.
