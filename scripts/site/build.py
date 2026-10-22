#!/usr/bin/env python3
"""Build docs/index.html from scripts/site/page.html.

Every code block on the page is cut from a real file by anchor, so the page
cannot drift from the source without this script failing. Placeholders:

    {{snippet:NAME}}   a registered snippet (see SNIPPETS below)
    {{css}}            scripts/site/site.css, inlined
    {{js}}             scripts/site/demos.js, inlined

HOST_DIR names the Jam Pilot checkout (default ../notedance_viewer).
"""
import html, os, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOST = pathlib.Path(os.environ.get("HOST_DIR", ROOT.parent / "notedance_viewer")).resolve()
SITE = ROOT / "scripts" / "site"


def read(path):
    p = pathlib.Path(path)
    if not p.exists():
        sys.exit(f"missing file: {p}")
    return p.read_text().split("\n")


def between(path, start, end=None, after=None):
    """Lines from the first match of `start` through the first match of `end`
    that follows the first match of `after` (itself after `start`), inclusive.
    With no `end`, to the end of the file. `after` lets a snippet span several
    declarations: start at the first, close at the `}` that ends the last."""
    lines = read(path)
    s = next((i for i, l in enumerate(lines) if re.search(start, l)), None)
    if s is None:
        sys.exit(f"{path}: no line matches start={start!r}")
    if end is None:
        return lines[s:]
    a = s
    if after is not None:
        a = next((i for i in range(s, len(lines)) if re.search(after, lines[i])), None)
        if a is None:
            sys.exit(f"{path}: no line after {start!r} matches after={after!r}")
    e = next((i for i in range(a + 1, len(lines)) if re.search(end, lines[i])), None)
    if e is None:
        sys.exit(f"{path}: no line after {after or start!r} matches end={end!r}")
    return lines[s:e + 1]


def whole(path):
    lines = read(path)
    while lines and lines[-1] == "":
        lines.pop()
    return lines


L = ROOT / "src"
H = HOST

# name -> (language, label, lines)
SNIPPETS = {
    # the library's shape
    "config": ("markdown", "src/config.temper.md", whole(L / "config.temper.md")),
    "rules": ("markdown", "CLAUDE.md", between(ROOT / "CLAUDE.md", r"^## Rules that are load-bearing", r"^## Commit and PR style")[:-2]),
    # into a host
    "vendor_header": ("bash", "notedance_viewer/scripts/vendor-dave.sh", between(H / "scripts/vendor-dave.sh", r"^#!/bin/bash", r"^set -euo")),
    "vendor_js": ("bash", "notedance_viewer/scripts/vendor-dave.sh", between(H / "scripts/vendor-dave.sh", r"^# The JS: the three packages", r"^done", after=r"^jsdest=")),
    "mix_deps": ("elixir", "notedance_viewer/mix.exs", between(H / "mix.exs", r"vendored by scripts/vendor-dave.sh", r"temper_dave, path")),
    "dockerfile": ("dockerfile", "notedance_viewer/Dockerfile", between(H / "Dockerfile", r"^COPY mix.exs", r"^COPY vendor vendor")),
    "esbuild": ("elixir", "notedance_viewer/config/config.exs", between(H / "config/config.exs", r"^config :esbuild", r"^  \]")),
    "version": ("text", "notedance_viewer/vendor/dave/VERSION", whole(H / "vendor/dave/VERSION")),
    # chat
    "transport": ("typescript", "src/chat/client.temper", between(L / "chat/client.temper", r"^export class HttpRequest", r"^  public send")),
    "client": ("typescript", "src/chat/client.temper", between(L / "chat/client.temper", r"^export class ChatClient", r"^}")),
    "messages": ("typescript", "src/chat/messages.temper", between(L / "chat/messages.temper", r"^export sealed interface Message", r"^}", after=r"^export class ToolMessage")),
    "toolcall": ("typescript", "src/chat/messages.temper", between(L / "chat/messages.temper", r"^// A request from the model to run a tool", r"^  public static decode")[:-1]),
    "problems": ("typescript", "src/chat/problems.temper", between(L / "chat/problems.temper", r"^// Diagnostics for decoding", r"^}")),
    "stream_head": ("typescript", "src/chat/stream.temper", between(L / "chat/stream.temper", r"^// A streamed reply", r"^  public feed\(")),
    "stream_host": ("elixir", "notedance_viewer/lib/dave/compose.ex", between(H / "lib/dave/compose.ex", r"^  defp post\(client, request, on_event\)", r"^  end")),
    "glm_stream": ("elixir", "notedance_viewer/lib/dave/hotfix/glm.ex", between(H / "lib/dave/hotfix/glm.ex", r"^  def stream\(", r"^  end")),
    # rounds
    "steps": ("typescript", "src/rounds/steps.temper", between(L / "rounds/steps.temper", r"^// ---------- what the host does next", r"^export class CheckRefused")),
    "policy": ("typescript", "src/rounds/agent.temper", between(L / "rounds/agent.temper", r"^export class RoundsPolicy", r"^}", after=r"^export interface ReplyReader")),
    "next": ("typescript", "src/rounds/agent.temper", between(L / "rounds/agent.temper", r"^export class RoundsAgent", r"^  }", after=r"^  public next\(")),
    "tool_turn": ("typescript", "src/rounds/agent.temper", between(L / "rounds/agent.temper", r"^  // The model asked for tools", r"^  }", after=r"^  private afterTools")),
    "attempt": ("typescript", "src/rounds/steps.temper", between(L / "rounds/steps.temper", r"^// One round, as the record keeps it", r"^\) \{\}")),
    "buckets": ("typescript", "src/rounds/steps.temper", between(L / "rounds/steps.temper", r"^// ---------- tools", r"^export class ToolResult")),
    "hotfix_drive": ("elixir", "notedance_viewer/lib/dave/hotfix.ex", between(H / "lib/dave/hotfix.ex", r"^  # ---------- the host loop", r"^  end", after=r"class: T.GaveUp")),
    # repair
    "edits_contract": ("typescript", "src/repair/edits.temper", between(L / "repair/edits.temper", r"^// The reply is JSON", r"edit that cannot be placed")),
    "repair_agent": ("typescript", "src/repair/agent.temper", between(L / "repair/agent.temper", r"^// A reviewer's words", r"^}", after=r"^export class RepairAgent")),
    "repair_script": ("typescript", "src/repair/agent.temper", between(L / "repair/agent.temper", r"^class RepairReader", r"^}", after=r"^class RepairScript")),
    "repair_turn": ("typescript", "src/repair/agent.temper", between(L / "repair/agent.temper", r"^// ---------- the turns, as Jam Pilot sends them", r"^}", after=r"^let firstTurn")),
    "hotfix_repair": ("elixir", "notedance_viewer/lib/dave/hotfix.ex", between(H / "lib/dave/hotfix.ex", r"^  def repair\(xml, error, check", r"^  end")),
    "hotfix_guidance": ("elixir", "notedance_viewer/lib/dave/hotfix.ex", between(H / "lib/dave/hotfix.ex", r"^  defp guidance\(nil\)", r"^  end", after=r"^  defp previous_attempt\(%")),
    "repair_test": ("typescript", "src/repair/repair_test.temper", between(L / "repair/repair_test.temper", r"^let runThreeRounds", r"^}")),
    # compose
    "compose_agent": ("typescript", "src/compose/compose.temper", between(L / "compose/compose.temper", r"^export class ComposeSetup", r"^}", after=r"^export class ComposeAgent")),
    "compose_outcome": ("typescript", "src/compose/compose.temper", between(L / "compose/compose.temper", r"^// ---------- what the teacher gets", r"^}", after=r"^let giveUp")),
    "compose_script": ("typescript", "src/compose/compose.temper", between(L / "compose/compose.temper", r"^class ComposeReader", r"^}", after=r"^export let fixTurn")),
    "reply_header": ("typescript", "src/compose/reply.temper", between(L / "compose/reply.temper", r"^// The model's reply to the composer", r"^export let parseReply")[:-1]),
    "compose_assist": ("elixir", "notedance_viewer/lib/dave/compose.ex", between(H / "lib/dave/compose.ex", r"^  def assist\(text, request", r"^  end", after=r"^  def rounds do")),
    "compose_drive": ("elixir", "notedance_viewer/lib/dave/compose.ex", between(H / "lib/dave/compose.ex", r"^  # ---------- the host loop", r"^  end", after=r"^  defp outcome\(agent, step\)")),
    # agent
    "specialty": ("typescript", "src/agent/specialty.temper", between(L / "agent/specialty.temper", r"^export interface Specialty", r"^}", after=r"^export class PlainReader")),
    "generic_agent": ("typescript", "src/agent/specialty.temper", between(L / "agent/specialty.temper", r"^export class GenericAgent", r"^}")),
    "librarian": ("typescript", "src/agent/agent_test.temper", between(L / "agent/agent_test.temper", r"^// A librarian", r"^}", after=r"^let catalogue")),
    "agent_test_turn": ("typescript", "src/agent/agent_test.temper", between(L / "agent/agent_test.temper", r'^test\("a tool turn', r"^}")),
    "agent_test_closed": ("typescript", "src/agent/agent_test.temper", between(L / "agent/agent_test.temper", r'^test\("after the round', r"^}")),
    "quickstart": ("javascript", "README.md (run in Node against the built bundle)", between(ROOT / "README.md", r"^import \{ ChatResponse", r"^}")),
    # room
    "room_clock": ("typescript", "src/room/clock.temper", between(L / "room/clock.temper", r"^export class ClockStatus", r"^}", after=r"^export class RoomClock")),
    "server_offset": ("typescript", "src/room/clock.temper", between(L / "room/clock.temper", r"^export class OffsetSample", r"^}", after=r"^export class ServerOffset")),
    "follower": ("typescript", "src/room/clock.temper", between(L / "room/clock.temper", r"^export class StateChange", r"^}", after=r"^export class FollowerClock")),
    "count_in": ("typescript", "src/room/count_in.temper", between(L / "room/count_in.temper", r"^export class Bar\(", r"^}", after=r"^export let countInNow")),
    "sessions": ("elixir", "notedance_viewer/lib/dave/sessions.ex", whole(H / "lib/dave/sessions.ex")),
    "clock_js": ("javascript", "notedance_viewer/assets/js/clock.js", whole(H / "assets/js/clock.js")),
    "count_in_js": ("javascript", "notedance_viewer/assets/js/count_in.js", between(H / "assets/js/count_in.js", r"^// The timeline JSON", r"^}", after=r"^export function countInNow")),
    "ping": ("elixir", "notedance_viewer/lib/dave_web/channels/session_channel.ex", between(H / "lib/dave_web/channels/session_channel.ex", r'handle_in\("ping"', r"^  end")),
    "no_wobble": ("typescript", "src/room/room_test.temper", between(L / "room/room_test.temper", r'^test\("through a held count-in', r"^}")),
    "same_word": ("typescript", "src/room/room_test.temper", between(L / "room/room_test.temper", r'^test\("the TV and an iPad', r"^}")),
    # tests
    "test_pattern": ("typescript", "src/room/room_test.temper", between(L / "room/room_test.temper", r'^test\("play from a position', r"^}")),
    "matrix_sh": ("bash", "scripts/matrix.sh", between(ROOT / "scripts/matrix.sh", r"^for b in", r"^done")),
    "matrix_md": ("markdown", "MATRIX.md", between(ROOT / "MATRIX.md", r"^\| backend", r"^\| elixir")),
}


def block(name):
    lang, label, lines = SNIPPETS[name]
    body = html.escape("\n".join(lines))
    return (f'<figure class="code"><figcaption><span class="path">{html.escape(label)}</span>'
            f'<span class="lang">{html.escape(lang if lang != "typescript" else "temper")}</span></figcaption>'
            f'<pre><code class="language-{lang}">{body}</code></pre></figure>')


def main():
    page = (SITE / "page.html").read_text()
    page = page.replace("{{css}}", (SITE / "site.css").read_text())
    page = page.replace("{{js}}", (SITE / "demos.js").read_text())
    used = set()

    def sub(m):
        used.add(m.group(1))
        return block(m.group(1))

    page = re.sub(r"\{\{snippet:([a-z_]+)\}\}", sub, page)
    unused = set(SNIPPETS) - used
    if unused:
        sys.exit(f"snippets registered but not placed: {sorted(unused)}")
    out = ROOT / "docs" / "index.html"
    out.write_text(page)
    lines = sum(len(v[2]) for v in SNIPPETS.values())
    print(f"wrote {out} ({len(page)} bytes, {len(SNIPPETS)} snippets, {lines} lines of real code)")


if __name__ == "__main__":
    main()
