# Remuda — design docs

One doc per feature. Each carries what is **settled** and what is **open**.
The project one-pager is [`../README.md`](../README.md). Decisions that close
an open item get recorded as ADRs in `../adr/` when we start cutting code.

| Doc | Feature |
|---|---|
| [01-agent-directory.md](./01-agent-directory.md) | The agent directory — layout, identity, lockfile |
| [02-runner.md](./02-runner.md) | The runner — Pi-only, sandbox, `remuda console` |
| [03-workflows.md](./03-workflows.md) | Workflows — plain Ruby, self-recording classes |
| [04-scheduler.md](./04-scheduler.md) | Scheduler — cron, tick, schedules table |
| [05-state.md](./05-state.md) | State — SQLite + ActiveRecord, migrations |
| [06-channels.md](./06-channels.md) | Channels — adapters in the gem, bindings in the agent |
| [07-cli.md](./07-cli.md) | CLI — commands, generators |
| [08-secrets.md](./08-secrets.md) | Secrets — model-provider and tool credential topology |

Identified but not yet drafted: observability & the optimize loop, fleet &
migration, distribution & versioning (gem ↔ image ↔ Pi pinning).
