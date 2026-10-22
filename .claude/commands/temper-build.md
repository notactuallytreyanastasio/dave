---
description: Build the Temper library for one or more backends and report compile errors by file
argument-hint: "[backend ...]  e.g. js py rust (default: js)"
allowed-tools: Bash(bin/temper:*), Bash(scripts/*), Read, Grep
---

# Build

Build the library under `src/` with `bin/temper` (never bare `temper`).

Backends from $ARGUMENTS, default `js` (fastest full pipeline, ~3s). Pass
each as its own `-b`:

```bash
bin/temper build -w "$PWD" -ign .temperignore -b js -b py
```

Valid backends: `csharp java java8 js lua py mypyc rust cpp data blimp`.
No `-b` at all means the default seven (csharp data java js lua py rust).

## Reading the output

A diagnostic looks like this, source line first, then the position:

```
2: x + 1.5
       ┗━┛
[-work/src/broken.temper:2+6-9]@G: Actual arguments do not match signature ...
```

`2+6-9` is line 2, columns 6 to 9. `@G` marks the stage (G = generate code,
S = syntax, R = run). `Build failed` ends a failed run. A clean build prints
nothing.

For machine reading: `--logformat json` emits one record per line with a
`template` name (`SignatureInputMismatch`, `BecauseNameUndeclared`, ...).

## Then

1. Group errors by file, fix the Temper source, rebuild. Never edit anything
   under `temper.out/`; the next build overwrites it.
2. If an error is in a backend's own tool (cargo, dotnet, mvn...), the
   Temper frontend accepted the code and the translation is what broke.
   Say so explicitly: that is a backend bug or an unsupported feature, and
   the generated file under `temper.out/<backend>/dave/` shows which.
3. Log an `action`/`outcome` pair in the decision graph when the build is
   part of a change the user asked for.
