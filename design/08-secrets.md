# 08 — Secrets & credential topology

Two credential planes — **model providers** and **tools** — crossing three
execution contexts with different trust. The design goal is unchanged from
agent-box: *no real service credential ever inside the sandbox.*

## The grid

| | Workflow script (host) | Reasoning step / console (sandbox) |
|---|---|---|
| **Model provider** | n/a (scripts don't call LLMs directly — `reason` does) | Pi needs provider auth |
| **Tools** | direct MCP calls with operator authority | MCP via secret-free config + edge-injected auth |

Three contexts, in decreasing trust:

1. **Workflow script** — plain Ruby on the host, fired by tick or `remuda run`.
   Runs with the operator's authority, like any cron job. It may hold real
   tool credentials (an MCP endpoint token in `.env`). This is accepted, not a
   leak: the script is operator-authored code, not model output.
2. **Reasoning step** (`Remuda.reason`) — Pi in the container. Model output
   steers execution here, so this is the boundary that matters. No real
   service credential inside.
3. **Console** (`remuda console`) — same container, same rules as (2). A human
   is present but the sandbox posture doesn't relax; that's the point of
   parity.

## Tools plane

**OneCLI is the interface, for now.** Not loved, but deployed (two client
vaults live) and its mechanism was fully designed and confirmed in agent-box:

- **Vault + forward proxy.** The sandbox routes HTTPS through the gateway
  (`HTTPS_PROXY`), authenticating as *this agent* with a per-agent token
  (`Proxy-Authorization`, wired in-process, never on argv). OneCLI matches the
  destination host to a connected service and swaps a placeholder for the real
  credential at the edge. The agent only ever "calls the URL."
- **CA trust in the image.** OneCLI terminates TLS to inject, so the image
  trusts the CA the agent's `.env` names. Egress-trust is an image
  responsibility — the directory cannot edit its own sandbox.
- **OAuth is a human's job**, once, in the vault dashboard. The agent cannot
  self-authorize. An unconnected tool 401s and a human connects it.
- **`mcp.json` stays secret-free** — `{name, url}` only. Provisioning a tool =
  one line in `mcp.json` + one connection in the vault.

**Self-hosted MCP servers are the other half of the tools story**, and already
embody the rule: planet-mcp holds the Plane keys, example-mcp holds the CRM
token — *secrets live with the server on the host; the caller reaches an
endpoint.* OneCLI generalizes the same shape to third-party services we don't
host (Gmail, QuickBooks). Both patterns are "credential at the edge"; neither
puts a secret in the sandbox.

**The seam, so OneCLI stays replaceable:** Remuda's contract is only the env
tuple the sandbox receives — `HTTPS_PROXY`, `AGENT_ID`, gateway token, CA
path — sourced from the agent's `.env`. OneCLI is one implementation of the
thing behind that tuple. Nothing else in Remuda may learn OneCLI's name.

## Model-provider plane

Pi-only makes this one credential class instead of one per coding agent. Pi
holds provider logins (Anthropic, OpenAI, …) as its own auth state on the
host.

**Proposal:** provider auth is **harness-level, not agent-level**. The runner
injects Pi's auth into the container per invocation (mounted read-only or
passed as env at spawn — decide with the image). Rationale: which *model* an
agent uses is agent config; which *provider account* pays for it is an
operator/machine concern, same as which podman binary runs the container.

The strictest future — provider keys never in the sandbox either, fronted
through the gateway like tools ("Anthropic token to the edge," agent-box's
open item) — stays on the roadmap, not v1. A leaked provider token spends
money; a leaked service token reads your email. Triage accordingly.

## `.env` in the agent directory

Slots, not a vault:

- gateway identity: proxy URL, per-agent token, CA path
- endpoints + tokens for *host-side* MCP calls the workflow scripts make
- never: third-party service credentials (those live in the vault or with the
  MCP server that owns them)

`remuda new` writes `.env.example` documenting the slots; `.env` is gitignored
and 0600.

## Settled

- Three-context trust grid above; the sandbox boundary is the one that matters.
- Secret-free `mcp.json`; credential-at-the-edge for tools (OneCLI vault for
  third-party services, self-hosted MCP servers for our own).
- Per-agent gateway identity in the agent's `.env`; CA trust and in-process
  proxy wiring in the image.
- OAuth is human-performed, vault-stored, auto-refreshed. Agents cannot
  self-authorize.
- OneCLI behind a named seam (the env tuple); replaceable without touching
  anything else.

## Open

- **Pi auth injection mechanics** — mount vs env; what Pi's auth state
  actually looks like on disk and whether it can be scoped read-only per
  invocation. (Blocks the image build.)
- **Host-side MCP auth** — workflow scripts calling planet-mcp present whose
  key? Per-agent API keys (current Planet practice) vs one operator key.
  Propose: per-agent, it's what makes the audit trail readable.
- **Does the sandbox route *all* egress through the gateway** (deny direct
  network, allowlist via proxy) or only credentialed hosts? Ties to
  02-runner's network-policy open item.
- **Vault deployment story for us** (the operator's own OneCLI instance vs
  per-client only, as today). Fleet doc territory.
- **Rotation & revocation** — per-agent gateway token rotation procedure;
  what `remuda doctor` checks (token valid, CA current, vault reachable).
- OneCLI's org/user sharp edges (org-split bug, no invite flow) are deployment
  runbook material, not Remuda design — but `doctor` could assert the
  known-good shape.
