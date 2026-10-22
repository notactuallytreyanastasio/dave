(function () {
  "use strict";
  var D = window.Dave;
  if (!D) { return; }
  var chat = D.chat, rounds = D.rounds, agentMod = D.agent, room = D.room, repair = D.repair, parseJson = D.parseJson;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------- sidebar: the current section ----------
  var links = Array.prototype.slice.call(document.querySelectorAll("nav.toc a[href^='#']"));
  var targets = links.map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); }).filter(Boolean);
  if ("IntersectionObserver" in window && targets.length) {
    var current = null;
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { current = e.target.id; } });
      links.forEach(function (a) { a.classList.toggle("on", a.getAttribute("href") === "#" + current); });
    }, { rootMargin: "-10% 0px -75% 0px" });
    targets.forEach(function (t) { io.observe(t); });
  }

  // ---------- shared: traces ----------
  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  function entry(kind, who, what, detail, pre) {
    var e = document.createElement("div");
    e.className = "entry " + kind;
    e.innerHTML = "<div class='who'>" + esc(who) + "</div><div class='what'><b>" + esc(what) + "</b>" +
      (detail ? "<div class='detail'>" + esc(detail) + "</div>" : "") +
      (pre ? "<pre>" + esc(pre) + "</pre>" : "") + "</div>";
    return e;
  }
  function attemptsTable(attempts) {
    var rows = attempts.map(function (a) {
      return "<tr><td>" + a.round + "</td><td>" + esc(a.summary == null ? "" : a.summary) + "</td><td>" + a.edits.length + "</td><td>" + a.toolCalls + "</td><td>" + esc(a.error == null ? "" : a.error) + "</td></tr>";
    }).join("");
    var w = document.createElement("div");
    w.className = "tablewrap";
    w.innerHTML = "<table class='attempts'><thead><tr><th>round</th><th>summary</th><th>edits</th><th>tool calls</th><th>error</th></tr></thead><tbody>" + rows + "</tbody></table>";
    return w;
  }
  function clearTrace(el) { Array.prototype.slice.call(el.children, 1).forEach(function (c) { el.removeChild(c); }); }
  var timers = {};
  function reveal(el, nodes, key) {
    if (timers[key]) { timers[key].forEach(clearTimeout); }
    timers[key] = [];
    nodes.forEach(function (n, i) {
      timers[key].push(setTimeout(function () { n.classList.add("in"); el.appendChild(n); }, reduced ? 0 : i * 380));
    });
  }
  function roles(request) { return request.messages.map(function (m) { return m.role; }).join(" "); }
  function requestSummary(request) {
    var json = JSON.parse(request.toJsonText());
    var bits = [roles(request)];
    if (json.tools && json.tools.length) { bits.push("tools: " + json.tools.map(function (t) { return t.function.name; }).join(", ")); }
    if (json.tool_choice) { bits.push("tool_choice: " + JSON.stringify(json.tool_choice)); }
    if (json.reasoning_effort) { bits.push("reasoning_effort: " + json.reasoning_effort); }
    bits.push("max_tokens: " + json.max_tokens);
    return bits.join(" · ");
  }
  function lastTurn(request) {
    var json = JSON.parse(request.toJsonText());
    var last = json.messages[json.messages.length - 1];
    var c = typeof last.content === "string" ? last.content : JSON.stringify(last.content);
    return last.role + ": " + (c.length > 420 ? c.slice(0, 420) + " …" : c);
  }
  function completion(message, finish, reasoning) {
    return new chat.ChatResponse("chatcmpl-demo", "glm-5.3", [new chat.Choice(0, message, finish)], null, new chat.Usage(1200, 300, 1500, reasoning));
  }
  function says(text) { return completion(new chat.AssistantMessage(text), chat.FinishReasons.stop, 120); }
  function cutOff(reasoning) { return completion(new chat.AssistantMessage(null), chat.FinishReasons.length, reasoning); }
  function calls(list) { return completion(new chat.AssistantMessage(null, list), chat.FinishReasons.toolCalls, 40); }

  function drive(agent, model, host, nodes) {
    var step;
    try { step = agent.next(new rounds.Start()); } catch (e) {
      var why = (agent.missing && agent.missing.length) ? "next() panics: the specialty asks for a bucket the catalogue lacks (" + agent.missing.join(", ") + "). A misconfigured agent does not run without the tools it was written for." : String(e && e.message || e);
      nodes.push(entry("fail", "library", "panic", why));
      return null;
    }
    nodes.push(entry("host", "host", "Start", null));
    var guard = 0;
    while (guard++ < 60) {
      if (step instanceof rounds.SendRequest) {
        nodes.push(entry("lib", "library", "SendRequest", requestSummary(step.request), lastTurn(step.request)));
        var r = model(step.request);
        if (r.dead) {
          nodes.push(entry("host", "host", "TransportFailed", r.dead));
          step = agent.next(new rounds.TransportFailed(r.dead));
        } else {
          var msg = r.response.choices[0].message;
          var what = msg.toolCalls.length ? msg.toolCalls.map(function (c) { return c.name + "(" + c.arguments + ")"; }).join(", ") : (msg.content === null ? "(no content)" : msg.content);
          nodes.push(entry("host", "host", "Responded", "finish_reason: " + r.response.finishReason + (r.response.finishReason === "length" ? ", reasoning_tokens: " + r.response.usage.reasoningTokens : ""), what));
          step = agent.next(new rounds.Responded(r.response));
        }
      } else if (step instanceof rounds.RunTools) {
        nodes.push(entry("lib", "library", "RunTools", step.runs.map(function (x) { return x.bucket + " › " + x.call.name + " " + x.call.arguments; }).join(" · ")));
        var results = step.runs.map(function (x) { return new rounds.ToolResult(x.call.id, host.tool(x)); });
        nodes.push(entry("host", "host", "ToolsRan", results.map(function (x) { return x.content; }).join(" · ")));
        step = agent.next(new rounds.ToolsRan(results));
      } else if (step instanceof rounds.Check) {
        nodes.push(entry("lib", "library", "Check", "summary: " + (step.candidate.summary || "(none)"), step.candidate.text));
        var why2 = host.check(step.candidate.text);
        if (why2) {
          nodes.push(entry("host", "host", "CheckRefused", why2));
          step = agent.next(new rounds.CheckRefused([why2]));
        } else {
          nodes.push(entry("host", "host", "CheckPassed", null));
          step = agent.next(new rounds.CheckPassed());
        }
      } else if (step instanceof rounds.Done) {
        var d = entry("end", "library", "Done", "round " + agent.currentRound + " · " + step.attempts.length + " attempt(s)");
        d.querySelector(".what").appendChild(attemptsTable(step.attempts));
        nodes.push(d);
        return step;
      } else if (step instanceof rounds.GaveUp) {
        var g = entry("fail", "library", "GaveUp", "cause: " + step.cause + " · " + step.problems.join(" "));
        g.querySelector(".what").appendChild(attemptsTable(step.attempts));
        nodes.push(g);
        return step;
      } else {
        nodes.push(entry("fail", "library", "unknown step", String(step)));
        return null;
      }
    }
    return null;
  }

  // ---------- the engine: repair ----------
  var doc = "<score>\n  <bar><value>6</value><value>3</value></bar>\n  <bar><value>6</value></bar>\n</score>";
  var docEl = document.getElementById("engine-doc");
  if (docEl) { docEl.textContent = doc; }
  var fixJson = '{"summary": "A 32nd note in bar 1 was written as a sixteenth.", "edits": [{"find": "<value>3</value>", "replace": "<value>4</value>"}]}';
  var wrongPlace = '{"summary": "Fixing bar 1.", "edits": [{"find": "<value>9</value>", "replace": "<value>4</value>"}]}';
  var repairHost = {
    check: function (text) { return text.indexOf("<value>3</value>") >= 0 ? "TODO: NFMXML note value 3.0 not yet observed" : null; },
    tool: function () { return ""; }
  };
  function scriptedModel(replies) {
    var i = 0;
    return function () {
      if (i >= replies.length) { return { dead: "scripted model ran out of replies" }; }
      return replies[i++];
    };
  }
  var engineScenarios = {
    first: function () { return [{ response: says(fixJson) }]; },
    three: function () { return [{ response: says("I think bar 1 has a 32nd; let me explain what to change.") }, { response: says(wrongPlace) }, { response: says(fixJson) }]; },
    cutoff: function () { return [{ response: cutOff(15673) }, { response: says(fixJson) }]; },
    dead: function () { return [{ dead: "no route to api.fireworks.ai" }]; }
  };
  var engineTrace = document.getElementById("engine-trace");
  var enginePlay = document.getElementById("engine-play");
  if (enginePlay) {
    enginePlay.addEventListener("click", function () {
      clearTrace(engineTrace);
      var setup = new repair.RepairSetup(doc, "TODO: NFMXML note value 3.0 not yet observed", "You repair scores. Reply with JSON only.", "glm-5.3");
      var agent = new repair.RepairAgent(setup);
      var nodes = [];
      drive(agent, scriptedModel(engineScenarios[document.getElementById("engine-scenario").value]()), repairHost, nodes);
      reveal(engineTrace, nodes, "engine");
    });
    document.getElementById("engine-clear").addEventListener("click", function () { clearTrace(engineTrace); });
  }

  // ---------- the generic agent ----------
  class Librarian extends agentMod.Specialty {
    get name() { return "librarian"; }
    get systemPrompt() { return "You find books. Use lookup; answer with the shelf mark."; }
    get buckets() { return ["shelf"]; }
    opening(task) { return "Find: " + task; }
  }
  var schema = parseJson('{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}');
  function catalogue(withShelf) {
    var list = [new rounds.ToolBucket("kitchen", [new chat.FunctionTool("boil", "Boil water", schema)])];
    if (withShelf) { list.unshift(new rounds.ToolBucket("shelf", [new chat.FunctionTool("lookup", "Find a book by title", schema)])); }
    return list;
  }
  var agentTrace = document.getElementById("agent-trace");
  var agentPlay = document.getElementById("agent-play");
  if (agentPlay) {
    agentPlay.addEventListener("click", function () {
      clearTrace(agentTrace);
      var turns = parseInt(document.getElementById("agent-turns").value, 10);
      var unknown = document.getElementById("agent-unknown").checked;
      var obeys = document.getElementById("agent-obeys").checked;
      var refuse = document.getElementById("agent-refuse").checked;
      var missing = document.getElementById("agent-missing").checked;
      var agent = new agentMod.GenericAgent("glm-5.3", "the dragon book", new Librarian(), catalogue(!missing), turns);
      var nodes = [];
      nodes.push(entry("note", "agent", "offered buckets: " + (agent.buckets.map(function (b) { return b.name; }).join(", ") || "none") + " · missing: " + (agent.missing.join(", ") || "none")));
      var titles = ["Compilers", "Dragons"];
      var id = 0, firstTurn = true;
      var model = function (request) {
        var json = JSON.parse(request.toJsonText());
        var closed = json.tool_choice === "none";
        var lookedUp = json.messages.filter(function (m) { return m.role === "tool" && /^QA76/.test(m.content); }).length;
        var noTools = !json.tools || !json.tools.length;
        if (noTools || lookedUp >= titles.length || (closed && obeys)) { return { response: says("QA76.73 .K54") }; }
        var list = [];
        if (unknown && firstTurn) { list.push(new chat.ToolCall("call_" + (++id), "boil", '{"litres": 1}')); }
        firstTurn = false;
        list.push(new chat.ToolCall("call_" + (++id), "lookup", JSON.stringify({ title: titles[lookedUp] })));
        return { response: calls(list) };
      };
      var checks = 0;
      var host = {
        tool: function (run) { return run.call.name === "lookup" ? "QA76.73 .K54 for " + run.call.arguments : "tool " + run.call.name + " failed: nothing in bucket " + run.bucket; },
        check: function () { checks++; return (refuse && checks === 1) ? "The shelf mark must name the book's author too." : null; }
      };
      drive(agent, model, host, nodes);
      reveal(agentTrace, nodes, "agent");
    });
    document.getElementById("agent-clear").addEventListener("click", function () { clearTrace(agentTrace); });
  }

  // ---------- the room ----------
  var srvPos = document.getElementById("srv-pos");
  if (srvPos) {
    var beats = 4, bpm = 90, barMs = 60000 / bpm * beats, barsCount = 8;
    var measures = [], playback = [];
    for (var b = 0; b < barsCount; b++) { measures.push(new room.Bar(b, b * barMs, barMs, barMs)); playback.push(new room.PlaybackStep(b, b * barMs)); }
    var timeline = new room.RoomTimeline(beats, measures, playback);
    var songMs = barMs * barsCount;
    var serverClock = new room.RoomClock();
    var mono = function () { return performance.now(); };
    var wall = function () { return Date.now(); };

    function Follower(el, skewMs, rttMs, lateMs) {
      this.el = el; this.skew = skewMs; this.rtt = rttMs; this.late = lateMs;
      this.offset = new room.ServerOffset();
      this.clock = new room.FollowerClock(this.offset);
      this.applied = 0;
      this.bars = el.querySelector(".bars");
      for (var i = 0; i < barsCount; i++) { var s = document.createElement("i"); s.appendChild(document.createElement("b")); this.bars.appendChild(s); }
    }
    Follower.prototype.localNow = function () { return wall() + this.skew; };
    Follower.prototype.ping = function () {
      var sent = this.localNow();
      var rtt = this.rtt + Math.random() * this.rtt * 0.6;
      this.offset.sample(sent, wall() + rtt * 0.5, sent + rtt);
      this.el.querySelector(".offset").textContent = "offset: " + Math.round(this.offset.offsetMs) + " ms from " + this.offset.kept.length + " sample(s)";
    };
    Follower.prototype.receive = function (state) {
      var self = this;
      setTimeout(function () {
        var change = self.clock.apply(state, self.localNow());
        self.applied++;
        self.el.querySelector(".last").textContent = "broadcast: " + state.status + " · position " + Math.round(state.positionMs) + " ms · count-in left " + Math.round(state.countInMs) + " ms";
        var j = self.el.querySelector(".jump");
        if (change.jumped && self.applied > 1) { j.classList.add("on"); setTimeout(function () { j.classList.remove("on"); }, 900); }
      }, this.late);
    };
    Follower.prototype.draw = function () {
      var now = this.localNow();
      var pos = Math.max(0, this.clock.positionAt(now));
      var left = this.clock.countInLeftAt(now);
      var w = room.countInNow(timeline, this.clock.positionMs, left);
      this.el.querySelector(".word").innerHTML = (w && this.clock.status === "playing") ? esc(w.word) : "&nbsp;";
      this.el.querySelector(".pos").textContent = fmt(pos);
      var cur = Math.min(barsCount - 1, Math.floor(pos / barMs));
      var kids = this.bars.children;
      for (var i = 0; i < kids.length; i++) {
        kids[i].className = i < cur ? "done" : "";
        var cursor = kids[i].firstChild;
        cursor.style.left = (i === cur ? ((pos - cur * barMs) / barMs * 100) : (i < cur ? 100 : 0)) + "%";
        cursor.style.opacity = i === cur ? 1 : 0;
      }
    };
    function fmt(ms) { var s = ms / 1000; var m = Math.floor(s / 60); var r = (s - m * 60).toFixed(1); return m + ":" + (r < 10 ? "0" : "") + r; }

    var followers = [new Follower(document.getElementById("scr-tv"), 0, 10, 0), new Follower(document.getElementById("scr-ipad"), 37000, 60, 200)];
    followers.forEach(function (f) { for (var i = 0; i < 6; i++) { setTimeout(function () { f.ping(); }, i * 300); } setInterval(function () { f.ping(); }, 10000); });

    function broadcast() {
      var state = serverClock.stateAt(mono(), wall());
      document.getElementById("srv-state").textContent = state.status + " · position " + Math.round(state.positionMs) + " ms · count-in left " + Math.round(state.countInMs) + " ms";
      followers.forEach(function (f) { f.receive(state); });
    }
    setInterval(function () { if (serverClock.playing) { broadcast(); } }, 1000);

    document.getElementById("room-play").addEventListener("click", function () {
      var now = mono();
      var here = Math.max(0, serverClock.positionAt(now));
      if (here >= songMs) { here = 0; }
      var countIn = document.getElementById("room-countin").checked ? room.countInFor(timeline, here) : null;
      if (countIn) { serverClock.play(now, countIn.startMs, countIn.ms); } else { serverClock.play(now, null, 0); }
      broadcast();
    });
    document.getElementById("room-pause").addEventListener("click", function () { serverClock.pause(mono()); broadcast(); });
    document.getElementById("room-seek").addEventListener("click", function () { serverClock.seek(mono(), 0); broadcast(); });

    function frame() {
      var now = mono();
      var pos = serverClock.positionAt(now);
      if (serverClock.playing && pos >= songMs) { serverClock.pause(now); serverClock.seek(now, songMs); broadcast(); }
      srvPos.textContent = fmt(Math.max(0, Math.min(songMs, pos)));
      followers.forEach(function (f) { f.draw(); });
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  // ---------- streaming ----------
  var streamPlay = document.getElementById("stream-play");
  if (streamPlay) {
    function chunk(delta, finish, usage) {
      var o = { id: "chatcmpl-demo", object: "chat.completion.chunk", created: 1761100000, model: "glm-5.3", choices: [{ index: 0, delta: delta, finish_reason: finish }] };
      if (usage) { o.usage = usage; }
      return "data: " + JSON.stringify(o) + "\n\n";
    }
    var f1 = chunk({ role: "assistant", reasoning_content: "Four bars, one part, the children can clap it. " }, null);
    var f2 = chunk({ reasoning_content: "Hot cross buns fits." }, null) + chunk({ content: "Summary: a four-bar song" }, null);
    var f3 = chunk({ content: " the class can clap.\n```\ntitle: Hot Cross Buns\ntempo: 90\n[Xylophone]\nE5 D C/2 | E D C/2" }, null);
    var f4 = chunk({ content: " | C C C C | D D D D | E D C/2\n```" }, "stop", { prompt_tokens: 1599, completion_tokens: 110, total_tokens: 1709, completion_tokens_details: { reasoning_tokens: 27 } }) + "data: [DONE]\n\n";
    var cut = Math.floor(f3.length * 0.55);
    var frames = [f1, f2, f3.slice(0, cut), f3.slice(cut) + f4];
    var framesEl = document.getElementById("stream-frames");
    function drawFrames(active) {
      framesEl.innerHTML = "";
      frames.forEach(function (fr, i) {
        var d = document.createElement("div");
        d.className = "frame" + (i < active ? " in" : "");
        var short = fr.replace(/\n/g, "⏎");
        d.textContent = "frame " + (i + 1) + " · " + fr.length + " bytes · " + (short.length > 110 ? short.slice(0, 110) + "…" : short);
        framesEl.appendChild(d);
      });
    }
    drawFrames(0);
    var streamTimers = [];
    function resetStream() {
      streamTimers.forEach(clearTimeout); streamTimers = [];
      drawFrames(0);
      document.querySelector("#stream-reply .thinking").textContent = "";
      document.querySelector("#stream-reply .content").textContent = "";
      document.getElementById("stream-finish").textContent = "(not finished)";
    }
    streamPlay.addEventListener("click", function () {
      resetStream();
      var asm = new chat.StreamAssembler();
      var th = document.querySelector("#stream-reply .thinking"), ct = document.querySelector("#stream-reply .content");
      frames.forEach(function (fr, i) {
        streamTimers.push(setTimeout(function () {
          drawFrames(i + 1);
          var deltas;
          try { deltas = asm.feed(fr); } catch (e) { th.textContent = "assembler refused the frame: " + (asm.lastError || e); return; }
          deltas.forEach(function (d) {
            if (d instanceof chat.ReasoningDelta) { th.textContent += d.text; } else { ct.textContent += d.text; }
          });
          if (i === frames.length - 1) {
            var resp = asm.finish();
            var usage = resp.usage;
            document.getElementById("stream-finish").textContent = JSON.stringify({ finish_reason: resp.finishReason, text_length: resp.text ? resp.text.length : 0, usage: usage ? { prompt_tokens: usage.promptTokens, completion_tokens: usage.completionTokens, reasoning_tokens: usage.reasoningTokens } : null, summary_line: (resp.text || "").split("\n")[0] }, null, 2);
          }
        }, reduced ? 0 : 650 * (i + 1)));
      });
    });
    document.getElementById("stream-clear").addEventListener("click", resetStream);
  }

  if (window.hljs) { window.hljs.highlightAll(); }
})();
