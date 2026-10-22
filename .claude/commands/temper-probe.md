---
description: Verify a claim about Temper or a backend by running a minimal library, not by reading docs
argument-hint: "<what to check> [backend ...]"
allowed-tools: Bash(scripts/probe.sh:*), Bash(bin/temper:*), Bash(mkdir:*), Bash(cat:*), Write, Read
---

# Probe

A probe is a tiny standalone Temper library that answers one question by
running: "does `when` without `else` compile on a sealed interface?",
"what does `Int64` become in js?", "does py preserve map insertion order?".
Write it, run it on interp and on the backend in question, and report the
real output. Never answer such a question from memory or from the docs
alone; the docs lag the compiler (they still say for...of is planned).

## Steps

1. Make a directory in the scratchpad (or `probes/<slug>/` if the finding
   will matter later) with `src/config.temper.md`:

   ```markdown
   # probe
       export let name = "probe";
   ```

   and a source file `src/probe.temper` holding the question as code,
   with `test(...)` blocks or `console.log` lines that show the answer.

2. Run it:

   ```bash
   scripts/probe.sh <dir> interp js        # test on each backend
   scripts/probe.sh <dir> py --show        # also print the generated python
   ```

3. Report: the question, the Temper source (short), the output per backend,
   and the conclusion in one sentence. Where backends disagree, say which
   one is wrong relative to Temper's semantics (interp is the reference).

4. If the finding changes what we build, log it as an `observation` in the
   decision graph and put the probe output in the relevant commit message.

Question to probe: $ARGUMENTS
