# 08 — Secrets & credential topology

Two credential planes — **model providers** and **tools** — crossing two
trust classes. The design goal is unchanged from agent-box: *no real service
credential ever inside the sandbox.* `.env` is never mounted into the
container (see [02-runner](./02-runner.md)). The runner may *read* it on the
host and inject a small env tuple.

## The grid

| | Workflow script / `remuda console` (host) | `Remuda.agent` / `remuda` (sandbox) |
|---|---|---|
| **Model provider** | n/a (scripts don't call LLMs directly — `Remuda.agent` does) | Pi needs provider auth |
| **Tools** | direct MCP calls with operator authority | MCP via secret-free config + edge-injected auth |

Two trust classes (IRB is operator Ruby, same as a workflow):

1. **Host** — workflow scripts (`remuda run` / tick) and `remuda console`
   (IRB). Operator authority, like any cron job or `rails console`. On a
   laptop, `.env` may hold tokens for *self-hosted* MCP (planet-mcp, etc.).
   Third-party SaaS tokens do not belong there — see *Client directories*
   below.
2. **Sandbox** — `Remuda.agent` (one-shot) and bare `remuda` (interactive Pi).
   Same container posture; a human at the TTY does not relax it. Model output
   steers execution here, so this is the boundary that matters. No real
   service credential inside.

## Tools plane

**The feature is an auth gateway.** The sandbox never holds a real service
credential. It calls URLs. Something outside the box, that knows *which agent
this is*, swaps in the real token. OAuth is a human in a dashboard. An
unconnected tool 401s — there is no login flow inside Pi.

OneCLI is one implementation that already did this (vault + `HTTPS_PROXY` +
per-agent token + TLS intercept). The OSS product is not great; that is a
reason **not** to couple Remuda to it, not a reason to put tokens back in
`.env`. Two client vaults already live. Use it while it works; replace the
process behind the seam without touching the gem.

**Remuda's contract — the only thing the gem may know:**

The runner reads the agent's `.env` on the **host** and injects a tuple into
the container. It does not mount the file.

- proxy URL (`HTTPS_PROXY`)
- per-agent gateway token (`Proxy-Authorization`, wired in-process, never argv)
- CA the image trusts (path or a CA file the runner mounts)

Name-only identity is impersonation: every container on the box shares the
path to the proxy, so the token must be scoped to one agent.

`mcp.json` is `{name, url}` only. Nothing in `Remuda.tool`, `Remuda.agent`, or
the CLI talks to a vendor API. Nothing else in Remuda may learn the gateway's
product name.

**Image work (real, not a footnote):** Node `fetch` / undici does not honor
`HTTPS_PROXY` by default. The image must wire Pi's HTTP client through the
proxy in-process and trust the gateway CA. Egress-trust is an image
responsibility — the directory cannot edit its own sandbox. Ship this wiring
as if *all* sandbox HTTPS will go through the gateway, even if v0 still
reaches the model API directly.

**Self-hosted MCP** is the same shape without a proxy: planet-mcp holds the
Plane keys, example-mcp holds the CRM token — secrets live with the server;
the caller reaches an endpoint. The gateway generalizes that to SaaS we don't
host (Gmail, QuickBooks). Both are credential-at-the-edge.

**What the gateway process must nail** (not Remuda — later, when we run this
for clients):

- agent identity (per-agent token)
- host match → credential inject
- OAuth storage + refresh
- human connect flow

OSS OneCLI's org/user sharp edges (org-split, no invite flow) are that
process's runbook, not Remuda design.

## Model-provider plane

Pi-only makes this one credential class instead of one per coding agent.

**Laptop / fleet v0:** provider auth is **per agent**. The sandbox sets
`PI_CODING_AGENT_DIR=/agent/.pi/agent` (host `<agent>/.pi/agent/`). That folder
is this agent’s Pi user dir: `auth.json`, `models-store.json` (catalog/pricing),
`sessions/`, `settings.json`. Same files Pi already uses. Not a copy of
`~/.pi/agent`. Not MCP (that is `.env` + `mcp.json`) and not channel tokens
(`.env` + `.remuda/channels.yml`). Alternatively the runner reads
`PI_PROVIDER` / `PI_MODEL` and that provider's API key from the agent `.env`
on the host and writes `auth.json` into that folder. It never mounts `.env`.
It never reads the operator's `~/.pi/agent/auth.json`. A leaked provider token
spends money; a leaked service token reads your email — triage v0 accordingly.

**Do not freeze that as the client path.** The client story is the same
gateway: model traffic through the proxy, placeholder in the box, real key at
the edge. Staged `auth.json` is a laptop shortcut. The image tuple and proxy
wiring are built as if the gateway will take model egress too.

## `.env` in the agent directory

Slots, not a vault. The file stays on the host; the runner reads it.

- gateway identity: proxy URL, per-agent token, CA path
- endpoints + tokens for *self-hosted* MCP the workflow scripts call
  (planet-mcp, etc.)
- never: third-party SaaS credentials (Gmail, QuickBooks, …) — those live in
  the gateway or with the MCP server that owns them

`remuda new` writes `.env.example` documenting the slots; `.env` is gitignored
and 0600.

## Client directories (later)

A client agent is a directory we can hand them. That is incompatible with
third-party tokens in `.env`, including for host-side `Remuda.tool`.

| | Laptop (us) | Client agent |
|---|---|---|
| **Tools (SaaS)** | gateway when present; never in the directory | gateway; tokens in `.env` are a bug |
| **Tools (our MCP)** | `.env` may hold the per-agent MCP key | same, or also behind the gateway |
| **Model** | staged harness `auth.json` | gateway ("token to the edge"); do not assume `auth.json` |

Host `Remuda.tool` on a client directory goes to self-hosted MCP or through
the gateway — not to a SaaS token sitting in the folder.

Gateway deployment (the operator instance vs per-client, rotation, `doctor`
checks) is fleet/runbook territory. Remuda only aims the box at the tuple.

## Settled

- Two-class trust grid above; the sandbox boundary is the one that matters.
  `remuda console` (IRB) is host-class; bare `remuda` (Pi) is sandbox-class.
- `.env` and `db/` never enter the container. The runner may read `.env` on
  the host and inject the gateway tuple.
- The feature is credential-at-the-edge. Remuda speaks only the env tuple.
  The gateway product (today: OneCLI) is replaceable; the gem does not name it.
- Per-agent gateway token (name-only is impersonation). CA trust and in-process
  proxy wiring in the image. Ship that wiring as if all sandbox HTTPS will go
  through the gateway.
- Secret-free `mcp.json`. Self-hosted MCP is the same shape for services we own.
- Third-party SaaS tokens never live in the agent directory.
- OAuth is human-performed, vault-stored, auto-refreshed. Agents cannot
  self-authorize.
- Laptop / v0 model auth: per-agent `.pi/agent/auth.json` (Pi user dir mapped
  into the sandbox). Not the client path — clients get model keys at the edge
  too.

## Open (later)

- **Gateway as only egress** vs credentialed hosts only vs v0 direct model API
  + staged `auth.json`. Image wiring assumes the first. Ties to [02-runner](./02-runner.md)
  network policy.
- **Pi `auth.json` internals** for the laptop path — on-disk shape, read-only
  per invocation. Blocks the image build for v0, not the gateway seam.
- **Host-side MCP auth** — per-agent API keys (current Planet practice) vs one
  operator key. Propose: per-agent, so the audit trail is readable.
- **Client gateway operations** — who runs it (the operator vs per-client),
  rotation/revocation, what `remuda doctor` checks (tuple valid, CA current,
  gateway reachable). Fleet/runbook, not gem API.
- Exact header vs proxy-URL userinfo for the per-agent token (confirm against
  whatever process sits behind the tuple).
