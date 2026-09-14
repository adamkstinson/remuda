# Remuda

**Rails for agent harnesses.** One Ruby gem that builds, runs, maintains, and
optimizes agent directories — the way Rails does for apps.

*A remuda is the working string of saddle horses on a ranch: the pool you rope
today's mount from, ride, and turn back. Many horses, one outfit. Many agents,
one harness.*

## The thesis

**An agent is a directory.** A new directory with a different `AGENTS.md`,
different skills, tools, and plugins is a different agent — the same way a new
Rails app directory is a different app. The directory holds everything that
makes *this* agent this agent:

- identity — `AGENTS.md` / `CLAUDE.md`
- skills, tools / MCP config, plugins
- *this* agent's workflows and channel bindings
- secrets slots, memory, working files
- run history and state, in a local SQLite file
- a `Gemfile.lock` naming the harness version it expects

**The harness is a gem.** The machine that runs any agent — workflow engine,
scheduler, sandbox runner, channel adapters, MCP client, the CLI itself — lives
in `remuda` on the machine, never copied into the directory. `bin/run` and
`bin/tick` are binstubs. Different directory ⇒ different agent. Different
lockfile ⇒ same mind on a different harness version.

This is the Rails split: the framework in the gem, your app in the directory,
the lockfile binding them. It was decided deliberately (Agentworks ADR-005)
over the scaffolder model, where the engine was stenciled into every agent and
immediately began to drift.

## What it does

```bash
remuda new ./ops              # a runnable agent directory: identity, Gemfile, binstubs
remuda                        # from inside: Pi in the sandbox
remuda console                # Rails console: this agent's SQLite (runs, steps, schedules)
remuda run ops triage         # run workflows/triage.rb once, now, recorded
remuda schedule ops operate --cron "0 7 * * *"   # cron tick, no daemon
remuda generate skill triage  # generators write YOUR files, not framework copies
bundle update remuda          # the harness moves; the agent's identity doesn't
```

Runs, steps, schedules, and channel state are rows in the agent's own SQLite
database (ActiveRecord in the gem), not loose JSON files. Channels (Telegram,
Planet, Slack…) are adapters in the gem, bound per-agent by config.

## Design choices

**Pi is the runtime.** Remuda runs exactly one coding agent: Pi. Pi accepts
the other model providers' logins, so *model* stays a per-agent config value
while *harness* stops being a dimension — one entrypoint, one wire format, one
container image, instead of a matrix of claude/opencode/codex adapters. Remuda
ships its own curated Pi configuration as part of the harness; the agent
directory layers its own skills, extensions, and tools on top. (Framework
config vs app config — the Rails/Rack move.)

**Interactive and unattended share one sandbox.** The sandbox is Pi only.
A workflow's `Remuda.agent(...)` call and bare `remuda` (interactive) use the
*same* container image, credential hygiene, and host config — one runs Pi with
a prompt and exits, the other attaches your terminal. Workflow Ruby and SQLite
stay on the host. Working on an agent no longer means escaping the sandbox its
scheduled runs live in. `remuda console` is the other Rails door: IRB on this
agent's database, not Pi.

**Workflows are plain Ruby, not a DSL.** Agentworks began with YAML, drifted
into a DSL, and ended up running `.rb` scripts anyway. Remuda skips to the end:
a workflow is an ordinary Ruby script in `workflows/` with two library calls —
`Remuda.tool(...)` for a deterministic MCP call, `Remuda.agent(...)` for one
sandboxed Pi invocation. No step vocabulary, no guards, no YAML. Recording is
ambient: those methods write `workflow_steps` themselves. The *runner* owns the
run: `remuda run` opens the `workflow_runs` row, executes the script, captures
output/error/duration, closes the row. The scheduler is a cron expression
attached to a script name, nothing more.

## Boundaries

- **Not a SaaS.** No cloud, no control plane. Your machine, your directories.
- **Not an agent framework.** Remuda doesn't decide how agents reason. Behavior
  is the directory's files — customer-owned.
- **Not multi-tenant.** Fleet is many directories and one gem, not a server.

## Lineage

Remuda is the successor to **Agentworks** (`~/Projects/agentworks` — agent-box,
agent-workflows, agent-channels). That project proved the engine, the YAML/Ruby
workflow format, the box seam, and the channel protocol, but stenciled its
runtime into each agent (`.agentworks/lib/**`). Remuda takes the code and
leaves the architecture: one repo, one gem, no stencil, no backwards
compatibility. The live Agentworks agents (Ops, Assistant) keep running their
frozen copies until they are migrated onto the gem.

## Status

Named and shaped; not yet built. First milestone: one test agent whose
directory contains no engine code, that runs a scheduled workflow through the
gem and writes a `workflow_runs` row to its own SQLite file.
