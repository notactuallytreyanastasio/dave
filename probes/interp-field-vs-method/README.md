# interp: a field and a method with the same name

Found 2026-10-21 with Temper 0.6.1-dev+498-gf911cadd while writing
`StreamAssembler` (src/chat/stream.temper), whose field `finish` held the
stream's finish_reason and whose method `finish()` built the response.
Every test that called `finish()` failed on interp with no message; js and
py passed all of them.

    export class Clash {
      private var finish: String? = null;
      public set(v: String): Void { finish = v; }
      public finish(): String { finish ?? "none" }
    }

The frontend accepts this without a diagnostic. On js and py the bare
`finish` inside the method is the field and the test passes; on interp it
is not, and `c.finish()` after `c.set("stop")` does not return "stop".
Renaming the field (`NoClash`, `finishSeen`) passes everywhere.

Run: `scripts/probe.sh probes/interp-field-vs-method interp js py`.
Expect 1 of 2 on interp, 2 of 2 on js and py.

Rule for this project: never give a field the name of a method on the
same class, even when the compiler lets you.
