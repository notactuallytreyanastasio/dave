defmodule ElixirHostTest do
  @moduledoc """
  Drives Temper.Dave.RepairAgent from the host side, the way Jam Pilot's
  loop will: the host performs every effect (the model call, the reader)
  and feeds the result back as an event. Everything here is read through
  the generated getters into plain Elixir terms, so the test documents what
  a host sees, not what the Temper source says.
  """
  use ExUnit.Case

  alias Temper.Dave, as: D

  @doc_text "<score><bar><value>6</value><value>3</value></bar><bar><value>6</value></bar></score>"
  @fixed "<score><bar><value>6</value><value>4</value></bar><bar><value>6</value></bar></score>"
  @refusal "TODO: NFMXML note value 3.0 not yet observed"
  @system "You repair scores. defmodule Dave.NFM.Parser ... Reply with JSON only"
  @fix_reply ~s({"summary": "A 32nd note in bar 1 was written as a sixteenth.", "edits": [{"find": "<value>3</value>", "replace": "<value>4</value>"}]})
  @bad_reply ~s({"summary": "nope", "edits": [{"find": "<value>99</value>", "replace": "<value>4</value>"}]})

  # ---------- host helpers: what Jam Pilot's loop will do ----------

  # Every optional parameter is passed as nil to take its Temper default.
  defp repair_setup(guidance \\ nil) do
    D.RepairSetup.new(@doc_text, @refusal, @system, "glm-5.3", nil, nil, nil, nil, guidance)
  end

  # The request as the wire would see it: JSON text, decoded with Jason.
  defp request_body(step) do
    assert %TemperCore.Ref{class: D.SendRequest} = step
    step |> D.SendRequest.get_request() |> D.ChatRequest.toJsonText() |> Jason.decode!()
  end

  # A chat-completions body as a provider would send it.
  defp completion(content, finish \\ "stop", reasoning \\ nil) do
    usage = %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}

    usage =
      if reasoning,
        do: Map.put(usage, "completion_tokens_details", %{"reasoning_tokens" => reasoning}),
        else: usage

    %{
      "id" => "r",
      "object" => "chat.completion",
      "created" => 1_700_000_000,
      "model" => "glm-5.3",
      "choices" => [
        %{"index" => 0, "message" => %{"role" => "assistant", "content" => content}, "finish_reason" => finish}
      ],
      "usage" => usage
    }
  end

  # Parse the provider's JSON text into a ChatResponse and hand it to the agent.
  defp respond(agent, body) do
    problems = D.Problems.new()
    response = D.parseChatResponse(Jason.encode!(body), problems)
    assert D.Problems.get_isEmpty(problems), inspect(Enum.to_list(D.Problems.get_messages(problems)))
    D.RepairAgent.next(agent, D.Responded.new(response))
  end

  defp edit_map(e) do
    %{
      find: D.Edit.get_find(e),
      replace: D.Edit.get_replace(e),
      occurrence: D.Edit.get_occurrence(e),
      all: D.Edit.get_all(e)
    }
  end

  defp attempt_map(a) do
    %{
      round: D.Attempt.get_round(a),
      summary: D.Attempt.get_summary(a),
      edits: a |> D.Attempt.get_edits() |> Enum.map(&edit_map/1),
      error: D.Attempt.get_error(a),
      retry: D.Attempt.get_retry(a)
    }
  end

  defp roles(body), do: Enum.map(body["messages"], & &1["role"])
  defp last_content(body), do: List.last(body["messages"])["content"]

  # ---------- the loop ----------

  test "a round that does not place, a cut-off round, then a fix: three attempts, each read back" do
    agent = D.RepairAgent.new(repair_setup())

    # Start -> the first request
    step = D.RepairAgent.next(agent, D.Start.new())
    body = request_body(step)
    assert roles(body) == ["system", "user"]
    assert body["model"] == "glm-5.3"
    assert body["temperature"] == 0.2
    assert body["max_tokens"] == 16000
    assert body["reasoning_effort"] == "high"
    assert hd(body["messages"])["content"] == @system
    user = last_content(body)
    assert is_binary(user)
    assert String.contains?(user, @refusal)
    assert String.ends_with?(user, @doc_text <> "\n")
    refute String.contains?(user, "TEACHER NOTE")

    # round 1: an edit that does not place -> the complaint goes back as a user turn
    step = respond(agent, completion(@bad_reply))
    body = request_body(step)
    assert roles(body) == ["system", "user", "assistant", "user"]
    assert Enum.at(body["messages"], 2)["content"] == @bad_reply
    assert String.starts_with?(last_content(body), "That did not work")
    assert String.contains?(last_content(body), "not found in the document")
    assert body["reasoning_effort"] == "high"

    # round 2: the reply was cut off while thinking -> ask again, briefly, at low effort
    step = respond(agent, completion(nil, "length", 15673))
    body = request_body(step)
    assert roles(body) == ["system", "user", "assistant", "user", "user"]
    assert body["reasoning_effort"] == "low"
    assert String.contains?(last_content(body), "15673 of 16000")
    assert String.contains?(last_content(body), "Do not deliberate")

    # round 3: a good edit -> Check, the host runs its reader
    step = respond(agent, completion(@fix_reply))
    assert %TemperCore.Ref{class: D.Check} = step
    candidate = D.Check.get_candidate(step)
    assert %TemperCore.Ref{class: D.Candidate} = candidate
    assert D.Candidate.get_text(candidate) == @fixed
    assert D.Candidate.get_summary(candidate) == "A 32nd note in bar 1 was written as a sixteenth."
    assert candidate |> D.Candidate.get_edits() |> Enum.map(&edit_map/1) == [
             %{find: "<value>3</value>", replace: "<value>4</value>", occurrence: nil, all: false}
           ]

    step = D.RepairAgent.next(agent, D.CheckPassed.new())
    assert %TemperCore.Ref{class: D.Done} = step
    assert step |> D.Done.get_candidate() |> D.Candidate.get_text() == @fixed
    assert step |> D.Done.get_candidate() |> D.Candidate.get_summary() == "A 32nd note in bar 1 was written as a sixteenth."

    attempts = step |> D.Done.get_attempts() |> Enum.map(&attempt_map/1)
    assert length(attempts) == 3

    assert [
             %{round: 1, summary: "nope", error: e1, retry: nil, edits: [%{find: "<value>99</value>"}]},
             %{round: 2, summary: nil, error: e2, retry: nil, edits: []},
             %{round: 3, summary: "A 32nd note in bar 1 was written as a sixteenth.", error: nil, retry: nil, edits: [_]}
           ] = attempts

    assert e1 == ~s|edit 1 (find "<value>99</value>"): not found in the document; copy the text exactly as it is|
    assert e2 == "GLM ran out of room: 15673 of 16000 tokens went to thinking and the reply was cut off before any answer"

    assert D.RepairAgent.get_currentRound(agent) == 3
    assert agent |> D.RepairAgent.get_attemptsSoFar() |> Enum.count() == 3
  end

  test "guidance with a previous attempt carrying retry 1 prints '- round 1 of retry 1:' in the first user turn" do
    previous = [D.Attempt.new(1, "dropped it", [], nil, 1)]
    guidance = D.Guidance.new("keep the second voice", 3, previous)
    agent = D.RepairAgent.new(repair_setup(guidance))
    body = agent |> D.RepairAgent.next(D.Start.new()) |> request_body()
    user = last_content(body)
    assert String.contains?(user, "- round 1 of retry 1: dropped it; edits: []")
    assert String.contains?(user, "<<<TEACHER NOTE (about bar 3)>>>\nkeep the second voice\n<<<END TEACHER NOTE>>>")
    refute String.contains?(hd(body["messages"])["content"], "keep the second voice")

    # and an Attempt without retry: no suffix
    body =
      D.RepairAgent.new(repair_setup(D.Guidance.new("note", nil, [D.Attempt.new(2, nil, [], "bad", nil)])))
      |> D.RepairAgent.next(D.Start.new())
      |> request_body()

    assert String.contains?(last_content(body), "- round 2: (no summary); edits: []; the reader then said: bad")
    refute String.contains?(last_content(body), "of retry")
  end

  test "TransportFailed on a fresh agent is GaveUp with one attempt that says why" do
    agent = D.RepairAgent.new(repair_setup())
    assert %TemperCore.Ref{class: D.SendRequest} = D.RepairAgent.next(agent, D.Start.new())
    # nil for `kind` takes the default, TransportFailures.sentence: `why` is kept as given
    step = D.RepairAgent.next(agent, D.TransportFailed.new("no GLM_API_KEY configured", nil))
    assert %TemperCore.Ref{class: D.GaveUp} = step
    assert step |> D.GaveUp.get_attempts() |> Enum.map(&attempt_map/1) == [
             %{round: 1, summary: nil, edits: [], error: "no GLM_API_KEY configured", retry: nil}
           ]
    assert D.GaveUp.get_cause(step) == "transport failed"
    assert D.GaveUp.get_draft(step) == nil
    assert Enum.to_list(D.GaveUp.get_problems(step)) == ["no GLM_API_KEY configured"]
  end

  test "CheckRefused goes back to the model as a user turn; out of rounds is GaveUp" do
    agent = D.RepairAgent.new(repair_setup())
    D.RepairAgent.next(agent, D.Start.new())
    assert %TemperCore.Ref{class: D.Check} = respond(agent, completion(@fix_reply))
    # the reader's sentences as a list; nil for `keep` takes the default (true; repair keeps no draft anyway)
    step = D.RepairAgent.next(agent, D.CheckRefused.new(["TODO: NFMXML note value 4.0 not yet observed"], nil))
    body = request_body(step)
    assert roles(body) == ["system", "user", "assistant", "user"]
    assert String.contains?(last_content(body), "the reader still refuses the patched document: TODO: NFMXML note value 4.0")

    assert %TemperCore.Ref{class: D.Check} = respond(agent, completion(@fix_reply))
    assert %TemperCore.Ref{class: D.SendRequest} = D.RepairAgent.next(agent, D.CheckRefused.new(["still"], nil))
    assert %TemperCore.Ref{class: D.Check} = respond(agent, completion(@fix_reply))
    step = D.RepairAgent.next(agent, D.CheckRefused.new(["still"], nil))
    assert %TemperCore.Ref{class: D.GaveUp} = step
    assert step |> D.GaveUp.get_attempts() |> Enum.count() == 3
    assert D.GaveUp.get_cause(step) == "out of rounds"
    assert Enum.to_list(D.GaveUp.get_problems(step)) == ["still"]
  end

  # ---------- what raises ----------

  test "a body that is not JSON raises TemperCore.Bubble and leaves the reason on Problems" do
    problems = D.Problems.new()
    assert_raise TemperCore.Bubble, fn -> D.parseChatResponse("not json", problems) end
    assert Enum.to_list(D.Problems.get_messages(problems)) == ["$: not valid JSON"]
  end

  test "a body off the chat-completions contract raises TemperCore.Bubble with the path" do
    problems = D.Problems.new()
    assert_raise TemperCore.Bubble, fn -> D.parseChatResponse(~s({"id": "r"}), problems) end
    assert D.Problems.get_last(problems) =~ "$."
  end

  test "an event that is not a RepairEvent raises TemperCore.Panic" do
    agent = D.RepairAgent.new(repair_setup())
    assert_raise TemperCore.Panic, fn -> D.RepairAgent.next(agent, :start) end
  end

  test "finish reasons are read from TemperCore.Global after init" do
    D.__temper_init__()
    assert TemperCore.Global.get(:"Temper.Dave.FinishReasons.length") == "length"
    assert TemperCore.Global.get(:"Temper.Dave.FinishReasons.stop") == "stop"
  end

  # ---------- the heap-per-process rule ----------

  test "an agent made in one process is not an object in another; a Task owning the whole loop is fine" do
    agent = D.RepairAgent.new(repair_setup())

    assert {:error, %ArgumentError{message: msg}} =
             Task.async(fn ->
               try do
                 {:ok, D.RepairAgent.next(agent, D.Start.new())}
               rescue
                 e in ArgumentError -> {:error, e}
               end
             end)
             |> Task.await()

    assert msg =~ "is not an object in this process"

    # the whole repair inside one Task: build, drive, and read the result there
    {:ok, fixed, summary, n} =
      Task.async(fn ->
        agent = D.RepairAgent.new(repair_setup())
        D.RepairAgent.next(agent, D.Start.new())
        assert %TemperCore.Ref{class: D.Check} = respond(agent, completion(@fix_reply))
        step = D.RepairAgent.next(agent, D.CheckPassed.new())
        candidate = D.Done.get_candidate(step)
        {:ok, D.Candidate.get_text(candidate), D.Candidate.get_summary(candidate), Enum.count(D.Done.get_attempts(step))}
      end)
      |> Task.await()

    assert fixed == @fixed
    assert summary == "A 32nd note in bar 1 was written as a sixteenth."
    assert n == 1
  end
end
