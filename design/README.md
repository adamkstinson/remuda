# Remuda — design docs

One doc per feature. Each carries what is **settled** and what is **open**.
The project one-pager is [`../README.md`](../README.md). Decisions that close
an open item get recorded as ADRs in `../adr/` when we start cutting code.

| Doc | Feature |
|---|---|
| [01-agent-directory.md](./01-agent-directory.md) | The agent directory — layout, identity, lockfile |
| [02-runner.md](./02-runner.md) | The runner — Pi-only sandbox; `Remuda.agent` and bare `remuda` |
| [03-workflows.md](./03-workflows.md) | Workflows — plain Ruby, `Remuda.tool` / `Remuda.agent` |
| [04-scheduler.md](./04-scheduler.md) | Scheduler — cron, tick, schedules table |
| [05-state.md](./05-state.md) | State — SQLite in the agent dir, AR models in the gem |
| [06-channels.md](./06-channels.md) | Channels — adapters in the gem, bindings in the agent |
| [07-cli.md](./07-cli.md) | CLI — bare `remuda` is Pi; `console` is IRB |
| [08-secrets.md](./08-secrets.md) | Secrets — gateway seam, two planes, client vs laptop |
| [09-gem.md](./09-gem.md) | The gem — tree, models-in-gem, build order |
| [fleet-inventory.md](./fleet-inventory.md) | Live Agentworks ticks on box (input to fleet & migration) |
| [10-fleet-migration.md](./10-fleet-migration.md) | Fleet cutover order, gem gaps, leftover ticks |

Identified but not yet drafted: observability & the optimize loop,
distribution & versioning (gem ↔ image ↔ Pi pinning).
