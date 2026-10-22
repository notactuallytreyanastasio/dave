---
description: Run tests on every backend available here and write MATRIX.md
argument-hint: "[backend ...]  default: interp js py lua rust csharp java"
allowed-tools: Bash(scripts/matrix.sh:*), Bash(bin/temper:*), Read
---

# Test matrix

```bash
scripts/matrix.sh $ARGUMENTS
```

Runs `bin/temper test -b <backend>` for each backend in turn, logs to
`build/matrix/<backend>.log`, and writes `MATRIX.md` with one row per
backend: passed/total, wall time, and the failing test names.

Backends known to run on this machine: `interp js py lua rust csharp`.
`java` needs a JDK whose `java -version` the CLI can parse (three-part
versions parse, `21.0.12.1` does not); see CLAUDE.md.

## Report

Show the table. For any row that is not all-pass:

- `no run`: the backend never reached the tests. Quote the reason line from
  the log and say whether it is a missing host tool or a Temper problem.
- failures: name each failing test and the backend(s). A test failing on
  exactly one backend is a translation bug or an unsupported feature on
  that backend; say which you believe and why.

MATRIX.md is a generated file, but it is committed, so stage it with the
change that moved the numbers.
