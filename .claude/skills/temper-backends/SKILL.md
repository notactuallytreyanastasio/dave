---
name: temper-backends
description: What each Temper backend (js, py, rust, csharp, java, lua, interp) produces, how to run and consume the output, naming conventions, and per-backend limits. Load when designing a public API, reading temper.out, or explaining a backend-only failure.
---

# Backends

`bin/temper build -b <id>` writes `temper.out/<id>/<library>/` plus
`temper.out/<id>/std/` and `temper-core`. Never edit it. Each backend also
knows how to run the translated tests: `bin/temper test -b <id>`.

| id | targets | output | tests via | runs here |
|---|---|---|---|---|
| `interp` | Temper's own interpreter | none | built in | yes, fastest, the reference |
| `js` | ES2018, Node 14+, TS types in JSDoc | `dave.js` + `.map`, `package.json` | mocha (`npm test`) | yes (~5s) |
| `py` | Python 3.11+, mypy types | `dave/dave.py`, `pyproject.toml` | pytest | yes |
| `mypyc` | py compiled with mypyc | same | pytest | untried |
| `rust` | Rust 1.71+ | `src/mod.rs`, `Cargo.toml` | cargo test | yes (~6s) |
| `csharp` | .NET 6+ | `src/Dave.csproj`, `Dave/DaveGlobal.cs` | MSTest | yes (~7s) |
| `elixir` | Elixir 1.15+, OTP; from the `../temper-elixir` checkout via `bin/temper-elixir` | `lib/temper_main.ex`, `mix.exs` | ExUnit | yes (~6s) |
| `java` | JDK 17+ (`java8` for 8) | `pom.xml`, `src/main/java/dave/dave/DaveGlobal.java` | JUnit via mvn | **no**: CLI rejects JDK version "21.0.12.1" |
| `lua` | Lua 5.1 (5.4 ok) | `dave.lua`, rockspec | busted-style | yes |
| `cpp`, `blimp` | C++, Blimp | | | untried here |
| `data` | writes `dataFile` outputs only | | | |

Timing is for a two-test library; the first run of a backend installs
its deps (npm, cargo registry) and is slower.

## Name mapping

| Temper | js | py | rust | csharp | java | lua |
|---|---|---|---|---|---|---|
| `greetingFor()` | `greetingFor` | `greeting_for` | `greeting_for` | `GreetingFor` | `greetingFor` | `greetingFor` |
| top-level fns/lets | module exports | module level | module fns | static class `DaveGlobal` | `DaveGlobal` | module table |
| `class P(public a: Int)` | class, ctor | class | struct + `P::new(a)` | class | class + `Builder` | ctor fn |
| `interface I` | class usable with `instanceof`, `implementedBy` | ABC | trait object | `II` | interface | table |
| `fn (Int): Int` | function | callable | closure | `Func<int,int>` (`Action` for Void, max 16 params) | functional interface | function |
| `List<T>` / `Listed<T>` | `Array` | `tuple`/`Sequence` | `Vec` behind `Rc` | `IReadOnlyList<T>` | `List<T>` | table |
| `ListBuilder<T>` | `Array` | `list` | `Vec` | `IList<T>` | `List<T>` | table |
| `Map<K,V>` | `Map` | `dict` | map | `IReadOnlyDictionary` | `Map` | table |
| `Int` | `number` | `int` | `i32` | `int` | `int` | number |
| `Int64` | `bigint` | `int` | `i64` | `long` | `long` | custom on 5.1 |
| `Float64` | `number` | `float` | `f64` | `double` | `double` | number |
| `T?` | `T \| null` | `Optional[T]` | `Option<T>` | nullable | boxed | nil |
| `Void` | `undefined` | `None` | `()` | `void` | `void` | nil |
| Bubble | throw | raise | `Result` | throw | throw | error |
| `console.log` | console | `logging` | | `ILogger`/`Trace` | | print |

Parameters sometimes carry a `__3` suffix in py/rust output; that is a
known wart, not something to work around in Temper.

## Backend bugs found here (each has a probe)

- **csharp**: an `if` as the body of a sealed `when` arm is emitted
  unbraced, so the `else throw` that closes the `when` binds to the inner
  `if`; the common case throws `System.Exception`. `do { if }` and an
  empty `else { void }` are flattened to the same thing. Move the `if`
  into a helper and make the arm a call: `is X -> checkX(x, out);`.
  `probes/csharp-dangling-else`, upstream #629.
- **rust**: `[new Sub(x)]` where a `List<Super>` is expected becomes
  `Vec<Sub>` and rustc rejects it (E0308). Build such lists through a
  `ListBuilder<Super>`. The other backends accept the literal.
- **csharp**: a class that only tests use is emitted in its own file and
  calls a test-only top-level function by its bare name (`CS0103`). Give
  such a class private methods instead. `probes/csharp-test-class-calls-test-function`.
- A top-level function that only tests call is filed with the tests on
  every backend, even if it sits in a library file; "library code" means
  "reachable from an export".
- The CLI prints only the first failing test per backend; the full list is
  in `temper.out/<backend>/<lib>/tests/TestResults/` (csharp) or the
  framework's own report.

## Per-backend limits that shape designs

- **js**: `Int` and `Float64` are both `number`; `is Int` cannot
  distinguish them (`@mayDowncastTo(false)`). `Int64` is `bigint`.
- **lua**: no async/await, no generators (functional matrix row
  ControlFlowAsync is ❌ on lua). Regex engine misses some anchored
  optional patterns. 5.1 has no 64-bit ints.
- **rust**: reference cycles leak, hence Temper's no-cycle rule;
  everything shared is `Rc`. Generated crates warn a lot:
  `RUSTFLAGS=--cap-lints=allow`.
- **py**: `int` is unbounded, so `Int` overflow wraps only in Temper code,
  not in host code that does its own arithmetic.
- **csharp**: `Func`/`Action` cap at 16 parameters.
- **java**: JUnit + Maven; `mvn install` to consume locally.
- **all**: `String` index integers differ (bytes / UTF-16 units / code
  points); only Temper's `StringIndex` API is portable.

## Consuming output from a host

- js: `npm install ../dave/temper.out/js/dave/`; `import { x } from "dave"`; ESM only.
- py: `poetry add --editable temper.out/py/dave/` (or `pip install -e`); `from dave import x`.
- rust: `cargo add dave --path temper.out/rust/dave`.
- csharp: `dotnet add reference temper.out/csharp/dave/src/Dave.csproj`.
- java: `cd temper.out/java/dave && mvn install`, then `implementation 'dave:dave:0.1.0'`.
- lua: `LUA_PATH=temper.out/lua/?.lua;temper.out/lua/?/init.lua`.

Library naming per backend is set in `src/config.temper.md`:
`csharpRootNamespace`, `javaName`, `javaPackage`, `jsName`, `pyName`,
`rustName` (`luaName` has no effect yet).

## REPL tricks

`bin/temper repl` then `translate(<n>, "py")` shows the translation of
input `n`; `describe(<n>, "frontend.generateCodeStage.after")` shows
inferred types. `bin/temper repl -b js` opens node with the library
loaded. The REPL is interactive; prefer `/temper-translate` from a
session.

## When a backend disagrees

interp is the reference semantics. A test green on interp and red on one
backend is a translation bug or a backend limit. Find which with a probe
(`scripts/probe.sh <dir> <backend> --show`), read the generated file, and
record it: commit message, MATRIX.md, and an `observation` node. The
functional matrix at `../temper/functional-test-matrix.md` lists upstream's
known gaps per backend with issue numbers.
