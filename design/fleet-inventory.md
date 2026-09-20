# Live Agentworks fleet inventory (adam-server)

Captured **2026-09-20T16:07:17-07:00** from user `adam` crontab on
`adam-server`. That crontab is the live source of ticks. Laptop copies of
these directories are dormant backups and are not inventoried here.

Every live Agentworks line is `* * * * * cd <path> && .agentworks/bin/tick`.
The real cadence lives in `<path>/.agentworks/state/schedules/*.json`
(server timezone America/Los_Angeles). Engine is `AGENT_ENGINE` from the
workspace `.env` or `.agentworks/config/.env`; when both are unset, `box.rb`
defaults to `claude`.

This is the input to fleet & migration (`design/10-fleet-migration.md`, not
yet drafted). Cross-check against `~/Agents/Ops/HOMELAB-INFRA.md` (stale as
of 2026-08-19) is in [Drift](#drift-vs-homelab-inframd).

## Crontab-ticked workspaces

| Workspace | Path | Plane project | Workflows | Channels | Engine | Schedule |
|---|---|---|---|---|---|---|
| Ops | `~/Agents/Ops` | OPS (`9b748190-7f21-4e40-8db3-978c2275d525`) | `triage`, `operate`, `execute` | telegram + planet (`.agentworks/config/channels.yml`; `bin/channel-telegram`, `bin/channel-planet`) | `opencode` (root `.env`) | crontab tick every minute; `triage` `0 * * * *`; `operate` `0 */4 * * *`; `execute` `35 */4 * * *` |
| Assistant | `~/Agents/Assistant` | none of its own — work items in OPS | `poll-and-execute` | none | `claude` (`.agentworks/config/.env`; root `.env` unset) | crontab tick every minute; `poll-and-execute` `50 */4 * * *` |
| SkyDog CRM Build | `~/Clients/sky-dog/skydog-crm-build` | SDCRM (`8887c34c-9adb-49a5-abbe-93fdcb026cb3`) | `poll-and-execute`; also `skydog-crm-inference`, `skydog-crm-trigger` (no schedule files) | telegram adapter code under `.agentworks/lib/channels/` + `bin/channel-telegram`; **no** `channels.yml` binding | `claude` (`.agentworks/config/.env`) | crontab tick every minute; schedule **paused** (`cron_paused`: `15 */4 * * *`, no `cron` key) |
| Client Tool Auth | `~/Clients/harbor-point/tool-auth` | HPAUT (`8e05cdaa-f71e-47c6-b1dd-d5cdc085a027`) | `poll-and-execute` | none | `claude` | crontab tick every minute; `5 */4 * * *` |
| Receipts and Expense Processing | `~/Clients/harbor-point/receipts-expenses` | HPRCP (`c4d6d4ac-3756-4f25-9e2d-4219c7506098`) | `poll-and-execute` | none | `claude` | crontab tick every minute; `15 */4 * * *` |
| receipts-agent (nested under HPRCP) | `~/Clients/harbor-point/receipts-expenses/receipts-agent` | none (mailbox→QBO runtime, not a Plane project agent) | `process-receipts` | none | `opencode` (root `.env`; also has `OPENCODE_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` set) | crontab tick every minute; `0 */6 * * *` (inputs `hours=6`, `apply=true`) |
| Subcontractor Payment Tracking | `~/Clients/harbor-point/payment-tracking` | HPPAY (`6377ffd0-e467-48fe-b5fe-7d112d12c128`) | `poll-and-execute` | none | `claude` | crontab tick every minute; `35 */4 * * *` |
| Echo Sources | `~/Clients/echonomy/echo-sources` | ECSRC (`fa89acc2-b18b-4895-afc6-c45776265f06`) | `poll-and-execute` | none | `claude` | crontab tick every minute; `5 */4 * * *` |
| Echo | `~/Clients/echonomy/echo` | ECAPP (`093f9d49-c5bc-4b1f-82f4-d9e0ce09866f`) | `poll-and-execute` | none | `claude` | crontab tick every minute; `25 */4 * * *` |
| SkyDog CRM agent (Asset 2) | `~/Clients/sky-dog/agent` | none (CRM asset, not a Plane project agent) | `skydog-crm-gmail`, `skydog-crm-sources` | none | `pi` | crontab tick every minute; gmail hot `0 8 * * *`, warm `30 8 * * *`, cold `0 9 1 * *`, other `0 10 1 1,4,7,10 *`; sources `30 9 * * *` |
| Remuda | `~/Projects/remuda/projects/remu` | REMU (`47bbd93b-ee51-4c05-b4cb-d9fcfecdba06`) | `poll-and-execute` | none | `claude` | crontab tick every minute; `10 */6 * * *` |
| Remuda Fleet | `~/Projects/remuda/projects/rflt` | RFLT (`e19c186c-edd5-4981-b018-8f994e1a73d1`) | `poll-and-execute` | none | `claude` | crontab tick every minute; `25 */4 * * *` |

## Leftover ticks

Listed, not omitted.

| Kind | Path | Plane project | What is left | Engine | Schedule |
|---|---|---|---|---|---|
| Crontab line, directory gone | `~/Clients/harbor-point/subcontract-automation` | HPSUB (UUID not on disk; HOMELAB-INFRA.md) | crontab still `cd … && .agentworks/bin/tick` every minute; path does not exist on adam-server. Crontab comment (2026-08-24) says a *duplicate* subcontract-automation entry was removed; this remaining line was not. | n/a | tick would fail every minute |
| Archived project, crontab removed 2026-08-24 | `~/Clients/echonomy/echo-hosted-deployment` | ECDEP (`9a25f69c-3474-4108-8ed1-a9c8212f65ec`) | directory + `poll-and-execute` workflow still on disk; empty `state/schedules/` | unset (would default `claude`) | **not** crontab-ticked |
| Archived project, crontab removed 2026-08-24 | `~/Clients/echonomy/capital-systems-specs` | ECCAP (`d0c08dd7-5666-4709-93b4-c4deba7f29bb`) | same shape as ECDEP | unset (would default `claude`) | **not** crontab-ticked |
| Archived project, not in crontab | `~/Clients/echonomy/digital-office` | ECDOF (`7d334d22-764d-494e-9909-8d861bf5f6a9`) | directory + workflows remain; last `tick.log` 2026-09-01T20:20; empty `state/schedules/` | unset (would default `claude`) | **not** crontab-ticked; HOMELAB still listed it as live `poll-and-execute` hourly :20 |
| Schedule on disk, never/no longer crontab-ticked | `~/Clients/harbor-point/award-subcontract-skill` | (not a live fleet row) | `poll-and-execute` schedule `30 */4 * * *`, `last_run` 2026-08-31T12:30-07:00, `next_run` still 2026-08-31T16:30 — stalled because crontab does not tick it | not captured | not crontab-ticked |

Crontab header on adam-server (verbatim intent):

> agentworks: one tick per live workspace. Exactly one line each — a duplicate
> double-fires the scheduler… Removed 2026-08-24: echo-hosted-deployment and
> capital-systems-specs (projects archived 2026-08-20; project-lifecycle close
> step 5.6), plus a duplicate subcontract-automation entry.

## Drift vs HOMELAB-INFRA.md

The fleet table in `~/Agents/Ops/HOMELAB-INFRA.md` (last updated 2026-08-19,
with later notes) is a starting list and is stale:

| HOMELAB row | Live on 2026-09-20 |
|---|---|
| Ops engine `claude`; workflows `triage` hourly + `operate` every 4h | engine is `opencode`; also `execute` at `35 */4 * * *` |
| Assistant `poll-and-execute` hourly :50 | cadence is `50 */4 * * *` (every 4h, not hourly) |
| Subcontract Automation HPSUB live at `~/Clients/harbor-point/subcontract-automation` | crontab line remains; **directory gone** |
| Echo Hosted Deployment ECDEP and Capital Systems Specs ECCAP “schedule still live, clean up” | crontab entries **already removed** 2026-08-24; dirs remain |
| Echonomy Digital Office ECDOF live hourly :20 | **not** in crontab; last tick 2026-09-01 |
| SkyDog CRM Build paused :15 | still paused (`cron_paused` `15 */4 * * *`); crontab still ticks the dir every minute |
| Remuda / Remuda Fleet | match (REMU `10 */6 * * *`, RFLT `25 */4 * * *`) |
| *(absent)* HPAUT, HPRCP, HPPAY, receipts-agent, ECSRC, ECAPP, `~/Clients/sky-dog/agent` | all crontab-ticked live |

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
