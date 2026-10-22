---
description: Add a new module directory to the library and wire it into config.temper.md
argument-hint: "<module-name> [one-line purpose]"
allowed-tools: Bash(mkdir:*), Bash(bin/temper:*), Edit, Write, Read
---

# New module

A module is a directory under `src/`. All `.temper` and `.temper.md` files
in it merge into one module; file names do not matter. Only `export`ed
names are visible to other modules, which import the directory:

```temper
let { Thing, makeThing } = import("./things");   // directory, not file
```

## Steps for module `$ARGUMENTS`

1. `mkdir src/<name>` and write `src/<name>/<name>.temper.md`, starting
   with a heading, one paragraph on what the module is for, then code
   blocks. Put at least one `test(...)` in it.

2. Add `import("./<name>");` to the Modules section of
   `src/config.temper.md`. (A module that another module imports is
   included anyway; listing it in config keeps the library's shape readable
   and keeps a module that nothing imports yet from silently vanishing.)

3. `bin/temper build -b js` and `bin/temper test -b interp`.

4. Log the action and outcome in the decision graph under the goal the
   module serves.

## Rules

- No reference cycles between objects (Temper will reject them; Rust and
  C++ backends count references). No parent pointers; pass context down.
- Hosts do I/O. A module that needs the network, a clock, storage or a
  model API declares an `interface` the host implements and takes an
  instance; it does not call out itself. (`std/net` exists but is the
  exception, not the pattern.)
- Prefer `Listed<T>` parameters and `List<T>` results; `ListBuilder` only
  inside a function.
