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
    "plane": { "url": "https://mcp.example.com" }
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

By default `Remuda.agent` does not pass `--provider` / `--model`. Pi uses
`defaultProvider` / `defaultModel` from that `settings.json` (set in
interactive `remuda` with `/model`, Ctrl+S). Remuda does not declare a
second default. Override it for one call with `provider:` / `model:`:

```ruby
Remuda.agent(prompt)                                                # Pi's default
Remuda.agent(prompt, provider: "anthropic", model: "claude-sonnet-4-5")
Remuda.agent(prompt, model: "gpt-4.1")                              # Pi resolves the provider
```

The override is recorded on the `agent` step's input. `.env` `PI_PROVIDER` /
`PI_MODEL` are not a fallback for it.

Put credentials in `<agent>/.pi/agent/auth.json` (login inside `remuda`), or
synthesize them from the agent `.env` (`PI_PROVIDER` plus that provider’s API
key — which key to write, not which model to run).

```bash
# in the agent's .env (gitignored) — auth shortcut only
PI_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
```

Do not put third-party SaaS tokens in `.env`. Self-hosted MCP tokens may live
there; the file is never mounted into the sandbox.

#### MCP from inside the sandbox

The images ship Remuda's Pi profile: the `pi` on `PATH` loads an MCP client
([pi-mcp-adapter](https://www.npmjs.com/package/pi-mcp-adapter), pinned in
`image/Dockerfile`) and points it at `/agent/mcp.json` and nothing else. A
directory declares its servers in its root `mcp.json`, the same file
`Remuda.tool` reads. Not `.pi/mcp.json` and not `.mcp.json`, which the box
ignores. Client options sit next to the URL:

```json
{
  "settings": { "toolPrefix": "server" },
  "mcpServers": {
    "plane": {
      "url": "https://plane.example.com/mcp",
      "headers": { "X-Plane-Key": "{{PLANE_API_KEY}}" },
      "directTools": true
    }
  }
}
```

With `directTools: true` Pi sees `plane_list_projects` and the rest as its
own tools. Without it Pi reaches them through one `mcp` proxy tool.

The sandbox reaches MCP servers that declare `headers` through a per-run
forwarder on the host. `mcp.json` stays the declaration and is not changed on
disk. For each run Remuda writes a copy and mounts it read-only over
`/agent/mcp.json`:

- a server with `headers` points at
  `http://host.docker.internal:<port>/<run token>/<server>` and carries no
  headers. The forwarder fills the declared headers (`{{VAR}}` from the agent
  `.env`, then the process environment, the same rule as `Remuda.tool`) and
  passes the request, streaming, to the real URL.
- a server with no `headers` keeps its URL; the agent calls it directly.
- a declared variable with no value is not sent blank. The forwarder answers
  that server with `401` and names the missing variable.

A token the workflow sets on the process before `Remuda.agent` (for example a
refreshed `GMAIL_MCP_TOKEN`) reaches the forwarder the same way. The forwarder
starts with the container and stops when it exits, for `Remuda.agent` and for
interactive `remuda`. It listens on the Docker bridge address, and every path
starts with a random token only that run's `mcp.json` holds. `.env` is still
never mounted. On a host with a firewall (ufw), allow the bridge in
(`ufw allow in on docker0`) or the box cannot reach the forwarder.

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
  listed = msg.files.filter_map do |file|
    next unless file.path
    dest = File.join("files", file.name)
    FileUtils.mkdir_p("files")
    FileUtils.cp(file.path, dest)
    dest
  end
  prompt = msg.text.to_s
  prompt += "\n\nAttached files:\n" + listed.map { |p| "- #{p}" }.join("\n") if listed.any?
  result = Remuda.agent("Reply to #{msg.sender_name}: #{prompt}")
  outbound = Dir.glob("files/outbound/*")
  channels.send_message(jid: msg.jid, text: result.output, thread_id: msg.thread_id, files: outbound)
end
channels.start_all
sleep
```

A message carries `jid` (where to reply: `mattermost:<channel_id>`),
`thread_id` (the root post; reply with it to stay in the thread),
`sender_name`, `text`, and `files` (attachments already downloaded to disk).
`send_message(..., files: ["photo.jpg"])` uploads those paths. Inbound arrives over the Mattermost websocket and
goes to `on_message` on one worker thread, in order, so a long agent run
does not stall the socket. While that handler runs, the bot shows as typing
in the channel and the thread. The adapter reconnects with backoff. After a
reconnect it backfills posts it missed, so a dropped connection does not
drop a message.

Outbound-only (a workflow posting a digest):

```ruby
mm = Remuda.channels[:mattermost]
mm.send_message(jid: mm.dm_jid("adam"), text: "Nightly run finished.")
mm.send_message(jid: mm.channel_jid(team: "team", channel: "ops"), text: "…")
```

### Microsoft Teams

Teams works the other way around from Mattermost. Microsoft's Bot Connector
POSTs every message to an HTTPS endpoint you host, and the bot replies over
REST. No SDK; the transport is `Remuda::Channels::Teams`.

```yaml
# .remuda/channels.yml
transports:
  teams:
    app_id_env: TEAMS_APP_ID          # defaults shown; the values live in .env
    app_secret_env: TEAMS_APP_SECRET
    tenant_id_env: TEAMS_TENANT_ID
    # mentions_only: true             # personal chats, and posts that @mention the bot
    # allow: [<entra object id>]      # only these senders reach the agent
```

The channel is a Rack app: it responds to `call(env)`. Serve it from a host
app (`mount Remuda.channels(dir)[:teams], at: "/api/messages"`) or with any
Rack server. TLS in front of it (Caddy, …) is yours:

```ruby
# config.ru in the agent directory
require "remuda"
teams = Remuda.channels(__dir__)[:teams]
teams.on_message do |msg|
  result = Remuda.agent("Reply to #{msg.sender_name}: #{msg.text}")
  teams.send_message(jid: msg.jid, text: result.output, thread_id: msg.thread_id)
end
teams.start!
run teams
```

Every POST must carry a Bot Framework JWT: an RS256 token signed by a key from
Microsoft's OpenID metadata, issued by `https://api.botframework.com`, with
your app id as audience and a `serviceUrl` claim that matches the activity.
Anything else gets `401`. A replayed activity id is dropped. The POST is
answered `200` at once, and `on_message` runs on one worker thread.

`jid` is `teams:<conversation id>`, `thread_id` is the root message of a
channel thread (or the activity id in a chat), and `sender_name` is the
display name. `allow:` matches Entra object ids, not names. To message
someone first (a digest, "shipment ready for review"), the bot needs a
conversation reference from an earlier message in that conversation. References
are stored in the agent's SQLite (`channel_sessions`), so
`send_message(jid:, text:)` still works after a restart. Text and Markdown
only: no Adaptive Cards and no files in v1.

One-time setup:

1. Microsoft Entra ID: a **single-tenant** app registration. Note the
   application (client) id and tenant id, and create a client secret.
2. An Azure Bot resource on that app id. Enable the Microsoft Teams channel
   and set the messaging endpoint to `https://<your host>/api/messages`.
3. A Teams app package (manifest plus two icons) with `bots[].botId` = the
   app id and scope `personal` (plus `team` / `groupChat` if wanted). Upload
   it for pilot users or publish it to the org catalog. The tenant's Teams
   admin must allow custom apps.

Put the three values in the agent's `.env` as `TEAMS_APP_ID`,
`TEAMS_APP_SECRET`, `TEAMS_TENANT_ID`.

### Channels as a tool

When `channels.yml` binds at least one transport, `channels.send_message` is a
tool like any MCP tool. `remuda tools` lists it, and with no bindings it is not
there.

From a workflow script it goes through `Remuda.tool` and is recorded as a
`workflow_steps` row (`kind: "tool"`, `name: "channels.send_message"`). It
raises when no channel delivers:

```ruby
Remuda.tool("channels.send_message", jid: "mattermost:abc", text: "Digest ready.",
                                     thread_id: nil, files: ["files/digest.pdf"])
# => { "thread_id" => "…" }
```

Inside the sandbox Pi sees it as `channels_send_message`. The runner adds a
`channels` server to the box's `mcp.json` that points at the per-run
forwarder, and the forwarder answers it on the host with the agent's bound
channels. `MATTERMOST_TOKEN` never enters the container. Each send is a step
on the run that started the box. The agent attaches files by their in-box
path (`/agent/files/report.pdf`). Paths outside the agent directory, `.env`,
and `.remuda/` are refused. To have the agent answer where it was asked, put
the `jid` and `thread_id` in the prompt:

```ruby
Remuda.agent(<<~PROMPT)
  #{msg.sender_name} asked: #{msg.text}
  When you are done, reply with channels_send_message to jid #{msg.jid}, thread_id #{msg.thread_id}.
PROMPT
```

A server named `channels` in `mcp.json` takes precedence over the built-in one.

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

No daemon. Install that one line on the host crontab. Tick finds unpaused rows
with `next_occurrence <= now`, advances `last_occurrence` / `next_occurrence`
first, then fires the workflow through the same Runner (`trigger: "schedule"`).
A run that outlasts the minute is not seen as due again by the next tick, and
when two ticks race for one occurrence only one wins it. If that workflow still
has a `running` row, the new run is `skipped`.

```bash
remuda tick           # inside the agent
remuda tick ./ops
```

### Images

Build the sandbox images from `image/` when the Dockerfiles change. They are
not rebuilt when the gem bumps:

```bash
docker build -t remuda-pi:latest image/
docker build -t remuda-coding:latest -f image/Dockerfile.coding image/
ruby -Ilib test/integration/mcp_client.rb   # Pi in the image can call MCP
```

## Interactive Pi (sandboxed)

From **inside** an agent directory, no subcommand:

```bash
remuda
```

That is `docker run --rm -it` of the image in `.remuda/image` (default
`remuda-pi:latest`). Same sandbox `Remuda.agent` uses. The directory you ran
from is mounted at `/agent` read-write, except `.env` (masked, empty in the
box) and `.remuda/` (masked, apart from `.remuda/workflows/`). Workflows are
writable here and read-only for `Remuda.agent`.

The sandbox adds `host.docker.internal` → host gateway. Set
`REMUDA_EXTRA_HOSTS=hostname:ip[,...]` for more. `mcp.json` may list both a
local `url` and a `tailscale_url`. When `REMUDA_LOCAL_HOSTNAME` matches this
machine, Remuda uses `url`; otherwise `tailscale_url`. Host-side
`Remuda.tool` rewrites `host.docker.internal` to `127.0.0.1`.

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

## License

MIT. See [LICENSE](LICENSE).
