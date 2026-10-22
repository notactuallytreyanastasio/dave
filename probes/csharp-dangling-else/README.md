# C# backend: an `if` as a `when` arm produces a dangling else

Filed as [temperlang/temper#629](https://github.com/temperlang/temper/issues/629); the polished repro is case `65-csharp-when-arm-dangling-else` in temper-issue-repros.

Found 2026-10-21 with Temper 0.6.1-dev+498-gf911cadd. interp, js, py, lua
and rust pass all four variants; csharp passes one.

    when (m) {
      is B -> if (m.flag) { out.add("b"); };
      is A -> void;
    }

translates (be-csharp) to

    if (m is B) if (((B) m).Flag) C::Listed.Add(out, "b");
    else if (!(m is A)) throw new S::Exception();

The `else` belongs to `if (Flag)`, not to `if (m is B)`, so a `B` whose
flag is false throws. Wrapping the arm in `do { ... }` or giving the inner
`if` an empty `else { void }` changes nothing: both are flattened to the
same two lines (`DoBlockArm`, `IfElseArm` in the generated
`tests/ProbeTests.cs`). What works is making the arm a call to a helper
that holds the `if` (`HelperArm`):

    if (m is B) AddIfFlag((B) m, out);
    else if (!(m is A)) throw new S::Exception();

Run: `scripts/probe.sh probes/csharp-dangling-else interp csharp`. Expect
4 of 4 on interp and 1 of 4 on csharp (the CLI prints only the first
failure; `temper.out/csharp/probe/tests/TestResults/TestResults.xml` has
all of them).
