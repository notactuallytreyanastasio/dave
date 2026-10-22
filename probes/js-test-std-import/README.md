# JS backend: a std function re-imported in a test file is dropped from the extracted tests

Filed as [temperlang/temper#630](https://github.com/temperlang/temper/issues/630); the polished repro is case `66-js-test-reimports-std-function` in temper-issue-repros.

Found 2026-10-21 with Temper 0.6.1-dev+498-gf911cadd. interp and py pass
both modules; js passes `once` and fails `reimport`.

Two modules with the same library file (`lib.temper` imports and uses
`parseJson`) and a test file that calls `parseJson`:

- `src/reimport/lib_test.temper` also writes `let { parseJson } = import("std/json");`
- `src/once/lib_test.temper` has no import and uses the module's binding

When the js backend extracts the tests into `test/<module>.js`, the
`reimport` test file comes out with no import of `parseJson` at all (the
other std names survive), so the call is a `ReferenceError`. It is caught
by the `try { } catch { panic() }` the backend wraps bubbling calls in,
so the test reports a bubble, not the real error:

    import { JsonObject as JsonObject_208 } from "@temperlang/std/json";
    ...
    t = parseJson('{"a":1}');   // ReferenceError: parseJson is not defined

The `once` test file comes out with `parseJson as parseJson_0` imported.

Rule for this repo: a test file in a module that already imports a std
name does not import it again.

Run: `scripts/probe.sh probes/js-test-std-import interp js py`. Expect
2 of 2 on interp and py, 1 of 2 on js.
