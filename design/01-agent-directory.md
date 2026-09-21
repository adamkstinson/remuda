# 01 — The agent directory

An agent is a directory. It holds everything that makes *this* agent this
agent, and nothing that runs agents in general.

## Settled

- **Identity, not machinery.** The directory contains identity files, skills,
  tools config, workflows, channel bindings, secrets slots, memory, and state.
  The engine, runner, adapters, and CLI live in the `remuda` gem. Binstubs
  live under `.remuda/bin/`.
- **Two layers.** Root is what you and Pi look at. `.remuda/` is the harness
  instance (db, workflows, channels, binstubs). Never mount all of `.remuda/`
  into the sandbox — `db/` stays host-only (see [02-runner](./02-runner.md)).
- **Always `AGENTS.md`.** Never `CLAUDE.md`. No compatibility symlink.
- **A lockfile binds mind to machine.** `Gemfile` + `Gemfile.lock` at the
  agent root name the harness version this agent expects. Two directories with
  the same identity and different lockfiles are the same mind on different
  harness versions.
- **Instance data is SQLite** at `.remuda/db/remuda.sqlite3` in *this* agent’s
  directory (gitignored) — see [05-state](./05-state.md). Model classes live
  in the gem, not here. No `app/models`.
- **Harness state in the DB, agent memory in files.** Ledgers, notes, and
  other identity-adjacent files stay under `files/` (or
  `.remuda/workflows/lib/` for Ruby helpers). Pi’s **user folder** is
  `.pi/agent/` in this directory (auth, sessions, model catalog) — see
  [02-runner](./02-runner.md). Agents do not add tables.
- **Portable as a specification**: copy the directory, `bundle install`, run.
  Air-gap via `vendor/bundle`, which is a deployment mode, not the
  architecture.

## Layout

```
my-agent/
├── AGENTS.md                 ← identity (Pi reads this). Always this name.
├── mcp.json                  ← MCP servers this agent uses
├── .pi/                      ← project Pi: skills, extensions; user dir at .pi/agent/
├── Gemfile / Gemfile.lock    ← names the harness version
├── .env                      ← secrets slots (gitignored)
├── files/                    ← the agent's working files / memory
└── .remuda/                  ← harness instance (not mounted as a whole)
    ├── db/remuda.sqlite3     ← runs, steps, schedules, channel state (gitignored)
    ├── workflows/            ← plain Ruby workflow scripts (03)
    ├── channels.yml          ← channel bindings (06)
    └── bin/                  ← binstubs only (remuda, run, tick)
```

**Root** — what you or Pi look at: `AGENTS.md`, `mcp.json`, `.pi/`, `Gemfile`,
`.env`, `files/`.

**`.pi/agent/`** — this agent’s Pi user folder (`PI_CODING_AGENT_DIR`). Same
shape as `~/.pi/agent` (`auth.json`, `sessions/`, `models-store.json`,
`settings.json`). Not a copy of the operator’s login. `auth.json` is
gitignored.

**`.remuda/`** — harness instance: db, workflows, channels, binstubs.

## Open

- Exact split between Remuda's shipped Pi profile and the directory's `.pi/`
  (what merges, what overrides — see [02-runner](./02-runner.md)).
- Does `remuda new` take archetypes (`--scaffold ops`), and what do they seed?
- What `state/`-era files from Agentworks survive as files vs move to SQLite
  on migration (the rule is settled; the inventory is not).
