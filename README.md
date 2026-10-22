# Dave

Building blocks for agents, bots and a classroom clock, written once in
[Temper](https://temperlang.dev) and translated to C#, Java, JavaScript,
Lua, Python, Rust and Elixir. One source, one test suite, seventy tests
green on the seven backends that run here:

| interp | js | py | lua | rust | csharp | elixir |
|---:|---:|---:|---:|---:|---:|---:|
| 70 of 70 | 70 of 70 | 70 of 70 | 70 of 70 | 70 of 70 | 70 of 70 | 70 of 70 |

Dave is a library, and it does no I/O. Anything that touches a socket, a
clock, a model API or a disk is an interface the host implements in its
own language and hands in. That is the whole reason one source can serve
seven languages, and it is also why the library is built as step
machines: the library says what to do next, the host does it and reports
back. Jam Pilot, a Phoenix app for school music lessons, runs the Elixir
translation in production for its model loops and the JavaScript one in
every browser for its clock.

## What is in it

| Module | What it is | Names to know |
|---|---|---|
| `src/chat/` | The OpenAI-style chat completions wire format, provider neutral: messages, tools, requests, responses, errors, a streaming assembler, a client over a host transport | `ChatRequest`, `ChatResponse`, `FunctionTool`, `ToolCall`, `Problems`, `Transport`, `ChatClient`, `StreamAssembler` |
| `src/rounds/` | The engine: ask a model, read the reply, let the host check it, send the problems back, N rounds; with tool turns inside a round | `RoundsAgent`, `Step` (`SendRequest`, `RunTools`, `Check`, `Done`, `GaveUp`), `Event`, `RoundsPolicy`, `Script`, `ReplyReader`, `ToolBucket` |
| `src/repair/` | Jam Pilot's score repair: find/replace edits to a document until a strict reader accepts it | `RepairSetup`, `RepairAgent`, `parseEdits`, `applyEdits`, `Guidance` |
| `src/compose/` | Jam Pilot's composer's assistant: a whole song as text, five rounds, a draft kept | `ComposeSetup`, `ComposeAgent`, `parseReply`, `SongWritten`, `NoSong` |
| `src/agent/` | A generic agent: a `Specialty` written in code plus the host's tool buckets | `Specialty`, `GenericAgent`, `PlainScript`, `PlainReader`, `plainPolicy` |
| `src/room/` | The classroom clock: a server clock, follower clocks that estimate their offset, the "1, 2, ready, play" count-in | `RoomClock`, `FollowerClock`, `ServerOffset`, `RoomTimeline`, `countInFor`, `countInNow` |

Every failure that a caller can handle records a JSON path and a reason
on a `Problems` object before it bubbles, because Temper's `Bubble`
carries no message:

```
request: messages: at least one message required
http: status 401: Incorrect API key provided (invalid_request_error, invalid_api_key)
$.choices[0].message.role: expected "assistant", got "user"
```

Impossible states panic. There is no plausible fallback anywhere in the
library: a reader that bubbles without saying why, a `CheckPassed` with no
`Check` outstanding, a tool result for a call that was never made, each
is a panic, because each is a bug in the caller and not a state to
recover from.

## The host contract

Two interfaces and one loop.

**`Transport`** is the network, one synchronous method: `send(HttpRequest):
HttpResponse`, bubbling only when no response was obtained at all. A 4xx
or 5xx is a response. `ChatClient` builds the request, sends it through
the transport and parses what comes back; `client.lastError` says why a
call failed. Synchronous on purpose: Lua has no async, and every host has
its own event loop to drive the library from outside.

**The step machine** is how a loop runs. The host asks `next(event)` and
performs the step it gets:

```temper
export sealed interface Step {}
// Post this to the model and report Responded or TransportFailed.
export class SendRequest(public request: ChatRequest) extends Step {}
// Run every tool and report ToolsRan with one result per run. A call that
// named no tool in any offered bucket is not here: the engine answered it.
export class RunTools(public runs: List<ToolRun>) extends Step {}
// Run the reader on the candidate's text and report CheckPassed or CheckRefused.
export class Check(public candidate: Candidate) extends Step {}
// The host's check passed: the loop is over, every round recorded.
export class Done(public candidate: Candidate, public attempts: List<Attempt>) extends Step {}
// The loop is over without a candidate that passed.
export class GaveUp(attempts, draft: Draft?, problems: List<String>, cause: String) extends Step {}
```

The events are `Start`, `Responded(response)`, `TransportFailed(why,
kind)`, `ToolsRan(results)`, `CheckPassed` and `CheckRefused(problems,
keep)`. Nothing in the library opens a socket, reads a clock or calls
back, so the same loop runs as an Elixir `Task`, a Python coroutine or a
blocking Lua loop, and a test drives it with a list of canned replies.

**The clock** follows the same rule from the other side: every method of
`RoomClock` and `FollowerClock` takes milliseconds from the host, and the
library never asks what time it is.

## Quickstart, in JavaScript

`bin/temper build -b js` writes `temper.out/js/{temper-core,std,dave}`.
This is a generic agent with one tool bucket, driven by a scripted model,
as run in Node against the built bundle:

```js
import { ChatResponse, Choice, Usage, AssistantMessage, ToolCall, FunctionTool, FinishReasons } from "dave/chat";
import { Start, Responded, CheckPassed, ToolsRan, SendRequest, Check, RunTools, Done, GaveUp, ToolBucket, ToolResult } from "dave/rounds";
import { Specialty, GenericAgent } from "dave/agent";
import { parseJson } from "@temperlang/std/json";

class Librarian extends Specialty {
  get name() { return "librarian" }
  get systemPrompt() { return "You find books. Use lookup; answer with the shelf mark." }
  get buckets() { return ["shelf"] }           // the host's catalogue has more; only these are offered
  opening(task) { return "Find: " + task }
}

const schema = parseJson('{"type":"object"}');
const catalogue = [
  new ToolBucket("shelf", [new FunctionTool("lookup", "Find a book by title", schema)]),
  new ToolBucket("kitchen", [new FunctionTool("boil", "Boil water", schema)]),
];
const agent = new GenericAgent("gpt-4o-mini", "the dragon book", new Librarian(), catalogue, 2);

let step = agent.next(new Start());
while (!(step instanceof Done) && !(step instanceof GaveUp)) {
  if (step instanceof SendRequest) {
    step = agent.next(new Responded(post(step.request)));          // the host's HTTP call
  } else if (step instanceof RunTools) {                            // one result per run, any order
    step = agent.next(new ToolsRan(step.runs.map(r => new ToolResult(r.call.id, lookup(r.call.arguments)))));
  } else if (step instanceof Check) {
    step = agent.next(new CheckPassed());                           // or CheckRefused([why])
  }
}
```

With a model that calls `boil` and `lookup` in its first turn, looks a
second title up, and then answers, the requests the host posted were:

```
SendRequest  system user                                      tools: lookup
RunTools     shelf:lookup {"title":"Compilers"}               (boil was answered by the engine)
SendRequest  system user assistant tool tool                  tools: lookup
RunTools     shelf:lookup {"title":"Dragons"}
SendRequest  system user assistant tool tool assistant tool user   tool_choice: none
Check        QA76.73
Done         round 1, 3 tool calls
```

The `tool` message the engine wrote for `boil` reads `There is no tool
named "boil". The tools are: lookup.` The last request carries
`tool_choice: "none"` and a user turn asking for the answer, because the
agent was given two tool turns per round. The same program in Python,
Rust, C# or Java is the same calls in that language's casing.

## The loops

**Rounds.** `RoundsAgent(model, systemPrompt, opening, policy, script,
reader, buckets = [], toolTurns = 8)`. What differs between loops is
plugged in and nothing else is: a `RoundsPolicy` (rounds, temperature,
max_tokens, the effort for round 1, for a retry and for the round after
a cut-off, whether a cut-off is retried, whether a refused draft is
kept), a `Script` (the turns the model hears and the sentences the
record keeps), and a `ReplyReader` (the reply as a `Proposal`, the
proposal as the text to check). A reply cut off at `max_tokens` is
recorded with how many tokens went to thinking and asked for again or
ends the loop, as the policy says. Every round leaves an `Attempt`:
round, summary, edits, error, how many tool calls it made.

**Tool turns.** A reply that calls tools is a `RunTools` step inside the
round. The model's turn goes into the conversation with its calls, the
host's results come back as tool messages in the calls' order, and the
model is asked again. After `toolTurns` such turns in one round the
tools are closed: the request carries `tool_choice: "none"` and the
script's `toolsExhaustedTurn`. A model that calls tools anyway has
failed the round, and the next round starts with the budget fresh. A
call to a tool in no offered bucket never reaches the host.

**Repair** (`RepairAgent(RepairSetup)`) is Jam Pilot's score repair: the
model proposes find/replace edits as JSON, the host applies its strict
reader, the refusal goes back, three rounds at most, a cut-off retried
once at low effort, a reviewer's note as a tie-breaker. `find` must
occur exactly once unless `occurrence` says which, because bars of a
score are often byte-identical. The turns are byte for byte what the
host sent before the engine existed.

**Compose** (`ComposeAgent(ComposeSetup)`) is the composer's assistant:
a teacher types a song as text and asks in plain words; the reply is a
`Summary:` line and the whole song in a fence; five rounds, round 1 at
`"low"` effort and `"medium"` from round 2; a cut-off ends the loop; the
last song that read is handed back as the draft when the rounds run
out, so the teacher keeps what the bot wrote. The effort schedule is a
measurement: at `"medium"` and 8,000 tokens the model thought through
all 8,000 and never answered.

**The generic agent** (`GenericAgent(model, task, specialty, catalogue,
toolTurns = 8)`) is the third loop and the first with tools. A
`Specialty` is an interface implemented in code: `name` and
`systemPrompt` are required; `buckets` (names), `opening(task)`,
`policy`, `script` and `reader` have defaults, so the smallest specialty
is two lines and reads the reply as the answer. A `ToolBucket` is a
named list of `FunctionTool`s the host can run. The host hands in its
whole catalogue; only the specialty's buckets are offered, and an agent
whose specialty names a bucket the catalogue lacks lists it in `missing`
and panics on `next`.

## The room

`RoomClock` is the server's: `play(nowMs, fromMs?, countInMs)`,
`pause(nowMs)` and `seek(nowMs, toMs)` take the host's monotonic time,
and `stateAt(nowMs, wallMs)` is the broadcast, a `ClockState(status,
positionMs, countInMs, at)`. A play can hold at the top of a bar for a
count-in. `FollowerClock` is a page's copy: it applies broadcasts
through a `ServerOffset` estimated from ping round trips (the five
fastest samples kept) and reports whether a broadcast changed the
status or jumped the position by more than 150 ms, so a page tells a
heartbeat from a transport event. `countInFor` and `countInNow` turn a
bar's real and full length into "1, 2, ready, play" and the word to show
with so much of the count left.

Before the port this arithmetic lived twice, in Elixir and in
JavaScript, and the day the count-in shipped the two copies disagreed:
the red line wobbled on every heartbeat. `room_test.temper` keeps that
case, and both sides now run the same source.

## The chat types

The wire format is the OpenAI one because every other provider speaks
it. Messages are a sealed type (`SystemMessage`, `UserMessage`,
`AssistantMessage`, `ToolMessage`); user content is a list of `TextPart`
and `ImagePart`; a `ToolCall` keeps the model's `arguments` as the JSON
text it produced, so a host can see invalid JSON. `ChatRequest` carries
the common fields plus an `extra` map merged into the top-level object as
given, which is how a host sends `reasoning_effort`. Absent and `null`
are the same thing on input; on output, unset optional fields are
omitted and an assistant message's `content` is always written.

`StreamAssembler` takes raw frames of a `stream: true` body, not lines,
because a socket read ends wherever it ends: the unfinished last line
waits for the next frame. `feed(frame)` returns the `ReasoningDelta`
and `ContentDelta` pieces the frame completed; `finish()` is the same
`ChatResponse` a whole reply gives, usage included. A data line that is
JSON but not a chunk this library reads bubbles with its path rather
than being skipped.

## Tests and the matrix

```
bin/temper test -b interp      # Temper's interpreter, the reference
bin/temper test -b js
scripts/matrix.sh              # every backend -> MATRIX.md
```

Seventy tests live beside the code (`src/*/*_test.temper`): exact JSON
bytes for a request with a tool round trip, OpenAI's documented
responses decoded, the path of every malformed input, the assembler fed
Fireworks-shaped frames split mid-line and with CRLF, the three-round
repair conversation and the `15673 of 16000` cut-off, the compose draft
kept after five refusals, the clock's wobble regression and the same
count-in word on a TV and an iPad 200 ms behind, and the librarian's
tool turns, unknown tool, closed tools, refused answer and missing
bucket. `MATRIX.md` has the per-backend numbers. The `java` backend does
not run on this machine (the CLI rejects Homebrew's JDK version string).

## Hosts

Jam Pilot (`../notedance_viewer`) vendors the generated code rather than
depending on a path across repositories, because its deploy rsyncs one
checkout to the box. `scripts/vendor-dave.sh` there copies
`temper.out/elixir/{temper-core,std,dave}` into `vendor/dave/` and
`temper.out/js/{temper-core,std,dave}` into `assets/vendor/temper/`, and
`VERSION` records the dave commit. Its hotfix and compose modules are
host loops of one function clause per step, matched on the Temper
class:

```elixir
defp drive(agent, %TemperCore.Ref{class: T.SendRequest} = step, check, client, rounds, effort) do
  case post(client, T.SendRequest.get_request(step)) do
    {:ok, response} -> drive(agent, T.RepairAgent.next(agent, T.Responded.new(response)), ...)
    {:error, why} -> drive(agent, T.RepairAgent.next(agent, T.TransportFailed.new(why, nil)), ...)
  end
end
```

The whole story of that port, with the host loops in full, the live runs
against the model and every place the output differs from the code it
replaced, is in [docs/jam-pilot-port.md](docs/jam-pilot-port.md). The
site, a page that runs the JavaScript translation in the browser with
scripted replies, is `docs/index.html`, served by GitHub Pages from the
`docs/` folder of `main`; `scripts/site.sh` rebuilds its bundle.

## What does not work yet

- Streamed tool calls. `StreamAssembler` bubbles on a delta with
  `tool_calls`; a host that streams a tool-using request gets a
  transport failure, not a silently dropped call.
- `stream: true` cannot be set from the library: `ChatRequest.extra` has
  no setter, so the host adds the flag to the wire JSON.
- Tool arguments are not checked against the tool's JSON Schema. The
  schema is carried, not interpreted; the host parses the arguments.
- An agent in flight is not data. A loop runs in one process from
  `Start` to `Done` and cannot be persisted or resumed.
- A `Specialty` is Temper code. The Elixir translation renders the
  interface as a module of default functions; whether an Elixir host can
  supply its own has not been tried.
- `logprobs`, `n > 1` beyond `choices[i]`, audio and file content parts.
- The `java` backend on this machine. The other seven run.
- One host program calls the generated libraries: Jam Pilot, on Elixir
  and (for the room) JavaScript. No Python, Rust, C#, Java or Lua host
  exists yet.

## Backend findings

Every claim about Temper in this repo was checked by running it, because
the docs lag the compiler. Findings that shaped the code, each with a
kept probe under `probes/` or a test:

- The C# backend turns an `if` used as a `when` arm into a dangling else
  (`csharp-dangling-else`, temperlang/temper#629); the Rust backend types
  `[new TextPart(x)]` as `Vec<TextPart>` where a `Vec<ContentPart>` is
  needed (#548); the JS backend drops a std function from the extracted
  test file when the test file re-imports it (`js-test-std-import`,
  #630); the C# backend emits a test-only class that cannot see
  test-only functions; a field named `finish` beside a method `finish()`
  reads as the method on interp and as the field on js and py.
- The Elixir backend puts every class of every module into one
  namespace, test helpers included, and the last definition wins. Two
  test files each declaring `class Run(...)` pass on six backends and
  fail on Elixir with `Run.new/3 is undefined`. Test helpers carry their
  module's name (`ComposeRun`, `AgentRun`).
- The Elixir backend emits only the full-arity constructor. A trailing
  default added to `Attempt` removed the five-argument form Jam Pilot
  called; host call sites pass every argument.
- Float64 division can bubble (division by zero), so a non-throwing
  function multiplies by `0.5` or writes `orelse panic()`; the Elixir
  CLI rejects a `for..of` that reassigns an outer variable, so the room
  uses indexed loops.

## Development

`CLAUDE.md` has the toolchain and the rules. `bin/temper` wraps the CLI
built from the sibling `../temper` checkout; `bin/temper-elixir` the one
from `../temper-elixir`. A hook builds for JavaScript after every edit of
a `.temper` file and hands the diagnostics back. `docs/api-we-wish-we-had.md`
is the roadmap.
