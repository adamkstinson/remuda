# 04 — Scheduler

A cron expression attached to a script name. Nothing more.

## Settled

- **No daemon.** One system crontab line per agent runs `.remuda/bin/tick` every
  minute (carried from Agentworks — it worked). Tick is fast, reads due
  schedules, fires them, exits.
- **Schedules are rows** in the agent's `schedules` table (workflow name,
  cron, timezone, inputs, paused, last/next occurrence). Managed by CLI:
  `remuda schedule ops operate --cron "0 7 * * *"`, `remuda unschedule`,
  `remuda schedules` to list.
- **Cron parsing via fugit** (proven in Agentworks).
- **Tick fires the runner**, so scheduled runs are recorded identically to
  manual `remuda run` (see [03-workflows](./03-workflows.md)).
- **Overlap:** previous run of the same workflow still `running` when the
  next is due — skip and record (`status: skipped`). Not concurrent, not queued.

## Open
- **Catch-up policy**: machine asleep through an occurrence — fire on wake or
  drop? Propose: drop, record the miss; workflows that care poll their own
  world state anyway.
- **Tick installation**: does `remuda new`/`schedule` write the crontab line
  itself or print it for the operator? (Agentworks was manual; a `remuda
  schedule --install-cron` might be the honest middle.)
- Per-schedule inputs and jitter — needed at all in v1?
