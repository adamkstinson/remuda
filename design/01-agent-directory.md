# 01 — The agent directory

An agent is a directory. It holds everything that makes *this* agent this
agent, and nothing that runs agents in general.

## Settled

- **Identity, not machinery.** The directory contains identity files, skills,
  tools config, workflows, channel bindings, secrets slots, memory, and state.
  The engine, runner, adapters, and CLI live in the `remuda` gem. `bin/*` are
  binstubs.
- **A lockfile binds mind to machine.** `Gemfile` + `Gemfile.lock` name the
  harness version this agent expects. Two directories with the same identity
  and different lockfiles are the same mind on different harness versions.
- **Instance data is SQLite** at `db/remuda.sqlite3` (gitignored) — see
  [05-state](./05-state.md).
- **Portable as a specification**: copy the directory, `bundle install`, run.
  Air-gap via `vendor/bundle`, which is a deployment mode, not the
  architecture.

## Proposed layout

```
my-agent/
├── AGENTS.md               ← identity (Pi reads this)
├── .pi/                    ← agent-level Pi config: skills, extensions, tools
├── mcp.json                ← MCP servers this agent uses
├── workflows/              ← plain Ruby workflow scripts (03)
├── channels.yml            ← channel bindings (06)
├── Gemfile / Gemfile.lock  ← names the harness version
├── bin/                    ← binstubs only (run, tick, console)
├── .env                    ← secrets slots (gitignored)
├── db/remuda.sqlite3       ← runs, steps, schedules, channel state (gitignored)
└── files/                  ← the agent's working files / memory
```

## Open

- Exact split between Remuda's shipped Pi profile and the directory's `.pi/`
  (what merges, what overrides — see [02-runner](./02-runner.md)).
- Does `remuda new` take archetypes (`--scaffold ops`), and what do they seed?
- What `state/`-era files from Agentworks survive as files vs move to SQLite
  (agent-authored memory like Ops's `.jsonl` logs stays files — confirm rule:
  *harness state in the DB, agent memory in files*).
- Naming: `AGENTS.md` vs `CLAUDE.md` compatibility (Pi convention wins; do we
  symlink for tool compatibility?).
