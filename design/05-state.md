# 05 — State

Harness state in the database, agent memory in files.

## Settled

- **One SQLite file per agent**: `db/remuda.sqlite3`, WAL mode (tick, channel
  daemon, and a manual run may write concurrently — JSON files never handled
  this honestly).
- **ActiveRecord, models and migrations in the gem.** The agent directory
  never contains schema code. `remuda db:migrate` (or migrate-on-boot —
  friendlier for this class of tool; the lockfile says which migrations
  exist).
- **Core tables** (replacing Agentworks's JSON files):

  | Table | Replaces |
  |---|---|
  | `workflow_runs` | `state/results/<wf>/<ts>_<id>.json` header |
  | `workflow_steps` | that file's `steps[]` — now written live by the classes |
  | `schedules` | `state/schedules/*.json` |
  | `channel_cursors` | `state/channels/<ch>.json` offsets |
  | `channel_sessions` / `channel_messages` | `planet-sessions.json` etc. |

- **The boundary rule**: rows the *harness* writes (runs, steps, schedules,
  cursors) live in the DB. Files the *agent* writes as its own memory (e.g.
  Ops's `state/operate/*.jsonl` ledgers) stay files in the directory — they
  are identity-adjacent, not harness plumbing.

## Open

- Migrate-on-boot vs explicit `db:migrate` — pick one and say why.
- Retention: run/step rows grow forever; prune policy or "disk is cheap,
  query planner copes"? (Agentworks kept every JSON result; nobody minded.)
- Do agents get to add their *own* tables in the same DB (engine-style extra
  migrations per directory), or is agent data always files until proven
  otherwise? Propose: files until proven otherwise.
- Import path: one-shot importer for existing Agentworks JSON so Ops/Assistant
  migrate with history intact.
- Step payload size: full tool results inline, or truncate + blob/file
  spillover past a threshold?
