# 02 — The runner

One invocation of the agent's mind, sandboxed. And the same sandbox opened
interactively.

## Settled

- **Pi is the only runtime.** No claude/opencode/codex adapter matrix. Pi
  accepts the other providers' logins, so *model* remains per-agent config
  while *harness* stops being a dimension. One entrypoint, one wire format,
  one container image.
- **Remuda ships a curated Pi profile** as part of the harness (its own config,
  skills it relies on, structured-output settings). The agent directory layers
  its own `.pi/` on top. Framework config vs app config.
- **Interactive and unattended share one sandbox.** The container definition is
  built once; `reason` runs Pi with a prompt and exits, `remuda console`
  attaches a TTY. Same image, same mounts, same credential hygiene. Working on
  an agent never means escaping the sandbox its scheduled runs live in.
- **Pi version is part of the harness version.** Gem version ↔ image tag ↔ Pi
  version pin together, so an agent's behavior is reproducible from its
  lockfile.
- **Credential hygiene by construction**: real service credentials stay outside
  the container; the mounted brain carries slots/identity, not live secrets
  for services the sandbox shouldn't reach. (Carried from agent-box's design;
  the enforcement point is now the image, which the agent directory cannot
  edit.)

## Interface sketch

```ruby
result = Remuda.reason(prompt, context: {...})   # one sandboxed Pi invocation
# → structured result: output, session id, cost/usage, step trace if available
```

```bash
remuda console        # from inside an agent dir: interactive Pi, same sandbox
remuda console --host # escape hatch: Pi on the host, no container (dev only?)
```

## Open

- **Container backend**: podman (agent-box's choice) — confirm, and decide
  rootless config as part of the image story.
- **Pi invocation mode for batch**: plain `pi -p`-style print mode vs Pi's
  SDK/RPC mode. RPC likely gives structured step output for run records
  (see 03) — investigate what Pi exposes.
- **What mounts read-only vs read-write** (brain writable, but `bin/`? `db/`
  needs write from inside? or does only the engine outside write the DB?).
- **Network policy** inside the sandbox: allow MCP endpoints only? per-agent
  allowlist?
- **Console session recording**: do interactive sessions write to the runs
  table too (as `kind: console`), or stay unrecorded?
- Does `--host` mode exist at all, or is unsandboxed Pi just "run `pi`
  yourself"?
