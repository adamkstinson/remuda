# 09 — The gem

One repo, one gem, one binary. The agent directory never contains engine
code. This is the tree; channels are in it even if we build them later.

## Settled

- **Models live in the gem, data in the agent.** `lib/remuda/models/` is Ruby
  classes. `.remuda/db/remuda.sqlite3` in the agent directory is rows. Same split as
  Rails, except the “app code” *is* the gem — there is no `app/models` in
  Ops or Assistant.
- **One `lib/remuda/`, not component gems.** Workflows, sandbox, scheduler,
  CLI share a tree. The workflow-feature file list was a slice, not a second
  package.
- **Image co-versioned with the gem** (`image/Dockerfile` → `remuda-pi:<gem-version>`).
- **Generators write agent files only** (`lib/remuda/templates/`).

## Tree

```
remuda/
├── README.md
├── design/
├── adr/                       # when we start cutting code
├── remuda.gemspec
├── Gemfile
├── Rakefile
├── .gitignore
│
├── exe/
│   └── remuda                 # the one binary
│
├── image/
│   └── Dockerfile             # remuda-pi:<gem-version>
│
├── lib/
│   ├── remuda.rb              # Remuda.tool, .agent, .inputs
│   └── remuda/
│       ├── version.rb
│       ├── cli.rb             # default task = sandboxed Pi
│       ├── directory.rb       # find agent, paths, .env read (host)
│       ├── current.rb         # ambient run / agent
│       ├── db.rb              # sqlite WAL, migrate-on-boot
│       ├── runner.rb          # remuda run / tick → load script
│       ├── mcp.rb             # host MCP client
│       ├── sandbox.rb         # Docker Engine API, mounts, wait
│       ├── scheduler.rb       # fugit, due schedules, skip overlap
│       ├── generator.rb       # remuda new only
│       │
│       ├── models/
│       │   ├── workflow_run.rb
│       │   ├── workflow_step.rb
│       │   ├── schedule.rb
│       │   ├── channel_cursor.rb      # later
│       │   ├── channel_session.rb     # later
│       │   └── channel_message.rb     # later
│       │
│       ├── migrate/           # AR migrations; never copied into agents
│       ├── templates/agent/   # remuda new
│       ├── pi/                # shipped Pi profile
│       └── channels/          # later
│
└── test/
    └── dummy/                 # fixture agent (no engine code)
```

**Not in the agent directory:** anything under `lib/`, `migrate/`, `image/`.

**In the agent directory** (written by `remuda new`; skip any path that
already exists): at root — `AGENTS.md`, `mcp.json`, `.pi/`, `Gemfile` /
`Gemfile.lock`, `.env` / `.env.example`, `files/`. Under `.remuda/` —
`db/remuda.sqlite3`, `workflows/`, `channels.yml`, `bin/` binstubs.

v1 implements this tree minus `channels/` and the channel models.

## Build order (first slice)

1. DB + models + `Runner` that `load`s a script which only `puts` — assert a
   `workflow_runs` row in the dummy agent.
2. `Remuda.tool` against MCP — assert a `tool` step.
3. `Remuda.agent` once sandbox exists — assert an `agent` step.
4. `remuda run` and tick both call `Runner`.

(1) is the README milestone: no engine in the directory, a scheduled
workflow, a row in that agent’s SQLite.
