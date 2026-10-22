# C# backend: a test-only class that calls a test-only top-level function does not compile

Found 2026-10-21 with Temper 0.6.1-dev+498-gf911cadd. interp, js, py,
lua, rust and elixir pass; csharp fails to build the test project.

A top-level function that only tests call is placed with the tests
(`tests/ProbeTests.cs`, `internal static bool IsEven`). A class that only
tests use is emitted in its own file (`tests/Checker.cs`) and calls that
function by its bare name, `IsEven(...)`, with no `using static` and no
`ProbeTests.` qualifier, so `error CS0103: The name 'IsEven' does not
exist in the current context`. Library classes calling library functions
are qualified (`C::ChatGlobal.KeyStringOrSkip(...)`), so only the
test-only pair is affected.

Workaround: give the class its own private method instead of calling the
module function, or make the function a method of the class.

Run: `scripts/probe.sh probes/csharp-test-class-calls-test-function interp csharp`
