# 11 — Rails

A Rails app may host a **fleet of Remuda agents** under `agents/` and invoke
one of them from application code. Rails stays the application (HTTP, records,
jobs). Remuda stays the harness (directories, sandbox Pi). This is not a
Rails engine and not “Remuda features inside ActiveRecord.”

Motivation: a CRM (or any Rails app) wants `after_commit` to hand work to a
named agent — Sky Dog–shaped — without blocking the request or sharing a
database connection.

## Settled

- **Two processes.** The web/worker process owns Rails. `Remuda.agent` runs
  Pi in Docker against **one agent directory**. The app never becomes an
  agent. An agent directory never becomes a Rails app.
- **Fleet root is `agents/` at the Rails root** (overridable). Each child
  directory is a normal Remuda agent (`AGENTS.md` + a Gemfile that names
  `remuda`). Identity, `.pi/`, `mcp.json`, `.env`, `files/`, and
  `.remuda/` stay per agent. Unchanged from [01-agent-directory](./01-agent-directory.md).
- **Name, then prompt.** Application code names the child (`"enrichment"`),
  not a filesystem path. The gem resolves `#{fleet_root}/enrichment` and
  requires `Directory.agent?`. Unknown names raise.
- **Jobs, not callbacks.** A model may `after_commit { enqueue }`. The job
  calls Remuda. `Remuda.agent` is a Docker one-shot (wall clock on the
  container). It does not run inside the request or inside the AR
  transaction.
- **The gem does not ship ActiveJob.** Queue adapter, retries, and payload
  shape are the app’s. The gem ships named lookup + `Remuda.agent(prompt,
  agent: name)`. The README shows a five-line job.
- **No Remuda SQLite in the Rails process.** `Remuda::Db.connect` uses
  `ActiveRecord::Base.establish_connection` and would steal the app DB.
  In-process `Remuda.agent` / `Remuda.tool` **must not** connect, migrate, or
  write `workflow_steps` unless a dedicated connection (not `AR::Base`) exists
  later. Today: no `Current.run` from Rails; no `Runner` / `tick` /
  `console` in-process. Standalone `bundle exec remuda run agents/foo hello`
  still uses the agent’s sqlite, in a CLI process, as now.
- **Pi does not load Rails.** Sandbox mounts are unchanged
  ([02-runner](./02-runner.md)). The job serializes what the agent needs
  (ids, JSON, a URL). The agent talks back over MCP or HTTP if it needs
  live records. Do not mount `app/` into the box.
- **One remuda version: the app’s Gemfile.** Nested agent Gemfiles remain
  the `Directory.agent?` marker and document intent. The running bundle is
  Rails’s. Per-agent lockfiles are for *standalone* agents, not for a fleet
  inside an app.
- **Minimal Railtie, not an engine.** If `Rails` is defined and
  `Rails.root.join("agents")` exists, set `Remuda.fleet_root` to that path
  on boot. No routes, no middleware, no generators required for v1, no
  `isolate_namespace`.
- **Secrets stay split.** Agent `.env` is never mounted. Rails credentials
  stay in Rails. Do not merge the files.

## Layout

```
my_app/                         # Rails root (the git repo)
├── Gemfile                     # gem "remuda" (path or git)
├── config/application.rb
├── app/models/customer.rb      # after_commit → perform_later
├── app/jobs/agent_job.rb       # app-owned; calls Remuda.agent
└── agents/
    ├── enrichment/             # full agent (01)
    │   ├── AGENTS.md
    │   ├── Gemfile             # gem "remuda" (marker)
    │   ├── mcp.json
    │   ├── .pi/
    │   ├── files/
    │   └── .remuda/
    └── outreach/
        └── …
```

`Directory.agent?` is still “this directory,” not “walk up until Rails.”
`Dir.pwd` inside a job is usually the Rails root, which is **not** an
agent — hence the `agent:` keyword.

## Invocation

Existing:

```ruby
Remuda.agent(prompt)   # Current.agent_dir || Dir.pwd
```

Add:

```ruby
Remuda.fleet_root = Rails.root.join("agents")   # Railtie does this when present

Remuda.agent(prompt, agent: "enrichment")
# → Directory.find(File.join(fleet_root, "enrichment"))
# → Sandbox.run(that_dir, prompt)
# → does not establish_connection
```

```ruby
# app/models/customer.rb
after_commit :enqueue_enrichment, on: :create

def enqueue_enrichment
  AgentJob.perform_later("enrichment", id)
end
```

```ruby
# app/jobs/agent_job.rb  — belongs to the app
class AgentJob < ApplicationJob
  def perform(agent_name, customer_id)
    customer = Customer.find(customer_id)
    Remuda.agent(
      "Enrich customer #{customer.id}: #{customer.as_json}",
      agent: agent_name
    )
  end
end
```

`Remuda.tool` gets the same `agent:` keyword so a job can call MCP as that
agent (host-side, that agent’s `mcp.json` / `.env`) without chdir.

CLI from the app root (optional in the same slice if cheap):

```bash
bundle exec remuda run agents/enrichment hello
# or, once fleet_root is set / inferred from ./agents:
bundle exec remuda run --agent enrichment hello
```

Bare `remuda` (interactive Pi) from the Rails root is an error unless a
path/name is given. Do not treat the Rails app as an agent.

## ActiveRecord boundary

| Call | In a Rails process | In `remuda run` CLI |
|---|---|---|
| `Remuda.agent(prompt, agent:)` | Docker only; no AR | same, plus step row if `Current.run` |
| `Remuda.tool(..., agent:)` | MCP on host; no AR | same, plus step row if `Current.run` |
| `Remuda::Runner` / `tick` / `console` | **forbidden** | agent sqlite via `Db.connect` |

Invariant to test: after `Remuda.agent` from a process that already has
`ActiveRecord::Base.connected?`, the connection spec is unchanged.

A later slice may give Remuda its own AR connection handler (not
`Base.establish_connection`) so Rails could record steps. Not this slice.

## Out of scope

- Mounting `app/`, `config/`, or the app DB into the sandbox
- `remuda tick` / schedules driven by ActiveJob (host crontab still owns tick)
- Streaming Pi into ActionCable / Turbo
- Generating agents from `rails generate`
- Sharing one `.pi/agent` or one `.env` across the fleet

## Open

- Exact CLI flag vs path for named agents from an app root (`--agent` vs
  `agents/name` as PATH).
- Whether `Remuda.tool` without `agent:` inside a job should raise instead
  of using `Dir.pwd` (Rails root has no `mcp.json`).
- Whether a failing Pi (`ok == false`) is the job’s problem (retry) or a
  raised error from `Remuda.agent`. Today the method returns a result;
  keep that unless we add `exception: true`.
- Optional `Remuda::AgentJob` if ActiveJob is already loaded — convenience
  vs “the gem does not ship jobs.” Default: do not ship it.

## Build order

1. `Remuda.fleet_root` + `Directory` named lookup; `agent:` on
   `Remuda.agent` / `Remuda.tool`. Raise if the child is not an agent.
2. Test: dummy `agents/foo` tree, no Rails, named invoke, **AR connection
   unchanged**.
3. Tiny Railtie: set `fleet_root` when `Rails.root/agents` exists.
4. README: Gemfile, layout, `after_commit` → job example, AR warning.
5. CLI name resolution from a fleet root (if not folded into 1).
