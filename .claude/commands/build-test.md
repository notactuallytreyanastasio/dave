---
description: Build the Temper library and run its tests on interp and js
allowed-tools: Bash(bin/temper:*), Bash(scripts/*), Read, Grep
---

# Build and test

```bash
bin/temper build -w "$PWD" -ign .temperignore -b js
bin/temper test  -w "$PWD" -ign .temperignore -b interp
bin/temper test  -w "$PWD" -ign .temperignore -b js
```

Then, for failures, say which test, what it checks, the likely cause and
the fix. For a backend-only failure, see `/temper-test`. For the whole
matrix before a commit, `/temper-matrix`.

$ARGUMENTS
