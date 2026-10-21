# Changelog

## 0.1.15

- Images: pi 1.3.0 and pi-mcp-adapter 5.4.0, with a built-in `darkhorse`
  provider that lists ai.darkhorse.so's live model catalog; `DARKHORSE_API_KEY`
  in `.env` maps to it (#62). Rebuild `remuda-pi` and `remuda-coding`.
- Provider keys in an agent's `.env` reach Pi again: before each `remuda run`
  and bare `remuda`, the runner writes them into `.pi/agent/auth.json`,
  keeping other logins. This had not been wired since `PI_CODING_AGENT_DIR`
  moved to the agent's own `.pi/agent` (#63). `REMUDA_PI_AUTH` and a flat
  `.pi/auth.json`, which also stopped working then, are gone.
- The Pi profile always passes `--mcp-config` (an empty one when the agent has
  no servers), so pi-mcp-adapter no longer adds `"-builtin:mcp"` to the
  agent's tracked `.pi/agent/settings.json` (#64). Rebuild the images.
- A failed `Remuda.agent` step records the exit code, pi's error, the tail of
  its stderr and the last JSON event, with `.env` and `auth.json` values
  redacted (#65).
