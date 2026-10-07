---
name: remuda
description: How to use Remuda, the harness this agent directory runs on. The remuda CLI (run, schedule, tick, tools, console, sandboxed Pi), writing workflows in .remuda/workflows/, and the Ruby API (Remuda.tool, Remuda.agent, Remuda.channels). Use when creating, running, scheduling, or debugging a workflow, calling MCP tools from Ruby, or working out where a file in this directory belongs.
---

# Remuda

An agent is a directory, and the `remuda` gem is the harness that runs it.
Workflows are plain Ruby run on the host. Thinking happens in Pi, sandboxed in
Docker. Nothing from the gem is copied into the directory.

## Where you are

```
AGENTS.md            identity. Always this name, never CLAUDE.md
mcp.json             MCP servers: URLs plus {{VAR}} header placeholders, no secrets
.env                 secrets (host only, never in the sandbox, never commit)
.pi/                 Pi config and skills; .pi/agent/ is this agent's Pi user dir
files/               working files and memory
.remuda/
  Gemfile            pins the remuda version
  workflows/*.rb     workflow scripts; helpers in workflows/lib/
  channels.yml       channel bindings (Mattermost, Teams)
  image              optional: sandbox image tag (default remuda-pi:latest)
  db/remuda.sqlite3  runs, steps, schedules (host only)
```

**Inside the sandbox** (cwd `/agent`, as in bare `remuda` or `Remuda.agent`):
there is no Ruby, no `remuda`, and no Docker. You can read and write files,
and workflows too when the session is interactive. `.env` reads as empty and
`.remuda/` holds only `workflows/`. Running anything is the operator's job:
write the workflow, then tell them the exact command. MCP servers from
`mcp.json` are your tools (`plane_list_work_items`, …). When channels are
bound, `channels_list_channels` (everywhere you can post, with a jid each)
and `channels_send_message` are two of them.

**On the host** (cwd is the agent directory): use the CLI below. Type
`remuda`, not `bundle exec remuda`. The binstub finds `.remuda/Gemfile`.

## CLI

`PATH` is an agent directory. Leave it out when you are standing in one.

```bash
remuda new [PATH]                          # scaffold; never overwrites existing files
remuda run [PATH] WORKFLOW                 # run .remuda/workflows/WORKFLOW.rb once, recorded
remuda tools [PATH]                        # list server.tool names from mcp.json (+ channels)
remuda tools [PATH] NAME                   # one tool's description and input schema
remuda schedule [PATH] WORKFLOW --cron "0 7 * * *" [--timezone America/Los_Angeles]
remuda schedules [PATH]                    # list schedules plus the crontab line to install
remuda unschedule [PATH] WORKFLOW
remuda tick [PATH]                         # fire due schedules (cron runs this every minute)
remuda console [PATH]                      # IRB on this agent's SQLite. Not Pi
remuda                                     # interactive Pi in the sandbox (inside the dir only)
remuda version
```

- **Scheduling.** `remuda schedule` writes a row; it does not install cron.
  Install the printed line once per agent:
  `* * * * * cd /path/to/agent && remuda tick >> .../.remuda/tick.log 2>&1`.
  `--timezone` defaults to UTC. Tick claims an occurrence before running it.
  If the previous run of that workflow is still `running`, the new one is
  recorded as `skipped`.
- **Inputs.** `remuda run` has no `--input` flag. Inputs come from a schedule
  row's `inputs` and reach the script as `Remuda::Current.inputs`.
- **Tools.** Run `remuda tools NAME` before you call a tool you have not used.
  It shows the real argument names.

## Writing a workflow

A workflow is `.remuda/workflows/<name>.rb`: ordinary Ruby with no class, no
DSL, and no step wrapper. The runner opens a `workflow_runs` row, sets
`Remuda::Current`, `chdir`s to the agent root, and `load`s the script. An
uncaught exception marks the run `error`. Steps already written stay, and
there is no resume. The next run starts fresh, so make workflows idempotent.

```ruby
# .remuda/workflows/triage.rb
require "json"
require_relative "lib/plane_helpers"   # .remuda/workflows/lib/plane_helpers.rb

project = "…"
items = Remuda.tool("plane.list_work_items", project_id: project)["results"]

items.each do |item|
  result = Remuda.agent(<<~PROMPT)
    Triage this work item. Reply with JSON only: {"actionable": bool, "comment_html": string}
    #{JSON.generate(item)}
  PROMPT
  raise "agent failed: #{result.output}" unless result.ok

  verdict = JSON.parse(result.output[/\{.*\}/m])
  next unless verdict["actionable"]

  Remuda.tool("plane.create_comment", project_id: project,
              work_item_id: item["id"], comment_html: verdict["comment_html"])
end
```

Then `remuda run triage`, and look at the result in `remuda console`.

## Ruby API

**`Remuda.tool("server.tool", **args)`** is an MCP call on the host with the
operator's credentials. The server comes from `mcp.json`. Header
`{{VAR}}`s fill from `.env`, then `ENV`. `SERVER_MCP_TOKEN` / `MCP_TOKEN` in
`.env` becomes a bearer token. It returns the tool's JSON parsed into a
**string-keyed** Hash or Array (`item["id"]`, not `item[:id]`). It raises on
error, and retries HTTP 429 up to five times. Inside a run it records a step
(`kind: "tool"`).

**`Remuda.tools(dir)`** returns `[{server:, name:, description:, input_schema:}, …]`.

**`Remuda.agent(prompt, provider: nil, model: nil)`** runs Pi once in the
sandbox, with this directory at `/agent`. It returns `output` (the assistant's
final text), `ok`, `exit_code`, `session_id`, `usage`, and `image`. It does
**not** raise: check `ok`. Inside a run it records a step (`kind: "agent"`).

- The agent cannot see the script, `.env`, or the database. Put everything it
  needs in the prompt, or in `files/`, and name the paths (`/agent/files/x.md`).
- For structured output, ask for JSON and parse `result.output`. Nothing in
  the gem does it for you.
- The model is Pi's default in `.pi/agent/settings.json`. Pass `provider:` /
  `model:` to override it for one call.
- MCP calls from inside the sandbox go through a host forwarder that adds the
  declared headers, so the key never enters the box.

**`Remuda.channels(dir = nil)`** builds the registry from
`.remuda/channels.yml`. Use `send_message(jid:, text:, thread_id: nil, files: nil)`
to send, or `on_message { |msg| … }` with `start_all` to listen. A message
has `jid`, `thread_id`, `sender_name`, `text`, and `files`. Reply with the
same `jid` and `thread_id` to stay in the thread. From a workflow, prefer
`Remuda.tool("channels.send_message", jid:, text:, thread_id:)`, which records
a step and raises if nothing delivered. `Remuda.tool("channels.list_channels")`
returns `{ "channels" => [{ "jid", "name", "transport", "kind" }] }`, flat
across every bound transport — do not hard-code channel ids.

**`Remuda::Current`** holds `agent_dir`, `run` (the `WorkflowRun`, nil
outside the runner), and `inputs`. Outside `remuda run` / `tick` nothing is
recorded, but every call still works.

## Inspecting runs

```ruby
# remuda console
WorkflowRun.order(id: :desc).limit(5)                  # workflow, status, trigger, times
WorkflowRun.where(status: "error").last.exception_message
WorkflowStep.where(workflow_run_id: 12).order(:position).map { |s| [s.kind, s.name, s.error] }
Schedule.all                                           # cron, timezone, next_occurrence
```

A run's status is `running`, `ok`, `error`, or `skipped`. A step's `output`
holds the tool result, or `{text, image, exit_code}` for an agent step.
Pi's full transcripts are in `.pi/agent/sessions/`.

## Rules

- Secrets go in `.env` only. `mcp.json` uses `{{VAR}}`, never the value.
- Ruby helpers go in `.remuda/workflows/lib/`, never `app/` or `lib/` at the
  root. Agent memory goes in `files/`. Never copy gem code into the directory.
- Do not add database tables. Harness state is rows; agent memory is files.
- Do not wrap scripts in `Timeout.timeout`. The sandbox has its own wall clock.
- New skills go in `.pi/skills/<name>/SKILL.md`. There is no `remuda generate`.
