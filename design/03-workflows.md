# 03 — Workflows

A workflow is an ordinary Ruby script. No YAML, no DSL, no step vocabulary.

## Settled

- **Plain Ruby in `workflows/`.** Agentworks began with YAML, drifted into a
  DSL, and ended up running `.rb` scripts anyway. Remuda skips to the end. A
  workflow uses library classes; control flow is Ruby's.
- **Recording is built into the classes, not called by the script.** Every
  effect already flows through the gem — the MCP tool client for deterministic
  calls, `Remuda.reason` for sandboxed Pi invocations. Those classes record
  their own step rows against the current run. The script never mentions
  recording; there is nothing to forget.
- **The runner owns the run record.** `remuda run <agent> <workflow>` (and the
  scheduler's tick) opens the `workflow_runs` row, establishes the current-run
  context, executes the script, captures output/error/duration, closes the
  row. A script executed outside the runner (plain `ruby workflows/x.rb`) is
  legal Ruby but unrecorded — don't do that in production.
- **Two effect primitives**:
  - `Remuda.tools.<server>.<tool>(args)` — deterministic MCP call, direct,
    no LLM. Self-records a step (tool, args, result/error, timing).
  - `Remuda.reason(prompt, ...)` — one sandboxed Pi invocation. Self-records
    a step (prompt, session, output, usage).
- **Turing-completeness is accepted.** The old "no custom code" boundary was a
  product-for-strangers rule. The sandbox boundary on reasoning steps does the
  real safety work; the workflow script itself runs on the host with the
  operator's authority, like any cron job.

## Sketch

```ruby
# workflows/triage.rb — plain Ruby
plane = Remuda.tools.plane
items = plane.list_work_items(project_id: OPS_ID, state_group: "backlog")

items.each do |item|
  verdict = Remuda.reason(<<~PROMPT, context: { item: item })
    Triage this arrival per the triage skill...
  PROMPT
  plane.create_comment(project_id: OPS_ID, work_item_id: item[:id],
                       comment_html: verdict.html) if verdict.actionable?
end
```

Run context is ambient (thread/fiber-local run id set by the runner); the tool
client and `reason` read it to attach their step rows.

## Open

- **Shape of `Remuda.tools`**: generated per `mcp.json` (method_missing proxy
  vs generated stubs)? How do tool schemas surface for arguments/errors?
- **`reason` result object**: what does Pi give us back (structured output,
  session id, usage) and what do we normalize into?
- **Inputs**: how does `remuda run ops triage --input k=v` reach the script —
  `Remuda.inputs` hash? ARGV? env?
- **Concurrency/locking**: two ticks firing the same workflow — advisory lock
  per (agent, workflow) in the DB?
- **Failure semantics**: exception in the script = failed run (obvious), but
  partial-step retry is explicitly *not* a feature (no engine, no resume)? Or
  do we want idempotence conventions documented instead?
- **Where do shared workflow helpers live** — `workflows/lib/`? The agent's
  own module namespace? (This is the `app/models` question for agents.)
- **Timeouts**: per-`reason` timeout and per-run timeout — who enforces,
  runner or class?
