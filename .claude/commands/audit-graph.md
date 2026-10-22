---
description: Audit the decision graph - find contradictions, rule on each from the evidence, leave one true final answer, repair connections
allowed-tools: Bash(deciduous:*, git:*, mix:*, cargo:*, npm:*, cat:*, grep:*), mcp__deciduous__*
argument-hint: [goal-id | --branch <name> | --all] [--apply] [--stale-days N]
---

# Graph audit

The graph is only worth reading if it agrees with itself and with the
code. This command finds the places where it does not, rules on each one,
and leaves the graph saying one thing. It changes nothing unless
`--apply` is given; without it, the output is the plan.

The ruling rule, applied everywhere below: **the true final answer is what
the repository does now.** Evidence ranks in this order, and a higher rank
beats any number of nodes at a lower one:

1. Output you produce now: a test run, a build, a command, a file read.
2. A commit on the branch (`metadata.commit`, or `git log -S` for the title's words).
3. A merged pull request that contains the work.
4. The newest node.
5. The node with the higher confidence.

Nodes are never resolved by majority. Two nodes that agree and are wrong
lose to one node that matches the code. When no evidence above rank 4 can
be had, the finding is labelled `uncertain`, is listed, and is left alone.

## Step 0: Scope

```bash
WS=$(grep -A1 '^\[remote\]' .deciduous/config.toml 2>/dev/null | grep workspace | cut -d'"' -f2)
WS=${WS:-$(basename "$(git rev-parse --show-toplevel)")}
BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

`$ARGUMENTS` picks the scope: a goal id audits that goal's subtree; `--branch
<name>` audits every node on that branch; `--all` audits the workspace. With
no argument, audit the current branch. `--stale-days N` (default 14) sets
when an action with no outcome counts as stale.

## Step 1: Collect, read-only

Run all of these before judging anything:

- `consolidation_report` with the workspace, `stale_days`, and `max_items` 200. It gives
  duplicate goals, competing decisions, stale actions and parentless nodes,
  each with the call that would act on it.
- `find_orphans` with `suggest_parents: true`.
- `query_nodes` for the scope, once per status that can lie: `completed`,
  `active`, `pending`.
- `get_descendants` for every goal in scope.
- `deciduous edges` for the scope, so edge types (`chosen`, `rejected`,
  `leads_to`) are known.
- `git log --oneline -200` and the branch's merged PRs (`gh pr list --state merged --base <branch>` where it applies).

## Step 2: Find the contradictions

Check each kind. The detection rule says what to look for; the ruling rule
says how the evidence decides it.

| Kind | Detection | Ruling |
|------|-----------|--------|
| Competing decisions | Two live decisions under one goal or option, no `revisit` between them | The one whose actions have completed outcomes and commits wins. The other becomes `superseded`, with a `revisit` node from loser to winner saying why. |
| Conflicting outcomes | One action with outcomes that disagree (passed and failed, two different numbers) | Re-run what the outcomes claim if it can be run. Otherwise the newest outcome whose commit exists wins. The rest become `superseded`. |
| Decision contradicted by code | A decision chose option A; the actions and the code implement B | The code wins. Mark the decision `superseded`, add a `revisit` from it, add a decision for B under the same options if none exists, and link the actions to it. |
| Status lies | A goal `completed` with failed or pending actions below it; an action `completed` with no outcome; an outcome `pending`; a `rejected` option whose decision chose it | Set the status the subtree supports. A goal is completed only when every action below it has a completed outcome or is `abandoned`. |
| Contradicting observations | Two observations that cannot both be true, or one that the code contradicts | Check the code now. The wrong one becomes `rejected`, with a description saying what was found and where. |
| Duplicate goals | `consolidation_report` pairs labelled `merge`, or `uncertain` pairs whose subtrees are the same work | Merge only when the prompts match or one subtree is empty: move children to the keeper, mark the other `superseded`. `keep_separate` and different subtrees are left as they are. |
| Orphans and parentless nodes | `find_orphans` and the report's `parentless` list | Link to the suggested parent only when a signal is strong: `shared_files`, text similarity above 0.2, or the same session. Weak suggestions are listed, not linked. |
| Stale actions | `pending` action older than `stale_days` with no outcome | If a commit matches (`git log -S` on the title's distinctive words), add the outcome from the commit, with `--commit`. If nothing matches, `abandoned`. |
| Exact duplicates | Same type, same title, same parent, created within ten minutes, one with no children | Soft-delete the childless one with `delete_node`. This is the only deletion the audit makes. |

For each finding, write one line before resolving it:

```
<kind> | <node ids> | ruling: <winner> | evidence: <rank and what it is>
```

## Step 3: Rule

Work through the lines in Step 2's order, because a status lie is often
a competing decision seen from below, and fixing the decision fixes the
status. Before each ruling, get the evidence named on the line. If getting
it means running tests or a build, run them; do not take an outcome's
word for a number you can produce yourself.

Every resolution that changes a decision, outcome or observation gets a
`revisit` node, linked from the node being overruled, whose description
holds the evidence verbatim: the test output, the commit hash, the file
and line. The audit must itself be readable in the graph later.

Nothing is hard-deleted. `superseded`, `rejected` and `abandoned` are
statuses; the nodes stay. `delete_node` is soft and is used only for the
exact-duplicate case.

## Step 4: Apply, or print the plan

Without `--apply`: print the plan as a table, grouped by kind, with the
exact `update_node`, `add_node`, `add_edge` and `delete_node` calls that
would run, and stop.

With `--apply`: run the calls in order (status changes, then revisit nodes
with `parent_id`, then edges, then deletions), passing `workspace` and
`branch` on every write. Never put an `add_edge` in the same batch as the
`add_node` whose id it needs.

Then run `find_orphans` and `consolidation_report` again and show both
counts next to the Step 1 counts.

## Step 5: Report

```
Audited <scope> in <workspace>
  competing decisions   3 found, 3 ruled, 0 uncertain
  conflicting outcomes  2 found, 1 ruled (test re-run), 1 uncertain
  status lies           11 fixed
  observations          1 rejected (lib/foo.ex:42 says otherwise)
  duplicate goals       2 merged, 3 kept separate
  orphans               21 -> 6 (15 linked on shared_files; 6 listed below, weak signals)
  stale actions         130 -> 0 (97 outcomes added from commits, 33 abandoned)
  exact duplicates      0
```

Then the `uncertain` list, each with what evidence would settle it. Then
the orphans left unlinked, each with its best suggestion and why it was not
strong enough.

## Scheduling

The audit is meant to run unattended, and the command installs no cron.
Run it on a loop with Claude Code:

```
/loop 24h /audit-graph
```

Keep it without `--apply` until the plan and the `uncertain` list look
right for a few runs, then:

```
/loop 24h /audit-graph --apply
```

or `/schedule` for a cloud routine. On a scheduled run, post the Step 5
report to the message board (`post_message`, author `audit`, subject
`audit <scope> <YYYY-MM-DD>`, body the counts and the `uncertain` list) so
a run nobody watched leaves a record where the other sessions read. A
scheduled run audits the scope it was given and nothing wider.

Do not create a goal or action node for the audit itself. The `revisit`
nodes are its record.
