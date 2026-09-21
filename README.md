# Remuda

**Rails for agent harnesses.** One Ruby gem that builds, runs, and maintains
agent directories — the way Rails does for apps.

An **agent is a directory**. The harness lives in the gem, never copied into
that directory. **Pi** is the only coding-agent runtime. Workflows are plain
Ruby.

*A remuda is the working string of saddle horses on a ranch: the pool you rope
today's mount from, ride, and turn back. Many horses, one outfit. Many agents,
one harness.*

v1 is the CLI and workflow runner below. Internals live in [`design/`](design/).

## Requirements

- Ruby 3.2 or later (4.x is fine)
- Bundler
- Docker, only if you use sandboxed Pi (`remuda` with no subcommand, or `Remuda.agent`)

This repo is private: [adamkstinson/remuda](https://github.com/adamkstinson/remuda).

## Install

From a clone of this repo:

```bash
git clone https://github.com/adamkstinson/remuda.git
cd remuda
bundle install
bundle exec remuda version    # 0.1.0
```

In an agent's `Gemfile` (after `remuda new`, point at the git source or a
path):

```ruby
source "https://rubygems.org"

gem "remuda", git: "https://github.com/adamkstinson/remuda.git"
# gem "remuda", path: "../remuda"   # local checkout
```

```bash
bundle install
bundle exec remuda help
```

`PATH` on commands is an agent directory. Omit it when the current directory
already is one (`AGENTS.md` plus a `Gemfile` that names `remuda`).

## Scaffold an agent

```bash
bundle exec remuda new ./ops
cd ops
```

Or scaffold the current directory: `remuda new`. Existing files are left alone.

That writes identity and slots, not engine code:

```
ops/
├── AGENTS.md              identity
├── Gemfile
├── mcp.json               MCP server URLs only (no secrets)
├── .env.example           copy to .env (gitignored); host-only
├── .pi/                   this agent's Pi config / skills
├── files/                 working files (agent memory)
└── .remuda/
    ├── workflows/         plain Ruby scripts
    └── db/                remuda.sqlite3 created on first run/tick/console
```

There is no `lib/` harness copy in the agent. Edit `Gemfile` so `remuda`
resolves (git or path), then `bundle install`.

## Run a workflow

A workflow is `.remuda/workflows/<name>.rb` — ordinary Ruby, no DSL.

```ruby
# .remuda/workflows/hello.rb
puts "hello"
```

```bash
bundle exec remuda run hello           # inside the agent
bundle exec remuda run ./ops hello     # from elsewhere
```

That opens a `workflow_runs` row (`trigger: "manual"`), `load`s the script,
then closes the row (`ok` or `error`). Inspect it in console (below).

## Workflow APIs

Two library calls. They run on the **host** (your credentials). Recording is
ambient when the Runner is in play.

### `Remuda.tool("server.method", **args)`

Host-side MCP call. Split on the first dot: server `plane`, tool
`list_work_items`. URL comes from `mcp.json`; token from the agent's `.env`
(`PLANE_MCP_TOKEN` or `MCP_TOKEN`). Raises on error.

```json
{
  "mcpServers": {
    "plane": { "url": "https://work.darkhorse.so/mcp" }
  }
}
```

```ruby
# .remuda/workflows/triage.rb
items = Remuda.tool("plane.list_work_items", project_id: "…", state_group: "backlog")
items.each { |item| warn item.inspect }
```

`mcp.json` `headers` are sent on the call (`{{VAR}}` from the agent's `.env`).
See the catalog while writing a workflow:

```bash
bundle exec remuda tools                      # server.method names
bundle exec remuda tools list_work_items      # description + schema
bundle exec remuda tools ./ops plane.list_work_items
```

### `Remuda.agent(prompt)`

One-shot **sandboxed** Pi in the `remuda-pi` image (same image as bare
`remuda`). Result has `output`, `ok`, `exit_code`, and related fields.

```ruby
# .remuda/workflows/ping.rb
result = Remuda.agent("Reply with the single word pong.")
puts result.output
```

The runner copies host `~/.pi/agent/auth.json` (or `REMUDA_PI_AUTH`) into a
per-invocation tmpdir and bind-mounts it at `/tmp/pi` (`PI_CODING_AGENT_DIR`).
It does **not** pass `--offline`. The agent `.env` is never mounted.

Do not put third-party SaaS tokens in `.env`. Self-hosted MCP tokens (e.g.
planet-mcp) may live there; the file is never mounted into the sandbox.

## Console

IRB on this agent's SQLite — not Pi.

```bash
bundle exec remuda console
bundle exec remuda console ./ops
```

Top-level constants: `WorkflowRun`, `WorkflowStep`, `Schedule`.

```ruby
WorkflowRun.last
WorkflowRun.where(status: "error").order(id: :desc).limit(5)
WorkflowStep.where(workflow_run_id: 1).order(:position)
```

`Remuda.tool` / `Remuda.agent` work here too. They do not write steps unless a
run is in progress (`Current.run`).

## Schedule a workflow

```bash
bundle exec remuda schedule hello --cron "0 7 * * *"
bundle exec remuda schedule ./ops hello --cron "10 */6 * * *" --timezone America/Los_Angeles
bundle exec remuda schedules
bundle exec remuda unschedule hello
```

That inserts (or replaces) a `schedules` row in the agent's SQLite. One row per
workflow name. `--timezone` defaults to UTC. The command prints the row and a
copy-pasteable crontab line that runs Remuda tick (not `.agentworks/bin/tick`):

```cron
* * * * * cd /path/to/ops && bundle exec remuda tick >> /path/to/ops/.remuda/tick.log 2>&1
```

No daemon. Install that one line on the host crontab. Tick fires unpaused rows
with `next_occurrence <= now` through the same Runner (`trigger: "schedule"`),
then advances `last_occurrence` / `next_occurrence`. If that workflow still has
a `running` row, the new run is `skipped`.

```bash
bundle exec remuda tick           # inside the agent
bundle exec remuda tick ./ops
```

## Interactive Pi (sandboxed)

From **inside** an agent directory, no subcommand:

```bash
bundle exec remuda
```

That is `docker run --rm -it` of `remuda-pi:<gem-version>`. Same sandbox
`Remuda.agent` uses. Workflow Ruby and SQLite stay on the host.

| Survives on the host | Dies when the container exits |
|---|---|
| `AGENTS.md`, `mcp.json` | `/tmp` (tmpfs): Pi home, auth, default sessions |
| `.pi/`, `files/` | the container rootfs (`--rm`) |
| `.remuda/workflows/` (writable in this interactive door) | |

`.env` and `.remuda/db/` are **not** mounted.

Provider login is **host** `pi` (`~/.pi/agent/auth.json`). Remuda copies that
file into the sandbox for the invocation; a login *inside* the box is lost
when the container exits.

## CLI (v1)

| Command | What |
|---|---|
| `remuda new [PATH]` | Scaffold an agent directory |
| `remuda run [PATH] WORKFLOW` | Run `.remuda/workflows/WORKFLOW.rb` once, recorded |
| `remuda tick [PATH]` | Fire due schedules through the same Runner |
| `remuda schedule [PATH] WORKFLOW --cron EXPR` | Insert/replace a schedules row; print crontab line |
| `remuda unschedule [PATH] WORKFLOW` | Delete that workflow's schedules row |
| `remuda schedules [PATH]` | List schedules and the crontab line |
| `remuda tools [PATH] [NAME]` | List MCP tool names from `mcp.json`, or print one tool |
| `remuda console [PATH]` | IRB on this agent's SQLite |
| `remuda` | Sandboxed Pi (must already be in an agent directory) |
| `remuda version` | Gem version |
| `remuda help` | Subcommands (`console` and bare `remuda` are omitted from help) |

Not shipped: channels. There is no `remuda generate` — add workflow scripts and skills as ordinary files.

## Boundaries

- **Not a SaaS.** Your machine, your directories.
- **Not an agent framework.** Behavior is the directory's files.
- **Not multi-tenant.** Many directories, one gem.

## Lineage

Successor to Agentworks. That project proved the engine and then stenciled it
into every agent. Remuda keeps the ideas, not the stencil, and is not
backwards compatible. Live Ops/Assistant agents stay on Agentworks until
migrated.

Design notes (not required to use v1): [`design/`](design/).
