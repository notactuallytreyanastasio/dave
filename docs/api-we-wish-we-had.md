# The API we wish we had

A toolkit, written once in Temper, that a Python eval team, a TypeScript
front end, a Rust service, a C# or Java product, or a Lua plugin can use
to plug in a chatbot, an agent, or inference at whatever depth they need.
This sheet is the target. `src/chat/` is rung 0, `src/chat/stream.temper`
is rung 1, and `src/rounds/` with its two loops (`src/repair/`,
`src/compose/`) is rung 4 as it turned out to be needed, which is not
quite as it was sketched. The sketches that have been replaced by code
are shown below as the code, with what the sketch got wrong.

The stance that makes it possible in Temper, and that every row below
follows:

- **The core does no I/O and never calls back into the host.** It is a
  set of pure functions and a step machine: the host hands it a response
  or a tool result, it hands back the next thing to do. That is what lets
  one source run on six backends, including Lua with no async and Rust
  with no garbage collector.
- **The host supplies four things in its own language**: a way to send an
  HTTP request, a way to run a tool, a clock, and (for streaming) a way to
  read the body. Everything else is translated.
- **State is data.** An agent in flight is a value that encodes to JSON,
  so it can be logged, persisted, resumed in another process, and replayed
  by an eval. There is no object graph the host must keep alive. (Not yet
  true of `RoundsAgent`; see rung 4.)
- **Failure carries a path and a reason.** `Problems` is the one error
  channel; `Bubble` signals, `Problems` explains.

## The ladder

Each rung is one more thing the host plugs in. A host can stop at any
rung; the rungs above it are optional modules.

| Rung | What the host wants | Host writes | Core provides | Today |
|---|---|---|---|---|
| 0. One call | "ask the model this, get the answer" | `Transport.send` | `ChatRequest`, `ChatResponse`, `ChatClient.complete`, `Problems` | done, `src/chat/` |
| 1. Streaming | tokens as they arrive | a body reader that hands over each frame | `StreamAssembler.feed(frame)` → `ReasoningDelta`/`ContentDelta`; `finish()` → the same `ChatResponse` as a whole reply | done, `src/chat/stream.temper`; tool-call deltas bubble |
| 2. Conversation | a chatbot with memory and a system prompt | nothing new | `Conversation`: history, budget, `request()`, `absorb()` | not started; `RoundsAgent` keeps its own history |
| 3. Tools | the model can call the host's functions | `ToolRunner.run(call)` | `ToolSpec`, `ArgReader`, `ToolResult`, tool-message plumbing | types done, runner and reader not |
| 4. Agent | run until the goal is met or a limit hits | a loop in the host's idiom, one clause per `Step` | `RoundsAgent.next(event) -> Step`, `RoundsPolicy`, `Script`, `ReplyReader`, `List<Attempt>` | done for the ask-check-retry shape, `src/rounds/`; two loops run on it in production |
| 5. Interactive | pause for a human, cancel, resume, hand off | drive `Step.AskUser` / `Event.UserSaid`; persist `AgentState` | same step machine, state encodes to JSON | partial: a reviewer's note and the attempts she rejected go in as `Guidance`; no resume |
| 6. Evals | score any rung's transcript identically everywhere | nothing | `Scorer`s over `Transcript`; exact match, regex, JSON Schema, structured output | goal logged, not started |

"Interactive inference of varying degrees" is rungs 0 to 5 read as a
dial: the same `ChatRequest` and the same `Transcript` at every setting,
so moving a product from a one-shot call to a tool-using agent changes
what the host loops over, not what it logs or how it is scored.

## The core, as Temper

Rungs 1 and 4 are real signatures copied from `src/`; the rest are
sketches. Names follow `src/chat/`. Everything is synchronous and takes or
returns plain data.

### Providers (rung 0, missing piece)

Neutrality is a profile, not a flag per call.

```temper
export class ProviderProfile(
  public baseUrl: String,
  public authHeader: String = "Authorization",      // "x-api-key" for some
  public authPrefix: String = "Bearer ",
  public maxTokensKey: String = "max_tokens",        // "max_completion_tokens" on newer OpenAI
  public supportsToolChoice: Boolean = true,
  public supportsJsonSchema: Boolean = true,
  public supportsParallelTools: Boolean = true,
) {}
export let openAi(): ProviderProfile { ... }
export let openAiCompatible(baseUrl: String): ProviderProfile { ... }   // Ollama, vLLM, Groq, Together
```

`ChatClient` takes a profile and rewrites a request to fit it (drops or
renames what the provider lacks, and says so in `Problems` as warnings,
never silently). Retries are a decision the core makes from `status` and
`Retry-After`; the host sleeps, because the host owns time:

```temper
export sealed interface Retry {}
export class RetryAfter(public millis: Int) extends Retry {}
export class GiveUp(public why: String) extends Retry {}
export let retryDecision(attempt: Int, response: HttpResponse, policy: RetryPolicy): Retry
```

### Streaming (rung 1, real)

The host reads the body however its language reads bodies and hands each
piece over as it arrives; the core does the line splitting, the parsing
and the accumulation. From `src/chat/stream.temper`:

```temper
// One piece of the reply as it arrived, for a host that shows the model
// thinking. ContentDelta text is what `finish` joins into the answer.
export sealed interface Delta {
  public get text(): String;
}
export class ReasoningDelta(public text: String) extends Delta {}
export class ContentDelta(public text: String) extends Delta {}
```

```temper
  // One frame of the stream. Returns the deltas it completed, in order,
  // empty strings skipped. Bubbles when a data line is JSON that is not a
  // chunk this library can read (a delta with tool_calls, a usage object
  // with a string where a number belongs, an {"error": ...} object); the
  // reason is in `lastError` and the frame's lines up to the bad one are
  // already applied.
  public feed(chunk: String): List<Delta> throws Bubble {
```

```temper
  // The reply as one ChatResponse. Content is null when no content delta
  // arrived, which is what RepairAgent reads as "cut off before any
  // answer"; a cut-off with partial content keeps the content and
  // finish_reason "length", like a whole reply would.
  public finish(): ChatResponse {
```

The getters are `contentSoFar`, `hasContent`, `finishReason`, `usage`,
`pending` (the partial line waiting for the next frame), `lastProblems`
and `lastError`. The sketch this replaced read:

```temper
export class StreamAssembler(public problems: Problems) {
  public feedLine(line: String): List<Delta>;        // "data: {...}" or "data: [DONE]" or blank
  public get response(): ChatResponse? throws Bubble; // assembled once [DONE] has been seen
}
export sealed interface Delta {}
export class TextDelta(public text: String) extends Delta {}
export class ToolCallDelta(public index: Int, public id: String?, public name: String?, public arguments: String) extends Delta {}
export class FinishDelta(public reason: String) extends Delta {}
export class UsageDelta(public usage: Usage) extends Delta {}
```

What it got wrong, each found by running the real thing:

- The seam is a frame, not a line. `Req` (and `fetch`, and `reqwest`)
  hand over whatever the socket read, which ends in the middle of a line
  as often as not; making the host split lines means every host writes
  the same buffer. `feed(chunk)` keeps the unfinished line in `pending`.
  The scripted test hands a frame over as two halves split at character
  20 to prove it.
- There is a `reasoning_content` delta, and a host wants it: Jam Pilot
  shows the model thinking. The sketch had no row for it. Finish and
  usage are not deltas a host acts on as they arrive; they are getters
  read once at `finish()`.
- Tool-call deltas are not assembled. The sketch promised to concatenate
  `arguments` fragments by index; nobody has needed it, so a delta with
  `tool_calls` bubbles (`streamed tool calls are not assembled yet`)
  rather than carrying a half-built type.
- The assembler owns its `Problems`. A constructor argument made every
  host allocate one; `lastError` is what the host reads after a bubble.
- `finish()` returns a `ChatResponse`, not `ChatResponse?`. Whether the
  stream was complete is the host's knowledge (it saw the status and the
  end of the body); an assembler that returns null after `[DONE]` was
  never seen would make the host check two things. The result is the
  same object `parseChatResponse` builds, so a streaming host and a
  non-streaming one feed the loop the same `Responded`.
- A malformed chunk is a problem, not a skipped line. Jam Pilot's
  `parse_sse` ignored any data line it could not use, which hid an
  `{"error": "overloaded"}` object mid-stream as an empty reply. Now it
  is `$.error: overloaded (server_error)` in `lastError` and the round
  ends as a transport failure.
- The `stream: true` flag cannot be set from the library: `ChatRequest.extra`
  is a `Map` with no setter, so the host puts it on the wire JSON. A
  `ChatRequest.streaming()` or a `stream` field on the request is the
  missing piece.

### Conversation (rung 2)

```temper
export class Conversation(
  public system: String?,
  public model: String,
  public budget: TokenBudget? = null,      // host supplies a TokenCounter; core trims
) {
  public user(text: String): Void;
  public user(parts: List<ContentPart>): Void;
  public request(options: RequestOptions = ...): ChatRequest;   // history + system + options
  public absorb(response: ChatResponse): AssistantMessage;      // appends the reply, records usage
  public get history(): List<Message>;
  public get transcript(): Transcript;
}
export interface TokenCounter { public count(messages: List<Message>): Int; }
```

Trimming is a policy object (`keepSystem`, `keepLastN`, `summarizeWith`
is the host's business), never an implicit behaviour. `RoundsAgent`
carries its own `ListBuilder<Message>` and `history` getter in the
meantime; when this rung exists the engine should hold a `Conversation`.

### Tools (rung 3)

```temper
export class ToolSpec(
  public tool: FunctionTool,                  // name, description, JSON Schema
  public timeoutMillis: Int? = null,
  public requiresConfirmation: Boolean = false,
) {}
export interface ToolRunner {
  public run(call: ToolCall, args: ArgReader): ToolResult throws Bubble;
}
export class ToolResult(public callId: String, public content: String, public isError: Boolean = false) {}

// Typed access to a call's arguments, with the same path+reason errors as decoding.
export class ArgReader(public call: ToolCall, public problems: Problems) {
  public string(key: String): String throws Bubble;
  public stringOrNull(key: String): String? throws Bubble;
  public int(key: String): Int throws Bubble;
  public float(key: String): Float64 throws Bubble;
  public boolean(key: String): Boolean throws Bubble;
  public list(key: String): List<JsonSyntaxTree> throws Bubble;
  public obj(key: String): ArgReader throws Bubble;
  public validateAgainst(schema: JsonSyntaxTree): List<String>;   // the same checker evals use
}
```

The core validates arguments against the tool's schema *before* the host
runs anything, and turns a malformed call into a `ToolMessage` the model
can read, instead of a crash in the host.

### Agent (rung 4, real; rung 5 partial)

The centrepiece. The host never hands the core a callback; it asks for
the next step and reports what happened. From `src/rounds/steps.temper`:

```temper
export sealed interface Step {}
// Post this to the model and report Responded or TransportFailed.
export class SendRequest(public request: ChatRequest) extends Step {}
// Run the reader on the candidate's text and report CheckPassed or CheckRefused.
export class Check(public candidate: Candidate) extends Step {}
// The host's check passed: the loop is over, every round recorded.
export class Done(public candidate: Candidate, public attempts: List<Attempt>) extends Step {}
// The loop is over without a candidate that passed. `problems` are the last
// refusal's (or the one sentence of the cut-off or transport failure that
// ended it); `cause` is one of GiveUpCauses.
export class GaveUp(
  public attempts: List<Attempt>,
  public draft: Draft?,
  public problems: List<String>,
  public cause: String,
) extends Step {}
```

```temper
export sealed interface Event {}
export class Start extends Event {}
export class Responded(public response: ChatResponse) extends Event {}
// No reply at all. `kind` says what `why` is, one of TransportFailures, so
// the loop's script can word it for the person.
export class TransportFailed(public why: String, public kind: String = TransportFailures.sentence) extends Event {}
```

```temper
export class CheckPassed extends Event {}
// The host's check refused the candidate with these sentences. `keep`: the
// candidate may still be handed back as the draft if nothing better comes
// (false for one the person must never see, whatever its problems).
export class CheckRefused(public problems: List<String>, public keep: Boolean = true) extends Event {}
```

And from `src/rounds/agent.temper`, the three things a loop plugs in and
the engine they plug into:

```temper
export class RoundsPolicy(
  public rounds: Int,
  public temperature: Float64,
  public maxTokens: Int,
  // sent as `reasoning_effort` on round 1; null leaves it out
  public effort: String?,
  // on a round after a reply that was refused (by the reader or the host)
  public retryEffort: String?,
  // on the round after a cut-off, when one is retried
  public cutOffEffort: String?,
  // a reply cut off at max_tokens: asked for again with script.cutOffTurn,
  // or the end of the loop with the cut-off sentence
  public retryCutOff: Boolean,
  // the last candidate the host refused but said to keep is handed back in GaveUp
  public keepDraft: Boolean,
) {}
```

```temper
export interface Script {
  // after a reply the reader could not read or realise; `problems` are its sentences
  unreadableTurn(problems: List<String>): String;
  // after a candidate the host's check refused, with its sentences
  refusedTurn(problems: List<String>): String;
  // after a reply cut off at max_tokens, when the policy retries one; `why` is the cut-off record
  cutOffTurn(why: String): String;
  // what the attempt records for a cut-off reply
  cutOffRecord(reasoningTokens: Int?, maxTokens: Int, beforeAnyAnswer: Boolean): String;
  // what the attempt records when the reader could not read the reply
  unreadableRecord(problems: List<String>): String { problems.join(" ") { it => it } }
  // what the attempt records when the host refused the candidate
  refusedRecord(problems: List<String>): String { problems.join(" ") { it => it } }
  // what the attempt records (and GaveUp.problems carries) for a transport failure
  transportRecord(why: String, kind: String): String { why }
}
```

```temper
export interface ReplyReader {
  // What the reply proposes. Bubbles, with the sentence for the model noted
  // on `problems`, when the reply is not one.
  read(reply: String, problems: Problems): Proposal throws Bubble;
  // The text the host checks. A proposal that carries its text is that
  // text; one made of edits is realised here, bubbling with the sentence on
  // `problems` when it cannot be (an edit that does not place).
  realize(proposal: Proposal, problems: Problems): String throws Bubble { proposal.text ?? panic() }
}
```

```temper
export class RoundsAgent(
  public model: String,
  public systemPrompt: String,
  // the first user turn, built by the loop's setup
  public opening: String,
  public policy: RoundsPolicy,
  public script: Script,
  public reader: ReplyReader,
) {
```

The whole loop in the host is a `while` over `next`. Because `Step` is a
sealed type, each language gets an exhaustive `match`/`switch`/`when`,
and because nothing is held by reference across the boundary, the same
loop works as a blocking loop, an `async` loop, an actor, or a coroutine.
The sketch this replaced read:

```temper
export sealed interface Step {}
export class SendRequest(public request: ChatRequest) extends Step {}
export class RunTools(public calls: List<ToolCall>, public parallel: Boolean) extends Step {}
export class AskUser(public prompt: String?) extends Step {}          // model asked, or policy requires confirmation
export class Finished(public answer: AssistantMessage, public transcript: Transcript) extends Step {}
export class Failed(public problems: List<String>, public transcript: Transcript) extends Step {}

export class AgentPolicy(
  public maxSteps: Int = 20,
  public maxTokens: Int? = null,
  public stopOnToolError: Boolean = false,
  public confirmTools: List<String> = [],
) {}

@json export class AgentState(...) {}   // conversation, pending calls, step count, usage so far

export class Agent(public conversation: Conversation, public tools: List<ToolSpec>, public policy: AgentPolicy) {
  public next(event: Event): Step;       // pure: consumes the event, advances state, returns what to do
  public get state(): AgentState;        // encode to JSON to persist; new Agent(state) to resume
  public get transcript(): Transcript;
}
```

What it got wrong, measured against the two loops that had to run on it:

- The host's tool is a verdict on a candidate, not a list of calls. Both
  Jam Pilot loops have exactly one tool, a validator the model never
  calls by name: the host runs it on every reply and the result is
  `CheckPassed` or `CheckRefused(sentences, keep)`. `RunTools` with
  `ToolCall`s is the model-driven shape and nothing built yet needs it;
  it belongs to rung 3 when that is built, as a second `Step`.
- The words are the agent's. The sketch's `Failed(problems)` left open
  who turns a refusal into the sentence a person reads and the turn the
  model hears; in practice that was where the host's 500 lines went, and
  it is what has to be the same in every language. So a loop is a
  `Script`: `refusedTurn`, `cutOffTurn`, `cutOffRecord`,
  `transportRecord(why, kind)`, and the compose loop's `outcome(step)`
  gives the teacher `SongWritten` or `NoSong(sentence)`. The host adds
  nothing but log lines.
- The policy is about effort and cut-offs, not step counts. `maxSteps`
  and `stopOnToolError` never came up; `reasoning_effort` for round 1,
  for a retry and for the round after a cut-off, whether a cut-off is
  asked for again, and whether a refused candidate is handed back as a
  draft are what the two loops differ on (table below). Those are the
  fields of `RoundsPolicy`.
- The reply is read by the loop, not the engine. A `ReplyReader` turns
  the text into a `Proposal` (edits, or the text itself) and `realize`s
  it into the candidate; the repair loop's reader applies edits to the
  original document, the compose loop's reader is two regexes written
  out by hand. The engine never sees JSON or fences.
- There is no `AgentState`. `RoundsAgent` is an object with
  `ListBuilder` fields; on Elixir those live in the process dictionary,
  so a loop runs from `Start` to `Done` in one process and cannot be
  resumed elsewhere. `history`, `attemptsSoFar`, `currentRound`, `draft`
  and `lastProblems` are readable at any point, which is what the hosts
  read for their logs and page events, but "state is data" is not yet
  true of it. The `Transcript` is `List<Attempt>`, one row per round
  with `summary`, `edits`, `error` and which teacher retry it belonged
  to.
- `AskUser` exists in one direction only. A teacher's "Something is
  wrong" note and the attempts she rejected arrive as `Guidance` in the
  repair setup and land in the first user turn; the agent never asks.

### Transcript and scoring (rung 6)

```temper
export class Transcript(public turns: List<Turn>, public usage: Usage, public model: String) {}
export sealed interface Turn {}
export class ModelTurn(public request: ChatRequest, public response: ChatResponse, public millis: Int?) extends Turn {}
export class ToolTurn(public call: ToolCall, public result: ToolResult, public millis: Int?) extends Turn {}
export class UserTurn(public message: UserMessage) extends Turn {}

export interface Scorer { public score(t: Transcript): Score; }
export class Score(public value: Float64, public passed: Boolean, public reasons: List<String>) {}
export let exactMatch(expected: String): Scorer
export let regexMatch(pattern: String): Scorer              // Temper's own regex, same on every backend
export let jsonSchema(schema: JsonSyntaxTree): Scorer       // the validator ArgReader uses
export let structuredOutput(schema: JsonSyntaxTree, where: fn (JsonSyntaxTree): Boolean): Scorer
export let toolCalled(name: String, argsMatching: JsonSyntaxTree?): Scorer
```

The Python eval team and the Java product grade the same `Transcript`
with the same scorer, and Temper's tests prove the scorers agree, which
is the pitch. Today the thing to score is `List<Attempt>`.

## What it looks like from each language

The generated surface today (from `temper.out/`), and the one-file shim
each language would ship so the loop reads natively. The shim is the only
hand-written code per language.

| | Transport the host implements | Loop idiom | Casing | Rough edge seen today |
|---|---|---|---|---|
| **Python** | subclass `Transport` (an `ABCMeta` class), `def send(self, request, /)` | `while True: match agent.next(event)` with `case SendRequest()`; shim wraps in `async def` with `httpx` | `from_text`, `complete`, `last_error` | parameters are positional-only (`/`), so no keyword args from the host |
| **JS / TS** | `class extends Transport { send(req) }`, or any object with `send` | `for await` over a tiny generator the shim writes around `next`; `fetch` with `ReadableStream` frames into `feed` for rung 1 | `fromText`, `complete` | `Int64` fields are `bigint`; `Int` and `Float64` are both `number` |
| **Rust** | `impl TransportTrait for MyTransport`, including `clone_boxed` | `loop { match agent.next(event) { Step::SendRequest(r) => ... } }`; shim adds `reqwest` and `tokio` adapters | `from_text`, `complete` | every type is `Arc`-wrapped and `clone_boxed` is boilerplate the shim should hide; `Result<T>` is `temper_core::Result` |
| **C#** | `class MyTransport : ITransport { HttpResponse Send(HttpRequest r) }` | `while (true) switch (agent.Next(ev)) { case SendRequest s: ... }`; shim adds `HttpClient` and `Task` wrappers | `FromText`, `Complete`, statics on `ChatGlobal` | sealed types are `IMessage` etc. with pattern matching on classes; works |
| **Java** | `class MyTransport implements Transport { HttpResponse send(HttpRequest r) }` | `while (true) { Step s = agent.next(ev); if (s instanceof SendRequest r) ... }` (JDK 17 patterns); shim adds `java.net.http` | `fromText`, `complete`, statics on `ChatGlobal` | cannot test here until the CLI accepts four-part JDK versions (#525) |
| **Lua** | a table with a `send` function | a plain `while` loop; no async exists, which is why the core has none | `fromText`, `complete` | no `Int64` on 5.1; strings index by byte |
| **Elixir** (sibling backend) | a module with `send/2` or `stream/3`, called by the host loop | one `defp drive` clause per `%TemperCore.Ref{class: T.SendRequest}` etc. | `get_currentRound`, `T.Start.new()` | fields live in the process dictionary: the whole loop, and the `StreamAssembler` it feeds, must run in the process that made them |

The shim per language is small by design: an HTTP adapter, a streaming
body reader, an async wrapper where the language has async, a sleep for
`RetryAfter`, and type bridges where the ecosystem expects them (pydantic
models from `ChatResponse`, `serde` for `AgentState`, `System.Text.Json`
for tool arguments). None of it contains decisions; the decisions are in
Temper so they are the same everywhere.

## What Temper forces, and how the design respects it

- No I/O, no clock: every effect is a `Step` the host performs; time
  comes in as `Event` fields and `millis` arguments.
- No async in the core: Lua has none, and hosts have their own loops. The
  step machine is the async-agnostic shape.
- No reference cycles: `RoundsAgent` owns its messages and attempts; the
  `Script` and `ReplyReader` never point back at the engine; validators
  live in the host.
- Map keys are `String` or `Int` only: registries key by tool name, call
  id, turn index.
- `enum` translation is unreliable (issue #859): roles, finish reasons,
  give-up causes and transport-failure kinds are string constants on a
  class (`GiveUpCauses.cutOff`, `TransportFailures.noKey`).
- `Bubble` has no message: `Problems` everywhere, including warnings for
  what a provider profile dropped.
- Generated decoders need every key present; the OpenAI format omits
  keys: hand-written adapters, as `src/chat/` does.
- A field and a method with the same name read differently on interp and
  on js/py (`probes/interp-field-vs-method`): the assembler's field is
  `finishSeen` beside `finish()`.

## To verify by probe before building each rung

1. A host-implemented interface on each backend: Python ABC subclass,
   Rust `impl TransportTrait` with `clone_boxed`, C# `ITransport`, JS
   object with `send`, Lua table. (Temper-side implementations pass; the
   host side is the claim. Done for Elixir: `probes/elixir-host`, and
   Jam Pilot.)
2. A sealed `Step` matched from host code: Rust `match` on
   `StepEnum`, C# `switch` on type, Python `match` on class. (Done for
   Elixir: match on `class`.)
3. `AgentState` round trip through JSON on every backend, including
   `Int64` usage counters on Lua 5.1 and `bigint` on JS.
4. Function values across the boundary are a known hazard (#619, generic
   function values); the design avoids passing functions in either
   direction, and the probe confirms `Scorer` as an interface, not a
   `fn`, translates everywhere.
5. Streaming chunk formats from three providers, recorded as fixtures
   the way growthbook recorded Node's answers, so `StreamAssembler` is
   checked against real bytes. (Fireworks: done, `stream_test.temper`
   and the scripted frames in Jam Pilot's `ScriptedGLM.stream/3`; the
   other two providers: not.)
6. Long strings and many small `feed` calls on Lua and Python, for the
   cost of `StringBuilder` per chunk.

## A worked example: Jam Pilot's two loops, as the agent rung

[Jam Pilot](../../notedance_viewer) (a Phoenix app) reads Noteflight
scores with a reader that is strict on purpose. When it refuses a score,
`Dave.Hotfix` hands GLM 5.3 the reader's own source, the refusal
sentence and the document, gets back find/replace edits as JSON, applies
them, runs the reader again, and sends a new refusal back to the model,
three rounds at most. A teacher who presses "Something is wrong" adds a
note that goes into the first user turn as data, with the attempts she
rejected listed. Every round is recorded whether it worked or not. It
was about 500 lines of Elixir, tuned against the model over two days.

Then the composer page: a teacher types a song as plain text and asks the
bot in a sentence. `Dave.Compose.assist` sends the song and the request,
reads a `Summary:` line and the whole song from a fence, runs the same
strict reader and a word list on it, sends the reader's sentences back,
five rounds, and streams the model's thinking to the page as it goes. It
was 352 lines of Elixir, the same loop with different turns, and it was
written second, which is how the engine was found: `src/rounds/` is what
the two have in common, and `src/repair/` and `src/compose/` are what
each has of its own. Since 2026-10-21 Jam Pilot runs both ports:
`hotfix_test.exs` `27 tests, 0 failures` unchanged, `compose_test.exs`
`18 tests, 0 failures`, the whole suite `195 tests, 0 failures`.

What differs between the two loops is all in their setups, scripts and
readers; the engine does not know which one it is running:

| | Repair (`src/repair/`) | Compose (`src/compose/`) |
|---|---|---|
| Rounds | 3 | 5 |
| Effort, round 1 | `"high"` | `"low"` (at `"medium"` and 8,000 tokens the model never answered) |
| Effort after a refusal | `"high"` | `"medium"` (at `"low"` a 24-bar song failed the bar count three rounds running) |
| max_tokens | 16000 | 24000 |
| Reply | `{"summary", "edits": [...]}` JSON, fences tolerated | a `Summary:` line and the song in a ``` fence |
| Reader | `parseEdits`, then `applyEdits` on the original document; an edit that does not place is the next turn | `parseReply`: the host's two PCRE regexes by hand; no `realize`, the text is the proposal |
| Host's check | the strict reader, rescued into one sentence | the reader (`preview/1`), then the word list (`Suitable`); refused with `keep: false` when the song is unfit for children |
| Cut-off at max_tokens | asked for again once, at `"low"`, with `cutOffTurn` ("Do not deliberate...") | ends the loop; the cut-off sentence is the answer |
| Draft on give-up | none: a patch the reader refuses is never handed back | the last song that read, with its problems listed under it, unless it was refused for its words |
| What the person gets | `{:ok, xml, summary, attempts}` or `{:error, attempts}`; the attempts go on the issue row | `SongWritten(text, summary, problems)` or `NoSong(sentence)` from `ComposeAgent.outcome(step)` |
| Streaming | no: `GLM.send/2`, `parseChatResponse` | yes: `GLM.stream/3` into `StreamAssembler`, deltas to the page |
| Guidance | a teacher's note and her rejected attempts in the first turn | none |

The repair host loop, from `lib/dave/hotfix.ex`, copied. A step is a
`%TemperCore.Ref{class: T.SendRequest}` struct and the host matches on
`class`; the sketch this section carried before called a
`Temper.Dave.step_kind/1` that the backend does not generate. Every
field of a Temper object sits in the process dictionary of the process
that made it, so the repair runs from `RepairSetup.new` to the last
`get_attempts` in one process (the repair Task in `Dave.Issues`, or the
test):

```elixir
  def repair(xml, error, check, opts \\ []) do
    client =
      Keyword.get(opts, :client) || Application.get_env(:dave, __MODULE__, [])[:client] ||
        Dave.Hotfix.GLM

    rounds = Keyword.get(opts, :rounds, @rounds)
    guidance = opts |> Keyword.get(:guidance) |> guidance()

    # nil takes the Temper default: temperature 0.2, max_tokens 16000,
    # reasoning_effort "high"
    setup =
      T.RepairSetup.new(
        xml,
        error,
        system_prompt(),
        Dave.Hotfix.GLM.model(),
        rounds,
        nil,
        nil,
        nil,
        guidance
      )

    agent = T.RepairAgent.new(setup)
    drive(agent, T.RepairAgent.next(agent, T.Start.new()), check, client, rounds, nil)
  end
```

```elixir
  defp drive(agent, %TemperCore.Ref{class: T.Check} = step, check, client, rounds, _effort) do
    round = T.RepairAgent.get_currentRound(agent)
    recorded = Enum.count(T.RepairAgent.get_attemptsSoFar(agent))

    event =
      case check(check, step |> T.Check.get_candidate() |> T.Candidate.get_text()) do
        :ok -> T.CheckPassed.new()
        {:refused, why} -> T.CheckRefused.new([why], nil)
      end

    next = T.RepairAgent.next(agent, event)

    case new_attempt(agent, recorded) do
      # the reader's next refusal goes back to the model, with its reply
      %{error: why} when is_binary(why) ->
        Logger.warning("hotfix round #{round} failed: #{String.slice(why, 0, 300)}")

      _ ->
        :ok
    end

    drive(agent, next, check, client, rounds, nil)
  end

  defp drive(_agent, %TemperCore.Ref{class: T.Done} = step, _check, _client, _rounds, _effort) do
    candidate = T.Done.get_candidate(step)

    {:ok, T.Candidate.get_text(candidate), T.Candidate.get_summary(candidate),
     attempts(T.Done.get_attempts(step))}
  end

  defp drive(_agent, %TemperCore.Ref{class: T.GaveUp} = step, _check, _client, _rounds, _effort) do
    {:error, attempts(T.GaveUp.get_attempts(step))}
  end
```

The compose host loop, from `lib/dave/compose.ex`, is the same shape with
a `started` clock for the log line and page events; the `SendRequest`
clause tells the page the round began, the `Check` clause runs the two
validators and tells the page what was refused:

```elixir
  defp drive(agent, %TemperCore.Ref{class: T.Check} = step, client, on_event, started) do
    round = T.ComposeAgent.get_currentRound(agent)
    candidate = T.Check.get_candidate(step)
    text = T.Candidate.get_text(candidate)
    said = text <> "\n" <> T.Candidate.get_summary(candidate)

    event =
      with {:ok, _} <- preview(text),
           :ok <- Dave.Compose.Suitable.check(said) do
        T.CheckPassed.new()
      else
        {:error, problems} ->
          problems = List.wrap(problems)
          Logger.info("compose assist round #{round} did not read: #{Enum.join(problems, " ")}")
          on_event.({:problems, problems})
          # a song that read but is unfit for children is never kept as the draft
          T.CheckRefused.new(problems, not Dave.Compose.Suitable.unsuitable?(said))
      end

    drive(agent, T.ComposeAgent.next(agent, event), client, on_event, started)
  end
```

The whole of `assist/3`, `drive/5` and the streaming `post/3` are in the
README under "The compose loop".

The transport seam. `post/2` is the host's: it builds the wire message
itself, so a scripted transport in a test sees exactly what the real one
would post, and a non-200, a body `parseChatResponse` refuses, or a 200
with no choices becomes a `TransportFailed` before the agent sees it.
`Dave.Hotfix.GLM.send/2` is one `Req.post` with the bearer key added,
`decode_body: false`, `retry: false`, and the round's timeout, returning
`{:ok, %{status:, body:}}`, `{:error, exception}` or
`{:error, :no_api_key}`. `Dave.Hotfix.GLM.stream/3` is the same request
with `into:` a function that receives each raw body piece in the calling
process; on a 200 the returned body is `""` and the pieces went through
`on_chunk`, a non-200 body is collected and returned whole with
`on_chunk` never called, and a raise inside `on_chunk` propagates to the
caller, because a malformed frame is the caller's failure to name.

The vendoring. The generated code is three mix projects whose `mix.exs`
files name each other by relative path (`dave` → `../temper-core` and
`../std`), so the host's `scripts/vendor-dave.sh` rsyncs `mix.exs`,
`lib/` and `test/` of each (no `_build`, no `deps`, no `.map` source
maps) into `vendor/dave/` keeping those names, and writes
`vendor/dave/VERSION` with the dave commit (`+dirty` when the tree
was), the CLI version and the build time. `scripts/matrix.sh` here
deletes and rebuilds `temper.out/elixir`, so the build comes right
before the copy. Current `VERSION`:

```
dave commit: f3002faadbce636b31bdef3f05908d46a850566a+dirty
temper cli: Temper df59dc3
built: 2026-10-21T19:50:42-0400
source: /Users/bg/code/dave/temper.out/elixir
js: /Users/bg/code/notedance_viewer/assets/vendor/temper (from /Users/bg/code/dave/temper.out/js)
```

What the ports proved, on seven backends (the six here plus Elixir
through `bin/temper-elixir`, `59 of 59` on each that runs): the hotfix
tests pass unchanged in meaning on the engine, including the cut-off
path (`15673 of 16000`), the three-round conversation shape (`system
user assistant user assistant user`), and the guidance turn landing in
the first user message and not the system prompt; the compose tests keep
every sentence the teacher is shown and the twelve `parse_reply` cases
whose expected strings came from running the host's regexes with
`elixir`. Both loops have now run against the live model through the
port, one call each: the repair `OK in 11426 ms`, one round, one edit
(`<value>3</value>` → `<value>6</value>`, the reader then accepts the
document); the compose `OK in 3420 ms`, one round, 24 reasoning deltas
and 318 content deltas through `StreamAssembler`, a song the reader
took. The outputs are in the README. What has not been reached live:
a second round of either loop, a cut-off, a transport failure; those
are exercised by the scripted transports only.

What the ports do not keep: the byte count in the first turn is a
character count (Temper has no bytes); the Task, its timeout and the
`settle_stuck` sweep stay in Elixir, because they are time; the readers'
source and the song format in the system prompts are the host's to
embed; and the `stream: true` flag is added by the host, for want of a
setter on `ChatRequest.extra`. The smaller departures, measured with
HEAD's loops loaded beside the ports and the same scripted replies (wire
key order, no position detail in `reply is not JSON`, a non-string
`summary` recorded as `""`, transport sentences on the row, the streamed
cut-off sentence now carrying the token count, a malformed chunk ending
the round instead of being skipped), are listed in the README under
"Where the port's output differs" and at the top of
`src/repair/edits.temper`.

## Proposed order (one chapter per PR)

1. `src/chat/` types, client, validation (done)
2. Provider profiles and retry decisions
3. `StreamAssembler` with recorded fixtures (done for Fireworks frames; tool-call deltas not)
4. `Conversation` and token budgets
5. `ToolSpec`, `ArgReader`, the JSON Schema validator
6. `Agent` step machine (done as `RoundsAgent`, two loops on it), `AgentState` JSON round trip (not)
7. `Transcript` and the first four scorers, with cross-backend agreement tests
8. One shim and one example program per language, calling the generated libraries for real (Elixir done: Jam Pilot)
