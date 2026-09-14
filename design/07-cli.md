# 07 — CLI

One user-facing tool. It generates, runs, schedules, inspects, and updates.
It is a thin shell over the gem's library surface — never a second
implementation.

## Settled

- **One gem, one binary**: `remuda`. No per-component CLIs (the agent-box /
  agent-workflows / agent-channels split was for independently sellable
  components; that's not this product).
- **Bare `remuda` is the agent.** No subcommand, inside an agent directory:
  start Pi in the sandbox (see [02-runner](./02-runner.md)). Same box
  `Remuda.agent` uses. Extra args may pass through to Pi later
  (`remuda "summarize files/"`); not required for v0. Outside an agent
  directory: error / help. `remuda -h` / `help` never starts Pi.
- **`remuda console` is IRB**, not Pi. Rails-console-shaped: this agent's
  gem context and SQLite loaded — `WorkflowRun.last`, steps, schedules,
  session history. Same environment a workflow gets, so models *and*
  `Remuda.tool` / `Remuda.agent` are available (inspect and poke). A
  read-only flag is later, not v1.
- **Command shape (v1)**:

  ```
  remuda                            sandboxed Pi (inside an agent dir) (02)
  remuda new [PATH] [--scaffold NAME]  scaffold cwd, or child PATH (01)
  remuda console                    IRB against this agent's DB (05)
  remuda run [PATH] WORKFLOW [--input k=v]   Runner#run + record (03)
  remuda schedule [PATH] WORKFLOW --cron EXPR (04)
  remuda unschedule [PATH] WORKFLOW
  remuda schedules [PATH]           list schedules + next occurrences
  remuda runs [PATH] [WORKFLOW]     recent runs; `remuda run show ID` detail
  remuda db:migrate [PATH]          escape hatch; migrate-on-boot is the path (05)
  remuda channels start|stop [PATH] channel supervisor (06)
  remuda generate GENERATOR NAME    write YOUR files (workflow, skill, …)
  remuda version
  remuda help
  ```

- **PATH defaults to the current directory** when inside an agent (presence of
  `Gemfile` naming remuda + `AGENTS.md`); commands work from inside or
  outside. Bare `remuda` (Pi) requires being inside; it is not
  `remuda [PATH]`.
- **`remuda new` with no PATH scaffolds the current directory.** `remuda new
  ops` creates child `ops/` (if needed) and scaffolds that. Existing files
  are left alone — no overwrite, no duplicate. Collision with bare `remuda`
  does not arise: `new` is a subcommand.
- **Generators write agent files, never framework code.** `generate workflow
  digest` writes `.remuda/workflows/digest.rb` from a template; `generate
  skill x` writes a skill skeleton under `.pi/`. No engine code is ever
  written into a directory.

No-args default task = sandbox Pi; every named subcommand stays a subcommand.

## Open

- Option parsing / generator library: hand-rolled optparse (Agentworks style)
  vs thor — thor buys generator conventions (`create_file`, diffs on
  conflict) at the cost of a dependency. Lean thor.
- `remuda update`: what does upgrading an agent mean beyond `bundle update`
  — re-run generators with diff/skip like `rails app:update`?
- `remuda doctor`: environment checks (Docker daemon, image present, cron
  installed, Pi login state) — v1 or later?
- Generator inventory for v1: `workflow`, `skill`, what else?
- Exit codes / JSON output mode for scripting against the CLI.
- `remuda console` backend: irb vs pry; `remuda c` alias like Rails?
