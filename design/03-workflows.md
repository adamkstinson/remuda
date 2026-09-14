# 03 — Workflows

A workflow is an ordinary Ruby script. No YAML, no DSL, no step vocabulary.
The feature is a **host-side runner** plus two methods that record themselves.
There is no engine, no step graph, no resume. Ruby is the control flow.

## Settled

- **Plain Ruby in `.remuda/workflows/`.** Agentworks began with YAML, drifted
  into a DSL, and ended up running `.rb` scripts anyway. Remuda skips to the
  end. The scripts are yours; they live under the harness folder so the agent
  root stays identity (`AGENTS.md`, `mcp.json`, `.pi/`, `Gemfile`, `files/`).
- **No workflow class.** The script is not `class Triage < Remuda::Workflow`.
  The runner `load`s `.remuda/workflows/<name>.rb` after `chdir` to the agent
  root, so `files/` and `require_relative "lib/foo"` from the script (i.e.
  `.remuda/workflows/lib/`) work. Helpers live in `.remuda/workflows/lib/`.
  Agents do not get `app/models`.
- **Two effect primitives — not one `step()`.** They share only that they
  happen inside a workflow and Remuda records them. A unified `Remuda.step`
  would still need a tag or a magic first argument. Recording is one
  `workflow_steps` table with a `kind`; the script never says “step.”
  - `Remuda.tool("server.method", **args)` — deterministic MCP call on the
    **host**, operator credentials, structured result (Ruby hash). Split on
    the first dot: server `plane`, tool `list_work_items`. Resolve URL from
    `mcp.json`; auth from host `.env` (self-hosted MCP) or later the gateway
    tuple. JSON-RPC `tools/call`. Raise on error so the run fails.
  - `Remuda.agent(prompt, ...)` — one **sandboxed** Pi invocation (see
    [02-runner](./02-runner.md)). Result is boring: `output`, `session_id`,
    `usage`, `ok`. `actionable?` / `.html` are **not** gem API. If a workflow
    wants structure, the prompt asks for JSON and the script parses
    `result.output`.
- **No method_missing tool proxy for v1.**
- **Recording is built into those methods.** They look up an ambient current
  run (`Remuda::Current` — ActiveSupport::CurrentAttributes or fiber-local),
  insert a step, return the result. The script never sees a run id. If
  someone runs `ruby .remuda/workflows/triage.rb` with no Current, the methods still
  work; they just don’t record.
- **The runner owns the run record.** `remuda run` and tick call the same
  `Runner`: open a `workflow_runs` row (`status: running`, `trigger: manual`
  or `schedule`), set Current, `chdir`, `load` the script, rescue into the
  row, ensure-close (`ok` / `error`, `finished_at`). CLI is a thin shell over
  that object.
- **No resume, no step retry.** Exception = the run is `error`. Steps already
  written stay (audit). Next tick is a new run. Idempotence is the workflow
  author’s problem.
- **Inputs:** `remuda run triage --input k=v` → runner sets `Remuda.inputs`
  to a hash before `load`. Not ARGV.
- **Timeouts:** the sandbox enforces the Pi wall clock (container `/wait`).
  Do not `Timeout.timeout` around the script. A coarser run-level reaper can
  come later.
- **Overlap:** if a run of the same workflow is still `running` when the next
  tick is due — skip and record (`status: skipped`). Not an engine; a check
  on the runner.
- **Turing-completeness is accepted.** The sandbox boundary on `Remuda.agent`
  does the real safety work; the script runs on the host with the operator's
  authority. `.remuda/workflows/` is read-only inside that sandbox so the
  model cannot rewrite the script.

## How it runs

```
remuda run [path] triage
        │
        ▼
   Runner                  # gem, on the host
     migrate-on-boot (05)
     open workflow_runs row (status: running)
     set Current.run
     chdir agent dir
     load .remuda/workflows/triage.rb
        Remuda.tool(...)  → MCP on host → insert workflow_steps (kind: tool)
        Remuda.agent(...) → Docker/Pi   → insert workflow_steps (kind: agent)
     rescue → store error
     ensure → close row (ok / error, finished_at)
```

`.remuda/bin/tick` is the same `Runner` with `trigger: "schedule"`.

**`workflow_runs`:** workflow name, status (`running` / `ok` / `error` /
`skipped`), timestamps, exception class/message, `inputs` json, `trigger`.

**`workflow_steps`:** `workflow_run_id`, `kind` (`tool` | `agent`), position,
name, input json, output json, error, timestamps, usage/session_id for agent.

## Sketch

```ruby
# .remuda/workflows/triage.rb — plain Ruby
items = Remuda.tool("plane.list_work_items",
                    project_id: Remuda.inputs[:project_id],
                    state_group: "backlog")

items.each do |item|
  verdict = Remuda.agent(<<~PROMPT)
    Triage this arrival per the triage skill.
    Return JSON: { "actionable": bool, "html": string }
    #{item.inspect}
  PROMPT
  data = JSON.parse(verdict.output)
  next unless data["actionable"]

  Remuda.tool("plane.create_comment",
              project_id: Remuda.inputs[:project_id],
              work_item_id: item[:id],
              comment_html: data["html"])
end
```

## Not in this feature

- A workflow class / DSL / `step` wrapper
- Recording as something the script calls
- Executing the script inside the container (that’s Pi, not Ruby)
- Partial-step retry, resume, compensation

## Open

- How tool schemas surface for arguments/errors (MCP `tools/list` vs fail
  at call time).
- Exact `Remuda.agent` result class fields beyond `output` / `session_id` /
  `usage` / `ok`.
- Per-run wall clock besides the sandbox `/wait`.
- Shared helper conventions beyond `.remuda/workflows/lib/` + `require_relative`.
