defmodule ComposeHostTest do
  @moduledoc """
  Drives Temper.Dave.ComposeAgent from the host side, the way Jam Pilot's
  `Dave.Compose.assist/3` will: the host posts each request, hands the
  reply back as a ChatResponse (whole, or assembled from a stream), runs
  its reader and its word list on each candidate, and turns the last step
  into the teacher's answer with `outcome/2`.
  """
  use ExUnit.Case

  alias Temper.Dave, as: D

  @song "title: Hot Cross Buns\ntempo: 90\n[Xylophone]\nE5 D C/2 | E D C/2 | C C C C | D D D D | E D C/2\n"
  @bad "title: Hot Cross Buns\ntempo: 90\n[Xylophone]\nE5 D C/2 | E D C/2 | C C C | D D D D | E D C/2\n"
  @system "You write songs for Jam Pilot ... Summary: ... ``` fence"
  @bar3 "Xylophone, bar 3 adds up to 3 beats; 4/4 wants 4."

  defp reply(song, summary \\ "Wrote it."), do: "Summary: #{summary}\n```\n#{song}```\n"

  # Every optional parameter nil: rounds 5, temperature 0.2, max_tokens 24000, effort "low", then "medium".
  defp compose_setup(rounds \\ nil, request \\ "hot cross buns please") do
    D.ComposeSetup.new("", request, @system, "glm-5.3", rounds, nil, nil, nil, nil)
  end

  defp request_body(step) do
    assert %TemperCore.Ref{class: D.SendRequest} = step
    step |> D.SendRequest.get_request() |> D.ChatRequest.toJsonText() |> Jason.decode!()
  end

  defp completion(content, finish \\ "stop", reasoning \\ nil) do
    usage = %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
    usage = if reasoning, do: Map.put(usage, "completion_tokens_details", %{"reasoning_tokens" => reasoning}), else: usage
    %{"id" => "r", "object" => "chat.completion", "created" => 1_700_000_000, "model" => "glm-5.3",
      "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => content}, "finish_reason" => finish}],
      "usage" => usage}
  end

  defp respond(agent, body) do
    problems = D.Problems.new()
    response = D.parseChatResponse(Jason.encode!(body), problems)
    assert D.Problems.get_isEmpty(problems)
    D.ComposeAgent.next(agent, D.Responded.new(response))
  end

  defp last_content(body), do: List.last(body["messages"])["content"]

  defp outcome(agent, step) do
    case D.ComposeAgent.outcome(agent, step) do
      %TemperCore.Ref{class: D.SongWritten} = o ->
        {:ok, %{text: D.SongWritten.get_text(o), summary: D.SongWritten.get_summary(o),
                problems: Enum.to_list(D.SongWritten.get_problems(o))}}
      %TemperCore.Ref{class: D.NoSong} = o ->
        {:error, D.NoSong.get_sentence(o)}
    end
  end

  test "a refused round goes back with the reader's sentences, then the song is handed back with its summary" do
    agent = D.ComposeAgent.new(compose_setup())
    step = D.ComposeAgent.next(agent, D.Start.new())
    body = request_body(step)
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user"]
    assert hd(body["messages"])["content"] == @system
    assert last_content(body) =~ "<<<REQUEST\nhot cross buns please\nREQUEST>>>"
    assert body["reasoning_effort"] == "low"
    assert body["max_tokens"] == 24000
    assert body["temperature"] == 0.2

    # round 1: the song does not add up; the host's reader refuses it, keep = true
    step = respond(agent, completion(reply(@bad)))
    assert %TemperCore.Ref{class: D.Check} = step
    candidate = D.Check.get_candidate(step)
    assert D.Candidate.get_text(candidate) == @bad
    assert D.Candidate.get_summary(candidate) == "Wrote it."
    step = D.ComposeAgent.next(agent, D.CheckRefused.new([@bar3], true))
    body = request_body(step)
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user", "assistant", "user"]
    assert body["reasoning_effort"] == "medium"
    assert last_content(body) =~ "Jam Pilot could not read that song:\n\n- #{@bar3}\n\n"
    assert D.ComposeAgent.get_currentRound(agent) == 2

    # round 2: reads
    step = respond(agent, completion(reply(@song, "Fixed bar 3.")))
    assert %TemperCore.Ref{class: D.Check} = step
    step = D.ComposeAgent.next(agent, D.CheckPassed.new())
    assert %TemperCore.Ref{class: D.Done} = step
    assert outcome(agent, step) == {:ok, %{text: @song, summary: "Fixed bar 3.", problems: []}}
  end

  test "when the rounds run out the draft comes back with its problems and the give-up sentence in its summary" do
    agent = D.ComposeAgent.new(compose_setup(2))
    D.ComposeAgent.next(agent, D.Start.new())
    respond(agent, completion(reply(@bad)))
    D.ComposeAgent.next(agent, D.CheckRefused.new([@bar3], true))
    respond(agent, completion(reply(@bad, "Second go.")))
    step = D.ComposeAgent.next(agent, D.CheckRefused.new([@bar3], true))
    assert %TemperCore.Ref{class: D.GaveUp} = step
    assert D.GaveUp.get_cause(step) == "out of rounds"
    assert {:ok, %{text: @bad, summary: summary, problems: [@bar3]}} = outcome(agent, step)
    assert summary == "Second go. After 2 tries the reader still found 1 thing to fix, listed under the song: fix them by hand, or ask the bot again."
  end

  test "a song refused for its words (keep = false) is never the draft; the teacher gets the unsuitable sentence" do
    agent = D.ComposeAgent.new(compose_setup(1))
    D.ComposeAgent.next(agent, D.Start.new())
    respond(agent, completion(reply(@song, "Damn.")))
    rude = "The song is for young children and cannot contain “damn”. Rewrite it on a cheerful, safe subject with none of those words anywhere, not in the title, the words, the part names or the summary."
    step = D.ComposeAgent.next(agent, D.CheckRefused.new([rude], false))
    assert %TemperCore.Ref{class: D.GaveUp} = step
    assert D.GaveUp.get_draft(step) == nil
    assert {:error, sentence} = outcome(agent, step)
    assert sentence == "The bot kept writing words that are not suitable for children, so nothing was changed. Try asking for the song another way."
  end

  test "no key, a transport sentence, and a raw detail" do
    for {why, kind, want} <- [
          {"whatever", "no key", "The bot is not set up on this server (no GLM_API_KEY)."},
          {"GLM answered 503: busy", nil, "GLM answered 503: busy"},
          {"{:closed, :timeout}", "detail", "The bot did not answer: {:closed, :timeout}"}
        ] do
      agent = D.ComposeAgent.new(compose_setup())
      D.ComposeAgent.next(agent, D.Start.new())
      step = D.ComposeAgent.next(agent, D.TransportFailed.new(why, kind))
      assert %TemperCore.Ref{class: D.GaveUp} = step
      assert D.GaveUp.get_cause(step) == "transport failed"
      assert outcome(agent, step) == {:error, want}
    end
  end

  test "a streamed reply cut off while thinking ends the loop with its sentence, no retry" do
    a = D.StreamAssembler.new()
    frame =
      [
        ~s(data: {"id":"c","model":"glm-5.3","choices":[{"index":0,"delta":{"reasoning_content":"Count"},"finish_reason":null}]}),
        ~s(data: {"id":"c","model":"glm-5.3","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}),
        ~s(data: {"id":"c","model":"glm-5.3","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":24000,"total_tokens":24001,"completion_tokens_details":{"reasoning_tokens":23990}}}),
        "data: [DONE]",
        ""
      ]
      |> Enum.join("\n")

    D.StreamAssembler.feed(a, frame)
    response = D.StreamAssembler.finish(a)
    assert D.ChatResponse.get_text(response) == nil

    agent = D.ComposeAgent.new(compose_setup())
    D.ComposeAgent.next(agent, D.Start.new())
    step = D.ComposeAgent.next(agent, D.Responded.new(response))
    assert %TemperCore.Ref{class: D.GaveUp} = step
    assert D.GaveUp.get_cause(step) == "cut off"
    assert outcome(agent, step) ==
             {:error, "GLM ran out of room: 23990 of 24000 tokens went to thinking and the reply was cut off before any answer"}
    assert agent |> D.ComposeAgent.get_attemptsSoFar() |> Enum.count() == 1
  end

  test "parseReply and fixTurn are reachable as plain functions" do
    problems = D.Problems.new()
    proposal = D.parseReply("```text\ntitle: A\n[A]\nC5/1\n```\nSummary: s", problems)
    assert D.Proposal.get_summary(proposal) == "s"
    assert D.Proposal.get_text(proposal) == "title: A\n[A]\nC5/1\n"
    assert_raise TemperCore.Bubble, fn -> D.parseReply("no fence here", D.Problems.new()) end
    problems = D.Problems.new()
    try do
      D.parseReply("no fence here", problems)
    rescue
      TemperCore.Bubble -> :ok
    end
    assert D.Problems.get_last(problems) == "The reply has no score: it must be a Summary: line and then the whole score inside a ``` fence."
    assert D.fixTurn(Enum.map(1..21, &"p#{&1}")) =~ "- p20\n- ...and 1 more like these.\n\n"
  end
end
