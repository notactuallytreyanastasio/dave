---
name: temper-lang
description: Temper language reference for writing or reviewing .temper / .temper.md code - syntax, types, classes, interfaces, Bubble, strings, collections, modules, decorators, std library, and the gotchas verified by probe. Load before writing any Temper.
---

# Temper, as it actually behaves

Temper (https://temperlang.dev, source in `../temper`) is a language for
writing a library once and translating it to C#, Java, JS, Lua, Python and
Rust (plus cpp, blimp, elixir backends in sibling checkouts). The compiler
does global analysis so each backend can emit idiomatic code. Everything
below was checked against `bin/temper version` 0.6.1-dev+498 unless marked.

Where to look things up, in order of trust:

1. A probe: `/temper-probe`. The docs lag the compiler.
2. Builtins reference: `../temper/docs/for-users/temper-docs/docs/reference/builtins.md` (macros, decorators, operators)
3. Types reference: `.../reference/types.md` (every method on String, List, Map...)
4. Tutorial: `.../tutorial/0*.md`; std sources: `../temper/frontend/src/commonMain/resources/std/*/`
5. Working code: `../temper-growthbook/src/` (a real SDK on 7 backends), `../temper/functional-test-suite/src/commonMain/resources/`

## Files and modules

- `.temper` is plain source. `.temper.md` is Markdown where indented or
  ```` ```temper ```` blocks are code and prose is comment. Prefer `.temper.md`
  for modules with something to explain; `.temper` for pure code.
- A *directory* is a module; all files in it merge. File names are
  irrelevant except `config.temper.md`, which marks a library root and
  exports `name`, `version`, `license`, and `import("./x")` lines.
- `let { a, b } = import("./dir");` imports a sibling module (directory
  path, never a file). `import("std/json")` for the standard library.
  `let { ... } = import(...)` (wildcard) only for std.
- Only `export`ed declarations cross module boundaries.
- Statements end with `;`. A `}` at end of line ends a statement, so
  `} else {` must share a line. The last expression of a block without a
  trailing `;` is the block's value.

## Declarations

```temper
let x = 1;                      // immutable (once per scope entry)
var n = 0; n += 1; n++;         // mutable
let f(a: Int, b: String = "x"): Int { a }        // function; last expr returns
let g = fn (a: Int): Int { a + 1 };               // same, anonymous
let h<T>(items: Listed<T>): List<T> { items.toList() }   // generic
let { width, height as h } = box;                 // destructure (no nesting)
```

Function types: `fn (Int): Int`, `fn (): Void`, `fn<T> (T): List<T>`,
`fn (...Int): Boolean`. Optional params come last.

Block lambdas as trailing args: `xs.map { (x): Int => x * 2 }`,
`xs.forEach { x => ... }`, `f(a) { (x, y): R => ... }`. Return type must be
stated unless inferable from the callee. `fn (x) {}` and `{ (x) => }` are
the same thing.

## Types

| Type | Notes |
|---|---|
| `Int` (= `Int32`) | wraps on overflow; `Int64` with literal `1i64`; no mixing: `i.toFloat64()`, `f.toInt32()` (throws Bubble on NaN/overflow), `toInt32Unsafe` |
| `Float64` | literals need a dot: `1.0`; `Float64.pi`, `NaN`, `Infinity`; `.floor() .round() .sqrt()` ... |
| `Boolean` | `&&`, `\|\|`, `!`; no truthiness, `if (1)` is an error |
| `String` | immutable, iterated by code point, see below |
| `T?` | nullable; `null`; `x ?? d`; `x?.m`; `x as T` throws Bubble if null |
| `Void` | result must be ignored |
| `Bubble` | failure, see below |
| `Never`, `AnyValue`, `Top` | rarely written |

`x is T` tests type and narrows `x` in the `&&` right side and in `when`
arms. `if (x != null) { use(x) }` and `if (x == null) {} else { use(x) }`
narrow **locals and parameters only**, never class properties: copy
`this.p` to a local first. An early exit does not narrow what follows
(`if (x == null) { bubble() } use(x)` is an error); put the use in the
`else`. `f() orelse null` needs a declared type: `let v: T? = f() orelse null;`
because `orelse` otherwise takes the left side's non-null type.

## Classes and interfaces

```temper
export interface Shape {
  area(): Float64;                       // abstract
  describe(): String { "area ${area()}" }  // default method
}
export class Rect(
  public width: Float64,                 // constructor params are the fields
  public var height: Float64,            // mutable field
  public label: String = "rect",         // default
) extends Shape {
  public area(): Float64 { width * height }
  public get diagonal(): Float64 { ... } // getter, used without ()
  public static let unit = new Rect(1.0, 1.0);
  private helper(): Void {}
}
new Rect(1.0, 2.0);  { width: 1.0, height: 2.0 }  { class: Rect, width: 1.0, height: 2.0 }
```

- Classes extend interfaces only; **a class cannot extend a class**.
  Interfaces extend interfaces. Multiple: `extends A & B`.
- `sealed interface S {}`: subtypes must be in the same file; `when` over
  it needs no `else`; backends translate to sum types.
- Custom `constructor(...) { this.x = ...; }` is allowed.
- `==` on your classes needs `@auto("==")` on the class (or a manual
  `@operator("==")` method). Built-ins compare by value.
- `enum` exists but its translation is flagged broken (issue #859); use a
  sealed interface with empty classes, or string constants.
- No reference cycles, ever (Rust/C++ count references). No parent
  pointers; pass context down, or keep nodes in a List and use indices.
- Property bags `{ a: 1, b: 2 }` are the only named-argument form and
  pick the constructor by field names; add `class:` when ambiguous.

## Control flow

```temper
if (c) { a } else if (d) { b } else { e }        // an expression
when (x) { 1 -> "one"; 0, 2 -> "few"; is Circle -> x.radius; else -> "?" }
for (var i = 0; i < n; i += 1) { ... }           // C-style
for (let item of items) { ... }                  // sugar for forEach; break/continue ok
while (c) { ... }   do { ... } while (c);
outer: while (true) { break outer; }
do { stmt; stmt; value }                          // block expression
```

## Failure: Bubble, orelse, panic

- A function that can fail says so: `let parse(s: String): Int throws Bubble`.
  `bubble()` fails. Callers recover with `expr orelse fallback`, or let it
  propagate if they also `throws Bubble`. `do { ... } orelse x` wraps blocks.
- Bubble carries **no message**. For diagnostics, pass a collector object
  (growthbook's `Diagnostics`) or return a result class.
- `panic()` is unrecoverable in Temper (may be catchable by the host).
  Use it for impossible states, never as a fallback.
- `xs[i]` out of range panics; `map[k]` missing key bubbles; use
  `getOr(k, d)`.
- Backend mapping: exceptions in Java/C#/Python/JS, `Result` in Rust.

## Strings

No `.length`, no integer indexing. Positions are opaque `StringIndex`:

```temper
var i = String.begin;
while (s.hasIndex(i)) { let cp = s[i]; i = s.next(i); }
s.countBetween(String.begin, s.end)   // code points
s.slice(a, b)   s.split(",")   s.indexOf("x", String.begin)   s.isEmpty
s.toInt32(10)  s.toFloat64()   // throw Bubble
String.fromCodePoint(65)   char'A' == 65
```

- Interpolation in every string: `"x=${x}"` calls `.toString()`.
- `raw"\d+"` keeps backslashes. `"""` starts a multi-line string where
  each content line begins with `"` (newline kept), `~` (no newline) or
  `:` (Temper code).
- `StringBuilder`: `append`, `appendCodePoint`, `toString`.
- `xs.join(", ") { it => it.toString() }` takes the stringifier as a block.
- Backends differ in what the index integer means (bytes in Rust, UTF-16
  units in JS/Java/C#, code points in Python); never do arithmetic on it.

## Collections

- `List<T>` immutable (covariant), `ListBuilder<T>` mutable, `Listed<T>`
  the read-only view both implement. Take `Listed<T>`, return `List<T>`.
- `[1, 2, 3]` is a `List`. Build: `let b = new ListBuilder<Int>(); b.add(x); b.toList()`.
- Listed methods: `length isEmpty get getOr slice map filter reduce
  reduceFrom join sorted toList toListBuilder forEach`. ListBuilder adds
  `add addAll set removeLast reverse sort splice clear`. `xs[i] = v` is
  `set`.
- `Map<K,V>` / `MapBuilder<K,V>` / `Mapped<K,V>`; keys are `String` or
  `Int` only. `new Map([new Pair(k, v)])`; `b[k] = v`; `m[k]` bubbles,
  `m.getOr(k, d)`; `has keys values toList forEach { k, v => }`.
  Insertion order is kept on every backend.
- `Pair<K,V>` (`key`, `value`), `Deque<T>`, `DenseBitVector`.
- `map`/`filter` do not propagate Bubble from the lambda; `for..of` does.
  Use a loop and a `ListBuilder` when the body can fail.
- `==` between two Lists does not compile; compare `xs.join("|") { it => it }`.
- `assert(a == b)` without a message block needs `toString` on both sides;
  for a class without one, or a nullable class, give the `{ "msg" }` block.

## Decorators you will use

| | |
|---|---|
| `@json class X(...) {}` | generates `X.jsonAdapter()` with `encodeToJson(x, p)` / `decodeFromJson(tree, ic)`. Field names become keys. Generated decoders **require every key present** (even for `T?`); write your own `encodeToJson(p: JsonProducer): Void` and `static decodeFromJson(t, ic): X throws Bubble` on the class to control that. Unknown keys are ignored. |
| `@jsonName("tool_calls")` | wire name for a field |
| `@jsonExtra("type", "text")` | discriminator for a `@json sealed interface`; decoders dispatch on it, encoders write it after the fields |
| `@auto("==")` | structural equality |
| `@extension("isBlank") let f(s: String)` | callable as `s.isBlank()` |
| `@overload("append")` | several methods under one host-facing name |
| `@operator("+")` | operator on your type |
| `@connected` | implemented natively per backend (std only) |

## Standard library (`import("std/...")`)

- **json**: `parseJson(text): JsonSyntaxTree throws Bubble`; tree classes
  `JsonObject(properties: Map<String, List<JsonSyntaxTree>>)` with
  `propertyValueOrNull(k)` / `propertyValueOrBubble(k)`, `JsonArray(elements)`,
  `JsonString(content)`, `JsonBoolean`, `JsonNull`, `JsonNumeric` with
  `asInt32() asInt64() asFloat64()`. `JsonTextProducer` writes:
  `startObject objectKey(k) stringValue int32Value float64Value booleanValue
  nullValue startArray endArray endObject`, then `toJsonString()` (throws
  Bubble). Adapters: `X.jsonAdapter()`, `listJsonAdapter(a)` (must be
  imported for `List.jsonAdapter` to resolve), `OrNullJsonAdapter(a)`,
  `int32JsonAdapter()` etc. `NullInterchangeContext.instance` as the context.
- **regex**: literals `/a(?name=.)c/` (named groups only, `(?name=...)`),
  `rgx"..${escaped}.."`; `re.find(s)` returns groups by name: `["name"].value`;
  structured tree (`Sequence`, `CodePoints`, `Capture`, `Repeat`, `Dot`)
  `.compiled()`. Lua's engine misses some `^`/`$` cases (growthbook MATRIX).
- **temporal**: `Date(year, month, day)`, ISO parse/format, `yearsBetween`.
- **net**: `new NetRequest(url).post(body, mime)`; `.send(): Promise<NetResponse>`
  (`status`, `contentType`, `bodyContent: Promise<String?>`); no headers,
  so not usable for authenticated APIs. Hosts supply transports.
- **testing**: `Test` with soft `assert`, `assertHard`; see temper-testing.

## Async and generators

`Promise<T>`, `await p` inside `async { (): GeneratorResult<Empty> extends GeneratorFn => ... }`;
`yield` in a block lambda `extends GeneratorFn` makes a coroutine. Works
on every backend except **lua**. Keep core logic synchronous and let hosts
drive async; growthbook's core has no async and runs everywhere.

## Logging

`console.log(...)` goes to the host's logger (Python `logging`, .NET
`ILogger`, ...). It is for debugging and tests, never library output.

## Diagnostics you will see

```
2: x + 1.5
       ┗━┛
[-work/src/f.temper:2+6-9]@G: Actual arguments do not match signature: (Int32, Int32) -> Int32 ...
```

`line+startCol-endCol`; `@G` generate stage, `@S` syntax, `@R` run.
"No member length in String" means use StringIndex. "Cannot bubble from a
function without Bubble in its return type" means add `throws Bubble` or
`orelse`. "Expected subtype of String, but got String?" means narrow via a
local or `as`. A failed build still emits code and tests may still run;
treat `Build failed` as the verdict.
