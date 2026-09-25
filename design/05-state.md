# 05 — State

Harness state in the database, agent memory in files.

## Settled

- **One SQLite file per agent, in that agent’s directory:**
  `.remuda/db/remuda.sqlite3` (gitignored). Ops →
  `ops/.remuda/db/remuda.sqlite3`. Assistant →
  `assistant/.remuda/db/remuda.sqlite3`. Nothing shared, nothing in the gem
  install. WAL mode so tick, a channel daemon, and a manual run may write
  concurrently without corrupting the file.
- **ActiveRecord in the gem.** Model *classes* (`WorkflowRun`, `WorkflowStep`,
  `Schedule`, …) and migrations live under `lib/remuda/` (see
  [09-gem](./09-gem.md)). The agent directory has the data file, not
  `app/models`, not schema code.
- **Migrate-on-boot.** Every `remuda run` / `tick` / `console` connects,
  applies any migrations this gem version knows about, then proceeds. First
  run creates the file and tables. `bundle update remuda` picks up new
  columns on the next run. No human `db:migrate` in the normal path (an
  explicit command can exist as an escape hatch). The lockfile already names
  which gem — and therefore which migrations — exist.
- **Core tables** (replacing Agentworks's JSON files):

  | Table | Replaces |
  |---|---|
  | `workflow_runs` | `state/results/<wf>/<ts>_<id>.json` header |
  | `workflow_steps` | that file's `steps[]` — now written live by the methods |
  | `schedules` | `state/schedules/*.json` |
  | `channel_cursors` | `state/channels/<ch>.json` offsets |
  | `channel_sessions` / `channel_messages` | `planet-sessions.json` etc. |

- **The boundary rule:** rows the *harness* writes (runs, steps, schedules,
  cursors) live in the DB. Files the *agent* writes as its own memory (e.g.
  Ops's `state/operate/*.jsonl` ledgers, Pi’s `.pi/agent/sessions`) stay files
  in the directory — they are identity-adjacent, not harness plumbing. The
  sandbox never mounts `.remuda/db/` ([02-runner](./02-runner.md)); only the
  host gem writes these rows. `.remuda/` as a whole is not a sandbox mount.
  Pi does not write SQLite.
- **Query.** `remuda console` on `workflow_runs` / `workflow_steps` (parsed
  from Pi JSONL: text, tool events, usage). Pi chats live in
  `.pi/agent/sessions`. Do not make SQLite Pi’s session store. An optional
  later index of JSONL into tables is a read model, not the writer.
- **Agents do not add tables.** No extra migrations per directory. Agent data
  is files until proven otherwise.
- **Inspection is `remuda console`** — IRB with this agent's models loaded
  ([07-cli](./07-cli.md)). Not Pi.

## Open

- Retention: run/step rows grow forever; prune policy or "disk is cheap,
  query planner copes"? (Agentworks kept every JSON result; nobody minded.)
- Import path: one-shot importer for existing Agentworks JSON so Ops/Assistant
  migrate with history intact.
- Step payload size: full tool results inline, or truncate + blob/file
  spillover past a threshold?
- Optional SQL index of `.pi/agent/sessions` JSONL (read model only).
