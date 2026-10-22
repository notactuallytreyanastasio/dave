---
description: Show how a Temper snippet translates to a backend's source, to check the output is idiomatic
argument-hint: "<backend> <snippet or src path>"
allowed-tools: Bash(scripts/probe.sh:*), Bash(bin/temper:*), Bash(find:*), Bash(cat:*), Read, Write
---

# Translate

Temper's point is idiomatic output in each language. When you design an
API (a class, an interface, a callback type, an optional parameter), look
at what each host user will actually see before committing to it.

For the project library, build and read the generated file:

```bash
bin/temper build -w "$PWD" -ign .temperignore -b <backend>
find temper.out/<backend>/dave -type f -not -name '*.map' | head
```

For a snippet, put it in a probe library and use `--show`:

```bash
scripts/probe.sh <dir> <backend> --show
```

Name mapping to expect:

| Temper | js | py | rust | csharp | java | lua |
|---|---|---|---|---|---|---|
| `greetingFor` | `greetingFor` | `greeting_for` | `greeting_for` | `GreetingFor` | `greetingFor` | `greetingFor` |
| `class Person(public name: String)` | class + ctor | dataclass-like | struct + `new` | class + Builder? | class + Builder | table ctor |
| `interface Shape` | class usable with `instanceof` | ABC | trait object `Shape` | `IShape` | interface | table |
| `List<T>` | `Array` | `tuple`/`Sequence` | `Vec` (Rc) | `IReadOnlyList<T>` | `List<T>` | table |
| `Int64` | `bigint` | `int` | `i64` | `long` | `long` | custom on 5.1 |
| top-level fns | module exports | module fns | module fns | `DaveGlobal` static class | `DaveGlobal` | module table |

Say what looks awkward for a host user (a `__3` suffix on a parameter name,
an `Any` type, a Builder with 12 fields) and whether a different Temper
shape would translate better.

$ARGUMENTS
