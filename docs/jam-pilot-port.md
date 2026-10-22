<!-- Moved verbatim from README.md on 2026-10-22; the README is the front door, this is the port's record. -->

# The first real host: Jam Pilot

Jam Pilot (`../notedance_viewer`, the Phoenix app both loops were ported
from) runs its score repair and its composer's assistant on the Elixir
generated from this repo. Its own `lib/dave/hotfix/edits.ex` is deleted,
`lib/dave/hotfix.ex` and `lib/dave/compose.ex` are host loops that
perform each step `Temper.Dave.RepairAgent` and `Temper.Dave.ComposeAgent`
ask for, its `parse_sse` is deleted in favour of `Temper.Dave.StreamAssembler`,
and its tests run against the generated code:

```
$ mix test
Finished in 2.6 seconds (0.9s async, 1.7s sync)
195 tests, 0 failures
```

(`hotfix_test.exs` alone: `27 tests, 0 failures`, unchanged by the move
onto the engine; `compose_test.exs` alone: `18 tests, 0 failures`.)

The generated Elixir is vendored, not a path dep across repositories,
because the host's `deploy.sh` rsyncs one checkout to the box and the
Dockerfile builds from it. The host's `scripts/vendor-dave.sh` copies
`mix.exs`, `lib/` and `test/` of the three mix projects under
`temper.out/elixir/` (`temper-core`, `std`, `dave`) into `vendor/dave/`;
`mix.exs` lists them as `{:temper_core, path: "vendor/dave/temper-core"}`
and siblings (dave alone does not pull the other two onto the code
path); the Dockerfile gains `COPY vendor vendor` before `mix deps.get`;
and `vendor/dave/VERSION` says what was built:

```
dave commit: f3002faadbce636b31bdef3f05908d46a850566a+dirty
temper cli: Temper df59dc3
built: 2026-10-21T19:50:42-0400
source: /Users/bg/code/dave/temper.out/elixir
js: /Users/bg/code/notedance_viewer/assets/vendor/temper (from /Users/bg/code/dave/temper.out/js)
```

What the generated API is from the host's side: a Temper object is a
`%TemperCore.Ref{class: Module}` whose fields live in the process
dictionary of the process that made it and are read through `get_field`
getters, so the step machine is driven by one function clause per step,
matched on `class`, and the whole loop has to run in one process.

## The repair loop

`Dave.Hotfix.repair/4` and `drive/6` from `lib/dave/hotfix.ex`, copied.
Moving `RepairAgent` onto the engine changed four call sites here and
nothing in `hotfix_test.exs`: `Fixed` became `Done` carrying a
`Candidate`, `CheckRefused` takes a list of sentences and a `keep` flag,
`TransportFailed` takes a `kind`:

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
  # ---------- the host loop: one clause per step the agent can ask for ----------

  # `effort` is only for the log line: nil for the setup's default, "low"
  # for the round after the model thought itself out of room (the agent
  # sets the request's reasoning_effort itself).
  defp drive(agent, %TemperCore.Ref{class: T.SendRequest} = step, check, client, rounds, effort) do
    round = T.RepairAgent.get_currentRound(agent)

    Logger.info(
      "hotfix round #{round}/#{rounds}#{if effort, do: " (#{effort} effort)", else: ""}"
    )

    recorded = Enum.count(T.RepairAgent.get_attemptsSoFar(agent))

    case post(client, T.SendRequest.get_request(step)) do
      {:ok, response} ->
        next = T.RepairAgent.next(agent, T.Responded.new(response))

        # a Check follows a reply that placed: nothing recorded yet. A
        # reply that did not place, or was cut off, is an attempt with an
        # error, and the cut-off makes the next round a low-effort one.
        effort =
          case new_attempt(agent, recorded) do
            nil ->
              nil

            %{error: "GLM ran out of room" <> _ = why} ->
              Logger.warning("hotfix round #{round} cut off: #{why}")
              "low"

            %{error: why} ->
              Logger.warning("hotfix round #{round} failed: #{String.slice(why, 0, 300)}")
              nil
          end

        drive(agent, next, check, client, rounds, effort)

      # the transport failed: nothing to send back, so this is the end
      {:error, why} ->
        next = T.RepairAgent.next(agent, T.TransportFailed.new(why, nil))
        drive(agent, next, check, client, rounds, nil)
    end
  end

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

Everything else in that file is the host's own: `post/2` builds the wire
message (`url`, `content-type`, `T.ChatRequest.toJsonText(request)`),
hands it to the transport (`Dave.Hotfix.GLM.send/2`: one `Req.post` with
the bearer key, `decode_body: false`, 180 s per round, `{:error,
:no_api_key}` without a key) and turns a non-200, a body
`parseChatResponse` refuses, or a 200 with no choices into a
`TransportFailed`; `check/2` rescues the reader's raise into
`CheckRefused`; `attempt/1` and `edit_record/1` read the agent's
`Attempt`s back into the maps the issue row keeps. The probe that proved
this shape before Jam Pilot was touched is `probes/elixir-host` (`mix
test` there: `15 tests, 0 failures`).

## The compose loop

`Dave.Compose.assist/3` and `drive/5` from `lib/dave/compose.ex`, copied.
The file lost `parse_reply/1`, `fix_turn/1`, `give_up/3`, `loop/6` and
`user_turn/2`, and its `@rounds`, `@effort`, `@retry_effort`,
`@max_tokens` and `@problems_sent`: all of that is `Temper.Dave.ComposeAgent`
now, and `rounds/0` reads the default back out of a throwaway
`ComposeSetup`. What stays is the system prompt (it embeds the host's song
format), the reader, the word list, and the page events:

```elixir
  def assist(text, request, opts \\ []) do
    client = Keyword.get(opts, :client) || client()
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)

    # nil takes the Temper default: 5 rounds, temperature 0.2, max_tokens
    # 24000, reasoning_effort "low" on round 1 and "medium" from round 2
    setup =
      T.ComposeSetup.new(
        text,
        request,
        system_prompt(),
        Dave.Hotfix.GLM.model(),
        Keyword.get(opts, :rounds),
        nil,
        Keyword.get(opts, :max_tokens),
        Keyword.get(opts, :effort),
        nil
      )

    agent = T.ComposeAgent.new(setup)
    drive(agent, T.ComposeAgent.next(agent, T.Start.new()), client, on_event, nil)
  end

  defp client, do: Application.get_env(:dave, __MODULE__, [])[:client] || Dave.Hotfix.GLM

  @doc "How many times the bot is asked before giving up: the library's default."
  def rounds do
    # The setup made to read the default is freed when the entry returns,
    # so a long-lived caller (the channel process) keeps nothing from it.
    TemperCore.Heap.entry(fn ->
      T.ComposeSetup.new("", "", "", "", nil, nil, nil, nil, nil) |> T.ComposeSetup.get_rounds()
    end)
  end

  # ---------- the host loop: one clause per step the agent can ask for ----------

  # `started` is when the round's request went out, for the log line.
  defp drive(agent, %TemperCore.Ref{class: T.SendRequest} = step, client, on_event, _started) do
    round = T.ComposeAgent.get_currentRound(agent)
    on_event.({:round, round})
    recorded = Enum.count(T.ComposeAgent.get_attemptsSoFar(agent))
    started = System.monotonic_time(:millisecond)

    {event, failed?} =
      case post(client, T.SendRequest.get_request(step), on_event) do
        {:ok, response} -> {T.Responded.new(response), false}
        {:error, why, kind} -> {T.TransportFailed.new(why, kind), true}
      end

    next = T.ComposeAgent.next(agent, event)

    # A Check follows a reply that was a song: nothing recorded yet. A
    # reply that was not one (no Summary: line and fence, an empty fence)
    # is an attempt with an error and its sentences go back to the model;
    # a reply the model cut off ends the loop with its own sentence.
    case new_attempt_error(agent, recorded) do
      nil ->
        :ok

      _why when failed? ->
        :ok

      why ->
        if cut_off?(next) do
          Logger.warning("compose assist round #{round} cut off: #{why}")
        else
          problems = Enum.to_list(T.ComposeAgent.get_lastProblems(agent))
          Logger.info("compose assist round #{round} did not read: #{Enum.join(problems, " ")}")
          on_event.({:problems, problems})
        end
    end

    drive(agent, next, client, on_event, started)
  end

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

  defp drive(agent, %TemperCore.Ref{class: T.Done} = step, _client, _on_event, started) do
    Logger.info(
      "compose assist answered in #{System.monotonic_time(:millisecond) - started} ms, " <>
        "round #{T.ComposeAgent.get_currentRound(agent)}"
    )

    outcome(agent, step)
  end

  defp drive(agent, %TemperCore.Ref{class: T.GaveUp} = step, _client, _on_event, _started),
    do: outcome(agent, step)

  # What the teacher gets, in the agent's words.
  defp outcome(agent, step) do
    case T.ComposeAgent.outcome(agent, step) do
      %TemperCore.Ref{class: T.SongWritten} = song ->
        {:ok,
         %{
           text: T.SongWritten.get_text(song),
           summary: T.SongWritten.get_summary(song),
           problems: Enum.to_list(T.SongWritten.get_problems(song))
         }}

      %TemperCore.Ref{class: T.NoSong} = none ->
        {:error, T.NoSong.get_sentence(none)}
    end
  end
```

The request is streamed, and the stream is assembled by the library. The
`stream` flag is added in the host, because `ChatRequest.extra` (where the
engine puts `reasoning_effort`) has no setter; each delta is forwarded to
the page as it arrives, and a frame the assembler refuses abandons the
stream with the assembler's reason:

```elixir
  defp post(client, request, on_event) do
    body =
      request
      |> T.ChatRequest.toJsonText()
      |> Jason.decode!()
      |> Map.put("stream", true)
      |> Jason.encode!()

    wire = %{
      method: "POST",
      url: Dave.Hotfix.GLM.base_url() <> "/chat/completions",
      headers: [{"content-type", "application/json"}],
      body: body
    }

    assembler = T.StreamAssembler.new()
    started = System.monotonic_time(:millisecond)

    on_chunk = fn chunk ->
      deltas =
        try do
          T.StreamAssembler.feed(assembler, chunk)
        rescue
          # a frame that was JSON but not a chunk the assembler reads (an
          # error object, a wrong type, streamed tool calls): the stream
          # is abandoned there, with the assembler's reason. Only feed's
          # own Bubble is caught, so another Temper failure stays a crash.
          TemperCore.Bubble ->
            throw({:malformed, T.StreamAssembler.get_lastError(assembler) || "unreadable frame"})
        end

      for delta <- deltas, do: forward(delta, on_event)
    end

    result =
      try do
        client.stream(wire, [timeout: @round_timeout_ms], on_chunk)
      catch
        {:malformed, why} -> {:malformed, why}
      end
```

`Dave.Hotfix.GLM.stream/3` is the transport: `Req` with `into:` a function
that receives each raw body piece of a 200 reply in the calling process
(Temper fields live in the process dictionary, so the assembler must be
fed from the process that made it); a non-200 body is collected whole and
`on_chunk` never called.

## Live runs through the port

Both loops have been run against the real model (Fireworks,
`accounts/fireworks/models/glm-5p3`) through the generated code, with the
host's `GLM_API_KEY` from its `.env`, one call each. The repair, the one
real refusal Jam Pilot has (`twinkle.nfmxml` with a `<value>6</value>`
changed to `<value>3</value>`), verbatim:

```
key configured: true; model accounts/fireworks/models/glm-5p3; base https://api.fireworks.ai/inference/v1
OK in 11426 ms; summary: The tempo marking in bar 1 used an unknown note-value unit (3) that the reader refuses; it was changed to the quarter-note unit (6), which matches the 80 bpm also written in the score's displayed tempo, so the speed the children play is unchanged.
attempts: [{1, nil, 1}]
edits: [%{"find" => "<tempo><value>3</value><bpm>80</bpm></tempo>", "occurrence" => 1, "replace" => "<tempo><value>6</value><bpm>80</bpm></tempo>"}]
reader accepts the fixed document: true; still has <value>3</value>: false
```

Before the engine, the same repair took 12.7 s in one round with one edit.
The compose loop, `Dave.Compose.assist(Dave.Compose.Text.example(), "make
it a song about a sleepy cat, two parts", on_event: counter)`, verbatim:

```
key configured: true; model accounts/fireworks/models/glm-5p3; base https://api.fireworks.ai/inference/v1
event round 1
thinking deltas: 24, writing deltas: 318
first writing delta (80): "Summary"
OK in 3420 ms
summary: I turned the tune into a gentle song about a sleepy cat, keeping the same easy melody and the two parts (xylophone with words, bass bells underneath).
problems: []
text (first 10 lines):
  | title: Sleepy Little Cat
  | composer: Jam Pilot
  | tempo: 100
  | time: 4/4
  | key: C
  | 
  | [Xylophone]
  | C5 C G G | A A G/2 | F F E E | D D C/2
  | G5 G F F | E E D/2 | G G F F | E E D/2
  | C5 C G G | A A G/2 | F F E E | D D C/2
```

The 24 `ReasoningDelta`s are the live thinking stream through
`StreamAssembler`; the scripted transport fakes one reasoning delta, and
the first live run after the port happened to get `reasoning_tokens: 0`,
so this was the first time real thinking went through it. That first
run, with the host's logger at `info`, showed the usage the assembler
keeps from the final chunk:

```
[info] glm streamed 200 in 1881 ms
[info] glm streamed in 1885 ms, finish "stop", 313 bytes of answer, usage %{completion_tokens: 110, prompt_tokens: 1599, reasoning_tokens: 0, total_tokens: 1709}
[info] compose assist answered in 1911 ms, round 1
```

Both runs ended in round 1, so the retry turn, the `"medium"` effort and
the cut-off sentence have been reached live only through the scripted
transport: a scripted `{:cut_off, 23900}` logged `compose assist round 1
cut off: GLM ran out of room: 23900 of 24000 tokens went to thinking and
the reply was cut off`.

## Where the port's output differs

The repair loop, measured with HEAD's `Dave.Hotfix` loaded beside the port
and the same scripted replies (the sentences that reach the model were
made identical first; these are what is left):

- The first user turn says `(N characters)` where the old said
  `(N bytes)`; same N for an ASCII score (twinkle: 37811 both ways),
  smaller for a score with multi-byte characters.
- The wire JSON's key order is `model, messages, temperature,
  max_tokens, reasoning_effort` (Jason sorted them alphabetically);
  every value is the same. In the guidance block an earlier edit is
  written `{"find","replace","occurrence"}` with `occurrence` always
  present where Jason wrote `{"find","occurrence","replace"}`.
- `reply is not JSON` carries no position detail; Jason appended
  `unexpected byte at position 0: 0x73 ("s")` and Temper's `parseJson`
  reports nothing. `reply is not {"summary": ..., "edits": [...]}` has
  no `: <inspect of the value>` tail.
- `edit N (find "...")` cuts the find at 80 code points, not graphemes,
  and escapes only `\`, `"`, newline, tab, carriage return and `#{`;
  `inspect` prints a find holding other control characters as a
  `<<...>>` binary.
- An occurrence of 99999999999 is refused up front where the old code
  accepted it and failed at apply; `"+2"` is refused where
  `Integer.parse` took it. Duplicate keys take the last value; a second
  fenced block after the first no longer makes the reply unreadable.
- A `summary` that is JSON but not a string records `""` (old:
  `to_string` of it).
- Transport sentences on the issue row inspect the raw body
  (`GLM answered 404: "<!DOCTYPE HTML ..."`) where the old inspected
  Req's decoded map; a 200 that is not a completion says
  `GLM answered 200: $.choices: expected array, got absent in "..."`.
  These never reach the model.
- Guidance input is checked: a recorded attempt without an integer
  `round` and a list `edits`, or an edit whose occurrence is not nil, a
  positive integer or `"all"`, raises `ArgumentError` where the old code
  printed whatever the row held.
- The log line `glm answered in N ms, usage ...` is two lines now: the
  transport's `glm answered STATUS in N ms` and the host's, with the
  Temper `Usage` flattened to atom keys.

The compose loop, asserted by its unchanged tests (the opening turn, the
fix turn with its cap of 20 sentences, the give-up sentences singular and
plural, the unsuitable sentence, the no-key sentence, and the `{:round}`,
`{:thinking}`, `{:writing}`, `{:problems}` events are byte for byte as
before); what is not:

- The streamed cut-off sentence. The old streaming path said `GLM ran out
  of room: its 24000 tokens went to thinking and the reply was cut off`;
  it now says `GLM ran out of room: 23900 of 24000 tokens went to
  thinking and the reply was cut off`, the wording the non-streaming path
  already used, with the count from the final chunk's usage (`?` when
  there is none).
- A data line that is JSON but malformed (an `{"error": ...}` object, a
  wrong type, `tool_calls`) was silently skipped by `parse_sse`; it now
  ends the round as a transport failure with `GLM answered 200:
  $.<path>: <why>`, for example `GLM answered 200: $.error: overloaded
  (server_error)`.
- The request body is the agent's `ChatRequest` JSON re-encoded by Jason
  with `"stream": true` added, so the same fields in Jason's key order,
  where the old `chat/2` built the map itself.
- Log lines: `glm streamed in N ms, finish ..., N bytes of answer` gained
  `, usage %{...}`; `GLM.stream` logs `glm streamed <status> in N ms`;
  a cut-off is a new `Logger.warning("compose assist round N cut off: ...")`.

Review found two places where the host had quietly taken on library
knowledge, both since fixed: `post/3` rescued every `TemperCore.Bubble`
raised inside `client.stream`, so a Bubble from some other Temper call
in a future `on_chunk` would have reached the teacher as
`GLM answered 200: ` with nothing after the colon (now only the
`StreamAssembler.feed` call is rescued, and anything else stays a
crash); and `cut_off?/1` compared against the literal `"cut off"` where
the library has `GiveUpCauses.cutOff` (now read from the Temper global
`Temper.Dave.GiveUpCauses.cutOff`). A new test streams an
`{"error": ...}` data line through the scripted client and gets
`GLM answered 200: $.error ...` and no second request, where the old
`parse_sse` skipped the line.
