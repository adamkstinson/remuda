# 02 — The runner

One invocation of the agent's mind, sandboxed. And the same sandbox opened
interactively.

The sandbox is **Pi only**. Workflow Ruby, ActiveRecord, and SQLite stay on
the host. Two doors share one container definition:

| Door | Who | What |
|---|---|---|
| `Remuda.agent(prompt)` | a workflow | one prompt, Pi exits, Ruby gets a result |
| `remuda` (no subcommand, inside an agent dir) | you | Pi's TUI until you quit |

`remuda console` is **not** this. It is IRB against the agent's database — see
[07-cli](./07-cli.md).

## Settled

- **Pi is the only runtime.** No claude/opencode/codex adapter matrix. Pi
  accepts the other providers' logins, so *model* remains per-agent config
  while *harness* stops being a dimension. One entrypoint, one wire format,
  one container image.
- **Remuda ships a curated Pi profile** as part of the harness (its own config,
  skills it relies on, structured-output settings). The agent directory layers
  its own `.pi/` on top. Framework config vs app config.
- **Interactive and unattended share one sandbox posture.** Same image, same
  uid, same credential set, same HostConfig builder. `Remuda.agent` runs Pi
  with a prompt and exits; bare `remuda` allocates a TTY. Working on an agent
  never means escaping the sandbox its scheduled runs live in.
- **Write bits may differ.** `.remuda/workflows/` is **read-only** for
  `Remuda.agent` (a scheduled model must not rewrite the cron job that runs
  with operator authority) and **read-write** for interactive `remuda` (that
  is how you develop the agent). That is the one intentional break from
  identical mounts.
- **Pi version is part of the harness version.** Gem version ↔ image tag ↔ Pi
  version pin together, so an agent's behavior is reproducible from its
  lockfile. The image is `remuda-pi:<gem-version>`; the agent directory does
  not pin Pi itself.
- **Credential hygiene by construction**: real service credentials stay outside
  the container. `.env` is **never mounted**. `.remuda/db/` is **never
  mounted** — only the host gem writes SQLite. Do **not** mount `.remuda/` as
  a whole (db lives there). Mount `.remuda/workflows/` as a slice. The
  directory's identity, `.pi/`, skills, and `files/` go in; host MCP tokens
  do not. Do not source the agent's `.env` inside the image (agent-box did;
  we don't).
- **No `--host` flag.** Unsandboxed Pi is `pi` in the directory yourself.
- **Do not depend on `agentbox`.** Fold the proven bits (Engine API wait/reaper,
  prompt-as-file, cap-drop, read-only rootfs). Leave the multi-runtime registry,
  JS wire harness, and `loadEnv(/brain/.env)`.

## What runs where

```
host:  remuda run … triage
         load .remuda/workflows/triage.rb  # operator Ruby, real tool creds
         Remuda.tool("plane.list_…", …)    # MCP on the host
         Remuda.agent(prompt) ─────────┐
                                       ▼
container:  pi --mode json --print --approve
            cwd /agent; identity + files only
            stdout: Pi JSONL  →  Ruby parses  →  step row
         Remuda.tool("plane.create_comment", …)
```

## Image and wire

One image, co-versioned with the gem. Payload is Pi plus git/ripgrep/ca-certs.
`ENTRYPOINT` is `pi` (a tiny wrapper may stage `auth.json` onto tmpfs, then
`exec pi`). No private JSON `run_done` protocol.

**Batch (`Remuda.agent`):**

```
pi --mode json --print --approve --no-session [--model …] [--session-id …]
```

`--approve` so `/agent/.pi` and `AGENTS.md` load. Ruby parses Pi's public
`--mode json` stream (session id, assistant text, tool events, usage) into a
result object. SDK/RPC are out: SDK is Node; RPC is a long-lived peer; one-shot
`agent` is print mode.

**Interactive (`remuda`):** same image, argv is `pi` (TUI), TTY attached.
Pi writes sessions under `/agent/.pi/agent/sessions` (the agent’s user folder).

The prompt for batch is a **0600 file in a 0700 tmpdir**, mounted read-only —
never argv (`MAX_ARG_STRLEN` is 128KiB; Agentworks Ops died on this).

## Engine

**Docker.** Drive the Docker Engine API with the `docker-api` gem — no CLI
shell-out for unattended runs. Podman is out: not enough long-term support to
bet the harness on. Do not `system("docker run")` plus `Timeout.timeout` —
that combination failed to reap hung containers in Agentworks.

Shared HostConfig builder; two wait paths:

| | `Remuda.agent` | `remuda` (interactive) |
|---|---|---|
| spawn | Docker Engine API | same HostConfig; TTY attach (or `docker run -it`) |
| stdin | closed (prompt is a file) | TTY |
| wait | HTTP `/wait` with wall-clock reaper | until the TTY exits |
| output | JSONL → result | none (human) |

Hardening: read-only rootfs, `cap-drop ALL`, `no-new-privileges`, pids/memory/cpu
limits, tmpfs for `/tmp` only — **not** for `PI_CODING_AGENT_DIR`. That dir is
the agent’s `.pi/agent/` (mounted at `/agent/.pi/agent`). uid `1000:1000` so
`files/` and `.pi/agent/` come back as the operator.

Interactive spawn may shell out to `docker run --rm -it` if API attach is
miserable; hung TTY is Ctrl-C. Do not split the mount/limit/env builder.

## Mounts

The agent directory is not one writable “brain.”

| Host | Container | `Remuda.agent` | `remuda` (interactive) |
|---|---|---|---|
| `AGENTS.md`, `.pi/`, skills, `files/` | `/agent` rw | rw | rw |
| `.remuda/workflows/` | `/agent/.remuda/workflows` | **ro** | rw |
| prompt file | `/run/remuda/prompt.txt` | ro | — |
| remuda Pi profile | in the image (or a ro mount) | ro | ro |
| `mcp.json` | `/agent/mcp.json` | ro, secret-free | ro |
| `.remuda/db/` | **not mounted** | | |
| `.remuda/` as a whole | **not mounted** | | |
| `.env` | **not mounted** | | |
| `.remuda/bin/`, `Gemfile` | not mounted | | |

Pi memory stays files. A jailbroken Pi can trash `files/` and `.pi/agent/`
(including `auth.json`); it cannot rewrite run history or steal host MCP
tokens. Do not copy `~/.pi/agent` into an agent directory.

## Auth and network (v0)

See [08-secrets](./08-secrets.md) for the full topology. Short version:

The runner **reads** `.env` on the host. It never mounts the file. From it,
inject the gateway tuple when present (`HTTPS_PROXY`, per-agent token, CA) —
not the rest of the file. The image wires Pi's HTTP client through that proxy
(Node will not honor `HTTPS_PROXY` by itself) and trusts the CA. Build that
as if all sandbox HTTPS will go through the gateway.

**Per-agent Pi user folder.** `PI_CODING_AGENT_DIR=/agent/.pi/agent` — the
host path `<agent>/.pi/agent/`. That is this agent’s `auth.json`, `sessions/`,
`models-store.json` (catalog/pricing), and `settings.json`. Same documents Pi
already uses; not a Remuda reimplementation; not the operator’s
`~/.pi/agent`. `.env` is still never mounted; if the agent has API keys only
in `.env`, the runner may synthesize a tmp `auth.json` into that folder or a
staging dir (08). MCP tokens stay in `.env` + `mcp.json`; channel tokens stay
in `.env` + `.remuda/channels.yml`.

Launcher also sets invocation env (`AGENT_PROMPT_FILE`, `AGENT_MODEL`,
`AGENT_SESSION_ID`, `PI_CODING_AGENT_DIR`).

Network on in v0 (the model API has to be reached until the gateway takes it).
`--network host` is a laptop shortcut for localhost MCP and a hole; default
bridge + explicit MCP routes is the next tightening.

Batch `Remuda.agent` still passes `--no-session` unless a workflow asks for a
session id (follow-up in the same run). The **queryable** record of that turn
is the `workflow_steps` row, parsed from Pi’s `--mode json` stream (text, tool
events, usage). Interactive `remuda` does not pass `--no-session`; Pi persists
under `.pi/agent/sessions`. SQLite is not Pi’s session disk. A later index of
JSONL into tables is optional (05).

## Interface sketch

```ruby
result = Remuda.agent(prompt, context: { ... })
# → output, session_id, usage, ok, exit_code
```

```bash
remuda          # from inside an agent dir: interactive Pi, same sandbox
remuda console  # not the sandbox — IRB, see 07
```

## Open

- Exact merge between Remuda's shipped Pi profile and the directory's `.pi/`
  (what merges, what overrides).
- Network policy past v0: host network vs default bridge vs MCP/provider
  allowlist vs gateway as the only egress (08: image wiring assumes the last).
- Whether to index `.pi/agent/sessions` JSONL into SQLite for ad-hoc SQL, or
  query files + `workflow_steps` only.
- `Remuda.agent` result object: exact fields we normalize from Pi JSONL.
- Whether `mcp.json` belongs in the box at all in v0 (secret-free URLs to
  self-hosted MCP are consistent with credential-at-the-edge; third-party MCP
  waits on the gateway tuple).
