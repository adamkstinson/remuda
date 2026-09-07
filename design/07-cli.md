# 07 — CLI

One user-facing tool. It generates, runs, schedules, inspects, and updates.
It is a thin shell over the gem's library surface — never a second
implementation.

## Settled

- **One gem, one binary**: `remuda`. No per-component CLIs (the agent-box /
  agent-workflows / agent-channels split was for independently sellable
  components; that's not this product).
- **Command shape (v1)**:

  ```
  remuda new PATH [--scaffold NAME]     scaffold an agent directory (01)
  remuda console                        interactive Pi in the sandbox (02)
  remuda run [PATH] WORKFLOW [--input k=v]   run + record (03)
  remuda schedule [PATH] WORKFLOW --cron EXPR (04)
  remuda unschedule [PATH] WORKFLOW
  remuda schedules [PATH]               list schedules + next occurrences
  remuda runs [PATH] [WORKFLOW]         recent runs; `remuda run show ID` detail
  remuda db:migrate [PATH]              if we choose explicit migration (05)
  remuda channels start|stop [PATH]     channel supervisor (06)
  remuda generate GENERATOR NAME        write YOUR files (workflow, skill, …)
  remuda version
  ```

- **PATH defaults to the current directory** when inside an agent (presence of
  `Gemfile` naming remuda + `AGENTS.md`); commands work from inside or
  outside.
- **Generators write agent files, never framework code.** `generate workflow
  digest` writes `workflows/digest.rb` from a template; `generate skill x`
  writes a skill skeleton. No engine code is ever written into a directory.

## Open

- Option parsing / generator library: hand-rolled optparse (Agentworks style)
  vs thor — thor buys generator conventions (`create_file`, diffs on
  conflict) at the cost of a dependency. Lean thor.
- `remuda update`: what does upgrading an agent mean beyond `bundle update`
  — re-run generators with diff/skip like `rails app:update`?
- `remuda doctor`: environment checks (podman present, image pulled, cron
  installed, Pi login state) — v1 or later?
- Generator inventory for v1: `workflow`, `skill`, what else?
- Exit codes / JSON output mode for scripting against the CLI.
