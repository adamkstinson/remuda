# 06 — Channels

Transports in the gem, bindings in the agent.

## Settled

- **Adapters live in the gem** (Telegram and Planet exist and are proven in
  Agentworks; Slack is demand-driven). The `Channel` protocol carries over:
  one class per transport, `owns_jid?`, `send_message`, poll/receive loop.
- **Bindings live in the agent**: `.remuda/channels.yml` says *which*
  Telegram bot, *which* Planet workspace this agent answers; tokens come from
  `.env` at the agent root.
- **Channel state is rows** (`channel_cursors`, `channel_sessions`,
  `channel_messages` — see [05-state](./05-state.md)), not JSON files.
- **Inbound resolves to an invocation** through the same runner seam as
  workflows (a message-triggered `Remuda.agent` with conversation context), so
  channel-driven work is sandboxed and recorded like everything else.

## Open

- **Process model**: Telegram long-poll needs a persistent process
  (`bin/channel-telegram` daemon carried from Agentworks). One daemon per
  channel, or one `bin/channels` supervising all bound transports? Propose:
  one supervising process.
- Supervision: systemd user unit per agent? `remuda channels start/stop`
  wrapping it?
- **Conversation → run mapping**: is each inbound message a `workflow_run`
  (kind: `message`), or do sessions get their own table with runs hanging off
  them?
- Ordering/dedup guarantees per conversation (Agentworks had offset tokens;
  formalize per-`jid` serialization?).
- Outbound-only use (a workflow posting a digest) — does that go through the
  channel adapter directly (`Remuda.channels.telegram.send_message`), and does
  it self-record as a step? (Consistency says yes.)
