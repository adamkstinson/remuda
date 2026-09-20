# Live Agentworks fleet inventory (adam-server)

Captured **2026-09-20T16:07:17-07:00** from user `adam` crontab on
`adam-server`. That crontab is the live source of ticks. Laptop copies of
these directories are dormant backups and are not inventoried here.

Every live Agentworks line is:

```
* * * * * cd <path> && .agentworks/bin/tick
```

The real cadence lives in `<path>/.agentworks/state/schedules/*.json`
(server timezone America/Los_Angeles). Engine is `AGENT_ENGINE` from the
workspace `.env` or `.agentworks/config/.env`; when both are unset, `box.rb`
defaults to `claude`.

This is the input to fleet & migration (`design/10-fleet-migration.md`, not
yet drafted). Cross-check against `~/Agents/Ops/HOMELAB-INFRA.md` (stale as
of 2026-08-19) is under [Drift](#drift-vs-homelab-inframd).

## Index (crontab-ticked)

- Ops — `~/Agents/Ops` — OPS
- Assistant — `~/Agents/Assistant` — work items in OPS
- SkyDog CRM Build — `~/Clients/sky-dog/skydog-crm-build` — SDCRM
- Client Tool Auth — `~/Clients/harbor-point/tool-auth` — HPAUT
- Receipts and Expense Processing — `~/Clients/harbor-point/receipts-expenses` — HPRCP
- receipts-agent — `~/Clients/harbor-point/receipts-expenses/receipts-agent` — no Plane project
- Subcontractor Payment Tracking — `~/Clients/harbor-point/payment-tracking` — HPPAY
- Echo Sources — `~/Clients/echonomy/echo-sources` — ECSRC
- Echo — `~/Clients/echonomy/echo` — ECAPP
- SkyDog CRM agent (Asset 2) — `~/Clients/sky-dog/agent` — no Plane project
- Remuda — `~/Projects/remuda/projects/remu` — REMU
- Remuda Fleet — `~/Projects/remuda/projects/rflt` — RFLT

## Crontab-ticked workspaces

### Ops

- Path: `~/Agents/Ops`
- Plane: OPS (`9b748190-7f21-4e40-8db3-978c2275d525`)
- Workflows: `triage`, `operate`, `execute`
- Channels: telegram + planet
  (`.agentworks/config/channels.yml`; `bin/channel-telegram`, `bin/channel-planet`)
- Engine: `opencode` (root `.env`)
- Schedule: crontab tick every minute
  - `triage` `0 * * * *`
  - `operate` `0 */4 * * *`
  - `execute` `35 */4 * * *`

### Assistant

- Path: `~/Agents/Assistant`
- Plane: none of its own — work items in OPS
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude` (`.agentworks/config/.env`; root `.env` unset)
- Schedule: crontab tick every minute; `poll-and-execute` `50 */4 * * *`

### SkyDog CRM Build

- Path: `~/Clients/sky-dog/skydog-crm-build`
- Plane: SDCRM (`8887c34c-9adb-49a5-abbe-93fdcb026cb3`)
- Workflows: `poll-and-execute`; also `skydog-crm-inference`, `skydog-crm-trigger`
  (no schedule files for the last two)
- Channels: telegram adapter code under `.agentworks/lib/channels/` plus
  `bin/channel-telegram`; **no** `channels.yml` binding
- Engine: `claude` (`.agentworks/config/.env`)
- Schedule: crontab tick every minute; workflow schedule **paused**
  (`cron_paused`: `15 */4 * * *`, no `cron` key)

### Client Tool Auth

- Path: `~/Clients/harbor-point/tool-auth`
- Plane: HPAUT (`8e05cdaa-f71e-47c6-b1dd-d5cdc085a027`)
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude`
- Schedule: crontab tick every minute; `5 */4 * * *`

### Receipts and Expense Processing

- Path: `~/Clients/harbor-point/receipts-expenses`
- Plane: HPRCP (`c4d6d4ac-3756-4f25-9e2d-4219c7506098`)
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude`
- Schedule: crontab tick every minute; `15 */4 * * *`

### receipts-agent (nested under HPRCP)

- Path: `~/Clients/harbor-point/receipts-expenses/receipts-agent`
- Plane: none (mailbox→QBO runtime, not a Plane project agent)
- Workflows: `process-receipts`
- Channels: none
- Engine: `opencode` (root `.env`; also has `OPENCODE_API_KEY` and
  `CLAUDE_CODE_OAUTH_TOKEN` set)
- Schedule: crontab tick every minute; `0 */6 * * *`
  (inputs `hours=6`, `apply=true`)

### Subcontractor Payment Tracking

- Path: `~/Clients/harbor-point/payment-tracking`
- Plane: HPPAY (`6377ffd0-e467-48fe-b5fe-7d112d12c128`)
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude`
- Schedule: crontab tick every minute; `35 */4 * * *`

### Echo Sources

- Path: `~/Clients/echonomy/echo-sources`
- Plane: ECSRC (`fa89acc2-b18b-4895-afc6-c45776265f06`)
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude`
- Schedule: crontab tick every minute; `5 */4 * * *`

### Echo

- Path: `~/Clients/echonomy/echo`
- Plane: ECAPP (`093f9d49-c5bc-4b1f-82f4-d9e0ce09866f`)
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude`
- Schedule: crontab tick every minute; `25 */4 * * *`

### SkyDog CRM agent (Asset 2)

- Path: `~/Clients/sky-dog/agent`
- Plane: none (CRM asset, not a Plane project agent)
- Workflows: `skydog-crm-gmail`, `skydog-crm-sources`
- Channels: none
- Engine: `pi`
- Schedule: crontab tick every minute
  - gmail hot `0 8 * * *`
  - gmail warm `30 8 * * *`
  - gmail cold `0 9 1 * *`
  - gmail other `0 10 1 1,4,7,10 *`
  - sources `30 9 * * *`

### Remuda

- Path: `~/Projects/remuda/projects/remu`
- Plane: REMU (`47bbd93b-ee51-4c05-b4cb-d9fcfecdba06`)
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude`
- Schedule: crontab tick every minute; `10 */6 * * *`

### Remuda Fleet

- Path: `~/Projects/remuda/projects/rflt`
- Plane: RFLT (`e19c186c-edd5-4981-b018-8f994e1a73d1`)
- Workflows: `poll-and-execute`
- Channels: none
- Engine: `claude`
- Schedule: crontab tick every minute; `25 */4 * * *`

## Leftover ticks

Listed, not omitted.

### HPSUB — crontab line, directory gone

- Path: `~/Clients/harbor-point/subcontract-automation`
- Plane: HPSUB (UUID not on disk; HOMELAB-INFRA.md)
- What is left: crontab still `cd … && .agentworks/bin/tick` every minute;
  path does not exist on adam-server. Crontab comment (2026-08-24) says a
  *duplicate* subcontract-automation entry was removed; this remaining line
  was not.
- Engine: n/a
- Schedule: tick would fail every minute

### ECDEP — archived, crontab removed 2026-08-24

- Path: `~/Clients/echonomy/echo-hosted-deployment`
- Plane: ECDEP (`9a25f69c-3474-4108-8ed1-a9c8212f65ec`)
- What is left: directory + `poll-and-execute` workflow still on disk;
  empty `state/schedules/`
- Engine: unset (would default `claude`)
- Schedule: **not** crontab-ticked

### ECCAP — archived, crontab removed 2026-08-24

- Path: `~/Clients/echonomy/capital-systems-specs`
- Plane: ECCAP (`d0c08dd7-5666-4709-93b4-c4deba7f29bb`)
- What is left: same shape as ECDEP
- Engine: unset (would default `claude`)
- Schedule: **not** crontab-ticked

### ECDOF — archived, not in crontab

- Path: `~/Clients/echonomy/digital-office`
- Plane: ECDOF (`7d334d22-764d-494e-9909-8d861bf5f6a9`)
- What is left: directory + workflows remain; last `tick.log` 2026-09-01T20:20;
  empty `state/schedules/`
- Engine: unset (would default `claude`)
- Schedule: **not** crontab-ticked. HOMELAB still listed it as live
  `poll-and-execute` hourly :20.

### award-subcontract-skill — schedule on disk, not crontab-ticked

- Path: `~/Clients/harbor-point/award-subcontract-skill`
- Plane: not a live fleet row
- What is left: `poll-and-execute` schedule `30 */4 * * *`,
  `last_run` 2026-08-31T12:30-07:00, `next_run` still 2026-08-31T16:30 —
  stalled because crontab does not tick it
- Engine: not captured
- Schedule: not crontab-ticked

Crontab header on adam-server (verbatim intent):

> agentworks: one tick per live workspace. Exactly one line each — a duplicate
> double-fires the scheduler… Removed 2026-08-24: echo-hosted-deployment and
> capital-systems-specs (projects archived 2026-08-20; project-lifecycle close
> step 5.6), plus a duplicate subcontract-automation entry.

## Drift vs HOMELAB-INFRA.md

The fleet table in `~/Agents/Ops/HOMELAB-INFRA.md` (last updated 2026-08-19,
with later notes) is a starting list and is stale.

- Ops — HOMELAB: engine `claude`; `triage` hourly + `operate` every 4h.
  Live: engine is `opencode`; also `execute` at `35 */4 * * *`.
- Assistant — HOMELAB: `poll-and-execute` hourly :50.
  Live: `50 */4 * * *` (every 4h, not hourly).
- HPSUB — HOMELAB: live at `~/Clients/harbor-point/subcontract-automation`.
  Live: crontab line remains; **directory gone**.
- ECDEP and ECCAP — HOMELAB: “schedule still live, clean up”.
  Live: crontab entries **already removed** 2026-08-24; dirs remain.
- ECDOF — HOMELAB: live hourly :20.
  Live: **not** in crontab; last tick 2026-09-01.
- SDCRM — HOMELAB: paused :15.
  Live: still paused (`cron_paused` `15 */4 * * *`); crontab still ticks
  the dir every minute.
- REMU / RFLT — match (`10 */6 * * *`, `25 */4 * * *`).
- Absent from HOMELAB, crontab-ticked live: HPAUT, HPRCP, HPPAY,
  receipts-agent, ECSRC, ECAPP, `~/Clients/sky-dog/agent`.

Other directories on adam-server have `.agentworks/bin/tick` but no crontab
line (archived engagement agents, nested Harbor Point helpers, CUBL, etc.).
They are not ticks. Only crontab lines and the leftover rows above are in
scope for cutover counting.

## How a stranger re-verifies

```bash
ssh adam-server 'crontab -l'
# then for each `cd <path>` line:
ls <path>/.agentworks/config/workflows
ls <path>/.agentworks/state/schedules
grep AGENT_ENGINE <path>/.env <path>/.agentworks/config/.env
```
