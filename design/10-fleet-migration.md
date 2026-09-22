# 10 — Fleet & migration

Cut the live Agentworks fleet on adam-server over to Remuda. Input:
[fleet-inventory.md](./fleet-inventory.md) (captured 2026-09-20). Sibling
project REMU shipped remuda **0.1.0**; this project implements whatever
cutover still needs in the gem, then moves directories.

No Agentworks compatibility layer. Agentworks stays frozen at
`~/Projects/agentworks`. We do not email clients about the harness change.
We do not write to client product live systems.

## What “this workspace is on Remuda” means

A stranger inspecting adam-server can check all four. Any miss means it is
not done.

1. **Layout.** The workspace has `AGENTS.md` (not `CLAUDE.md` as identity)
   and `.remuda/workflows/` (plain Ruby). No `.agentworks/bin/tick` on the
   crontab path.
2. **Crontab.** User `adam` crontab has exactly one tick line for that path,
   and it is Remuda, not Agentworks:

   ```
   * * * * * cd <path> && remuda tick >> <path>/.remuda/tick.log 2>&1
   ```

   There is
   **no** `.agentworks/bin/tick` line for that path.
3. **Schedule.** `.remuda/db/remuda.sqlite3` has a `schedules` row for each
   live cadence (workflow, cron, timezone, paused, next_occurrence).
4. **Evidence.** A successful tick left a `workflow_runs` row
   (`trigger: "schedule"`, `status: "ok"`), inspectable with
   `remuda console` / `WorkflowRun.last` — not only a log line.

## Cutover order

Move one workspace at a time. Do not overlap crontab ticks (Agentworks and
Remuda both ticking the same path double-fires work). Swap is: Remuda
schedule + Remuda crontab line in, Agentworks crontab line out, in that
session.

### 0. Gem gaps (before any live swap)

Ship in **this** gem, then cut. Do not leave these on Agentworks. Detail in
[Gaps vs remuda 0.1.0](#gaps-vs-remuda-010). Until they land, no workspace
moves.

### 1. Remuda Agent (`~/Projects/remuda/projects/remu`) — first

Dogfood. Plane REMU. `poll-and-execute` `10 */6 * * *`. No channels. Engine
today: `claude`. This is RFLT-3. A stranger executing the rest of the fleet
starts here because a broken harness on remu does not take down Ops or a
client.

### 2. Remuda Fleet (`~/Projects/remuda/projects/rflt`)

Same shape as remu (`poll-and-execute` `25 */4 * * *`, no channels). Move
immediately after remu proves a scheduled `workflow_runs` row.

### 3. Dark Horse poll-and-execute brains without channels

Same rewrite, different Plane project and cron.

- Assistant — `~/Agents/Assistant` — work items in OPS — `50 */4 * * *`
- Client Tool Auth — `~/Clients/harbor-point/tool-auth` — HPAUT — `5 */4 * * *`
- Receipts and Expense Processing — `~/Clients/harbor-point/receipts-expenses` — HPRCP — `15 */4 * * *`
- Subcontractor Payment Tracking — `~/Clients/harbor-point/payment-tracking` — HPPAY — `35 */4 * * *`
- Echo Sources — `~/Clients/echonomy/echo-sources` — ECSRC — `5 */4 * * *`
- Echo — `~/Clients/echonomy/echo` — ECAPP — `25 */4 * * *`
- SkyDog CRM Build — `~/Clients/sky-dog/skydog-crm-build` — SDCRM — **paused**
  (`cron_paused` `15 */4 * * *`). Migrate the schedule as `paused: true` so
  Remuda tick is a no-op until Adam unpauses. Do not unpause as part of
  cutover.

### 4. Nested / custom workflow runtimes

Not Plane poll-and-execute. Rewrite their Ruby workflows; do not invent a
Plane project.

- receipts-agent — `~/Clients/harbor-point/receipts-expenses/receipts-agent`
  — `process-receipts` `0 */6 * * *`, engine today `opencode`
- SkyDog CRM agent (Asset 2) — `~/Clients/sky-dog/agent` — gmail/sources
  cadences, engine already `pi`

### 5. Ops last among live ticks

`~/Agents/Ops` — OPS. Workflows `triage`, `operate`, `execute`. Channels:
telegram + planet. Engine today `opencode`. **Do not move Ops until gem
channels can bind telegram and planet** (see gaps). Ops is the coordinator;
it moves after the dogfood pair and after channels exist in the gem.

### 6. Leftover archived ticks — do not migrate

Remove Agentworks crontab (if any). Do **not** add a Remuda tick. Do **not**
rewrite workflows. Directories may stay on disk until Ops/Adam archive them.

- HPSUB — crontab line still present, directory **gone**. Delete the crontab
  line. That is the whole cutover for this row.
- ECDEP `~/Clients/echonomy/echo-hosted-deployment` — crontab already
  removed 2026-08-24. Leave the dir. No Remuda schedule.
- ECCAP `~/Clients/echonomy/capital-systems-specs` — same as ECDEP.
- ECDOF `~/Clients/echonomy/digital-office` — not in crontab; last tick
  2026-09-01. Leave the dir. No Remuda schedule.
- `~/Clients/harbor-point/award-subcontract-skill` — schedule on disk, not
  crontab-ticked. Leave it. No Remuda schedule.

Directories that have `.agentworks/bin/tick` but no crontab line (archived
engagement agents, CUBL, nested Harbor Point helpers) are not fleet. Ignore.

## Gaps vs remuda 0.1.0

Shipped today (`remuda help`): `new`, `run`, `tick`, `tools`,
`version`. Also present but not in help: `console`, bare `remuda` (sandbox
Pi). `tick` fires due `schedules` rows through the same Runner as `run`.
`Remuda.tool` already sends `mcp.json` `headers` with `{{VAR}}` filled from
the agent `.env` (enough for planet-mcp `X-Plane-Key`).

The project brief puts these in the **gem**, not left on Agentworks:

### Tick-from-cron — gem

`tick` exists; installing a live tick does not.

- **`remuda schedule` / `unschedule` / `schedules`.** Insert/pause/list
  `schedules` rows (cron, timezone, inputs). Today the only way to create a
  row is console/SQL. Cutover cannot depend on that.
- **Crontab install.** One line per agent, same shape Agentworks used
  (minute tick, real cadence in the DB). `remuda schedule --install-cron`
  (or equivalent) writes or prints that line. Open in [04-scheduler](./04-scheduler.md)
  is hereby settled for fleet: the command may print the line for the
  operator to install; it must be copy-pasteable. Do not keep
  `.agentworks/bin/tick` as the launcher.
- **`.remuda/bin/tick` binstub** from `remuda new` / lockfile, so crontab
  does not hard-code a bundler path per workspace.

Without this, remu cannot swap.

### Host MCP / auth into the box — gem

Host `Remuda.tool` is done for self-hosted MCP. The sandbox is not.

- Sandbox currently starts Pi `--offline`. Scheduled `Remuda.agent` cannot
  reach a model. Stage harness Pi `auth.json` per [02-runner](./02-runner.md)
  / [08-secrets](./08-secrets.md) and drop `--offline` for live ticks.
- Do **not** mount agent `.env` into the container (Agentworks `loadEnv`
  was the bug). Do **not** put SaaS tokens in the directory.
- `mcp.json` in the box stays secret-free. Plane calls stay **host**
  `Remuda.tool`, not Pi-inside-the-box MCP, unless a later ADR says otherwise.

Without model auth in the box, remu’s `poll-and-execute` agent steps cannot
run.

### Channels — gem, before Ops (step 5), not before remu

[06-channels](./06-channels.md) is designed; v1 did not ship `channels/` or
channel models. Adapters (telegram, planet) live in the gem; bindings in
`.remuda/channels.yml`.

- Remu, rflt, and the poll-and-execute project agents have **no** channel
  bindings. They can move without this.
- Ops has telegram + planet. It cannot move until `remuda channels
  start|stop` (or the supervisor 06 proposes) runs on adam-server.
- SDCRM has telegram adapter **code** and no `channels.yml`. Treat as no
  binding unless a later inspect finds a live daemon.

## Gem vs each agent directory

Build once in the gem:

- tick-from-cron CLI + crontab line shape
- sandbox Pi auth (staged `auth.json`, not `--offline`)
- channel adapters + supervisor (before Ops only)
- `Remuda.tool` / `Remuda.agent` / Runner / SQLite models (already shipped)

Rewrite in each workspace when it moves:

- `AGENTS.md` from identity in `CLAUDE.md`; stop using `CLAUDE.md` as identity
- `Gemfile` / lockfile naming remuda
- `.remuda/workflows/<name>.rb` from `.agentworks/config/workflows/*.rb`
  (`Remuda.tool` / `Remuda.agent`; no YAML)
- skills: `.claude/skills/` and `.opencode/skills/` → `.pi/`
- `mcp.json` secret-free URLs; Plane key stays in `.env` as header interpolation
- `remuda schedule` for each live cadence (cron + inputs from the inventory)
- crontab swap (Remuda in, Agentworks out)
- engine becomes Pi (today: claude / opencode / pi — harness is not a dimension)

Do not copy `lib/` harness into a workspace. Do not keep a dual-run
Agentworks workflow “just in case.”

Workflow YAML (`.yaml` next to `.rb`) is discarded. The Ruby script is the
workflow; port control flow, do not port the Agentworks engine.

## Per-workspace notes the next session will need

- **Ops** is `opencode` today and has three workflows plus channels. Last.
- **Assistant** has no project of its own; filters stay on OPS + assignee.
- **SDCRM** extra workflows `skydog-crm-inference` / `skydog-crm-trigger`
  have no schedule files — do not schedule them.
- **receipts-agent** holds `OPENCODE_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`
  in `.env`. Remuda must not carry those into the sandbox; host tools for
  Outlook/QBO stay host-side. Confirm the MCP URL shape when rewriting
  `process-receipts`.
- **sky-dog/agent** already `pi`; still needs Remuda layout and schedules
  (four gmail slices + sources).
- **HPSUB** is a crontab delete, not a rewrite.

## Inspect commands (stranger)

After a workspace moves:

```bash
ssh adam-server 'crontab -l | grep <path>'
# expect remuda tick; no .agentworks/bin/tick

ssh adam-server 'test -f <path>/AGENTS.md && ls <path>/.remuda/workflows'

ssh adam-server 'cd <path> && remuda tick'
# then:
ssh adam-server 'cd <path> && remuda console'
# WorkflowRun.order(:id).last → trigger schedule, status ok
```

## Open (do not block remu)

- Crontab wrapper is `remuda tick` (Adam, 2026-09-22). Not `bundle exec`.
- Whether `remuda schedule --install-cron` writes crontab or prints it.
  Print is enough for adam-server (operator/agent with host crontab access).
- Channel process model (one supervisor vs per-transport) — settle in 06
  before Ops, not before remu.
- Catch-up policy when adam-server was asleep (04) — drop, as 04 proposes.
- Observability / optimize loop, distribution & versioning — not this
  project.
