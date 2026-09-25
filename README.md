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
bundle exec remuda version    # this repo is the gem, not an agent
```

In an agent's `.remuda/Gemfile` (after `remuda new`, point at the git source or a
path):

```ruby
source "https://rubygems.org"

gem "remuda", git: "https://github.com/adamkstinson/remuda.git"
# gem "remuda", path: "../remuda"   # local checkout
```

```bash
bundle install
```

Inside an agent directory the command is `remuda`. Not `bundle exec remuda`.
`bundle exec` is only for working on this gem from its own clone.

`PATH` on commands is an agent directory. Omit it when the current directory
already is one (`.remuda/Gemfile` is present).

## Scaffold an agent

```bash
remuda new ./ops
cd ops
```

Or scaffold the current directory: `remuda new`. Existing files are left alone.

That writes identity and slots, not engine code:

```
ops/
├── AGENTS.md              identity
├── mcp.json               MCP server URLs only (no secrets)
├── .env.example           copy to .env (gitignored); host-only
├── .pi/                   this agent's Pi config / skills
├── files/                 working files (agent memory)
└── .remuda/
    ├── Gemfile            harness pin (not the app Gemfile)
    ├── workflows/         plain Ruby scripts
    ├── channels.yml       channel bindings
    └── db/                remuda.sqlite3 created on first run/tick/console
```

There is no `lib/` harness copy in the agent. Edit `.remuda/Gemfile` so `remuda`
resolves (git or path), then `bundle install` with `BUNDLE_GEMFILE=.remuda/Gemfile`.

## Run a workflow

A workflow is `.remuda/workflows/<name>.rb` — ordinary Ruby, no DSL.

```ruby
# .remuda/workflows/hello.rb
puts "hello"
```

```bash
remuda run hello           # inside the agent
remuda run ./ops hello     # from elsewhere
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
    "plane": { "url": "https://mcp.example.com/mcp" }
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
remuda tools                      # server.method names
remuda tools list_work_items      # description + schema
remuda tools ./ops plane.list_work_items
```

### `Remuda.agent(prompt)`

One-shot **sandboxed** Pi in `remuda-pi:latest` unless the agent has
`.remuda/image` (one line, the tag). Coding agents set that file to
`remuda-coding:latest`. `GH_TOKEN` / `GITHUB_TOKEN` from the host `.env` is
injected when present; `.env` is still not mounted. Result has `output`,
`ok`, `exit_code`, and related fields.

```ruby
# .remuda/workflows/ping.rb
result = Remuda.agent("Reply with the single word pong.")
puts result.output
```

Model auth is **per agent**. The sandbox sets `PI_CODING_AGENT_DIR` to
`/agent/.pi/agent` (the host agent’s `.pi/agent/`). That folder is this
agent’s Pi user dir (`auth.json`, sessions, model catalog, `settings.json`).
It does **not** pass `--offline`. The agent `.env` is never mounted. Host
`~/.pi/agent` is not used.

`Remuda.agent` does not pass `--provider` / `--model`. Pi uses
`defaultProvider` / `defaultModel` from that `settings.json` (set in
interactive `remuda` with `/model`, Ctrl+S). Remuda does not declare a
second default.

Put credentials in `<agent>/.pi/agent/auth.json` (login inside `remuda`), or
synthesize them from the agent `.env` (`PI_PROVIDER` plus that provider’s API
key — which key to write, not which model to run).

```bash
# in the agent's .env (gitignored) — auth shortcut only
PI_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
```

Do not put third-party SaaS tokens in `.env`. Self-hosted MCP tokens (e.g.
planet-mcp) may live there; the file is never mounted into the sandbox.

## Channels

How a person reaches an agent, and how the agent answers. Transports live in
the gem, bindings in the agent's `.remuda/channels.yml`, tokens in its `.env`.
Mattermost is the transport today.

```yaml
# .remuda/channels.yml
transports:
  mattermost:
    url: https://chat.example.com
    token_env: MATTERMOST_TOKEN   # the bot's personal access token, in .env
    # mentions_only: true         # DMs and posts that tag @bot (threads too)
    # ignore_bots: true           # never answer another bot
    # allow: [adam]               # only these usernames reach the agent
```

`Remuda.channels` builds the registry from that file. An agent with no
bindings gets an empty registry, and every call on it is a no-op.

```ruby
channels = Remuda.channels
channels.on_message do |msg|
  result = Remuda.agent("Reply to #{msg.sender_name}: #{msg.text}")
  channels.send_message(jid: msg.jid, text: result.output, thread_id: msg.thread_id)
end
channels.start_all
sleep
```

A message carries `jid` (where to reply: `mattermost:<channel_id>`),
`thread_id` (the root post; reply with it to stay in the thread),
`sender_name`, and `text`. Inbound arrives over the Mattermost websocket and
goes to `on_message` on one worker thread, in order, so a long agent run
does not stall the socket. The adapter reconnects with backoff. After a
reconnect it backfills posts it missed, so a dropped connection does not
drop a message.

Outbound-only (a workflow posting a digest):

```ruby
mm = Remuda.channels[:mattermost]
mm.send_message(jid: mm.dm_jid("adam"), text: "Nightly run finished.")
mm.send_message(jid: mm.channel_jid(team: "dark-horse", channel: "ops"), text: "…")
```

Not shipped yet: a `remuda` command that supervises channels, and durable
channel state (the cursor is in memory; pass `since:` to resume). See
[design/06-channels.md](design/06-channels.md).

## Console

IRB on this agent's SQLite — not Pi.

```bash
remuda console
remuda console ./ops
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
remuda schedule hello --cron "0 7 * * *"
remuda schedule ./ops hello --cron "10 */6 * * *" --timezone America/Los_Angeles
remuda schedules
remuda unschedule hello
```

That inserts (or replaces) a `schedules` row in the agent's SQLite. One row per
workflow name. `--timezone` defaults to UTC. The command prints the row and a
copy-pasteable crontab line that runs Remuda tick (not `.agentworks/bin/tick`):

```cron
* * * * * cd /path/to/ops && remuda tick >> /path/to/ops/.remuda/tick.log 2>&1
```

No daemon. Install that one line on the host crontab. Tick fires unpaused rows
with `next_occurrence <= now` through the same Runner (`trigger: "schedule"`),
then advances `last_occurrence` / `next_occurrence`. If that workflow still has
a `running` row, the new run is `skipped`.

```bash
remuda tick           # inside the agent
remuda tick ./ops
```

## Interactive Pi (sandboxed)

From **inside** an agent directory, no subcommand:

```bash
remuda
```

That is `docker run --rm -it` of the image in `.remuda/image` (default
`remuda-pi:latest`). Same sandbox `Remuda.agent` uses. The directory you ran
from is mounted at `/agent` read-write.

The sandbox adds `host.docker.internal` → host gateway and
`host.example.test` → `127.0.0.1` (so containers do not
resolve `box` to themselves). `mcp.json` may list both a local
`url` and a `tailscale_url`. On box Remuda uses `url`; everywhere
else it uses `tailscale_url`. The sandbox gets `REMUDA_BROWSER_MCP_URL`.
Host-side `Remuda.tool` rewrites `host.docker.internal` to `127.0.0.1`.

Model auth is **per agent**, same as `Remuda.agent`. The sandbox sets
`PI_CODING_AGENT_DIR` to `/agent/.pi/agent` (the host agent’s `.pi/agent/`).
It does **not** copy host `~/.pi/agent/auth.json`. A login inside the box
writes to the agent’s `.pi/agent/` on the host and survives the container.

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

Not shipped: a channels command (the library is above). There is no `remuda generate` — add workflow scripts and skills as ordinary files.

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
