# 06 — Channels

Transports in the gem, bindings in the agent.

## Settled

- **Adapters live in the gem.** Mattermost is the first one shipped
  (`lib/remuda/channels/mattermost.rb`); it is the Dark Horse chat tool
  (Adam, 2026-08-21) and has first-class bot accounts. Telegram and Planet
  are proven in Agentworks and port when an agent needs them; Slack is
  demand-driven. The `Channel` protocol carries over:
  one class per transport, `owns_jid?`, `send_message`, poll/receive loop.
- **Bindings live in the agent**: `.remuda/channels.yml` says *which*
  Telegram bot, *which* Planet workspace this agent answers; tokens come from
  `.env` at the agent root.
- **The protocol** is `Remuda::Channels::Channel` plus a `Registry` that
  routes by jid. `Remuda.channels(dir)` builds the registry from
  `.remuda/channels.yml` (`transports: { mattermost: { url:, token_env: } }`).
  No bindings means an empty registry, not an error. Unknown transports and
  missing tokens fail at load.
- **Mattermost specifics.** Inbound over the websocket event stream, using a
  stdlib RFC 6455 client (`channels/websocket.rb`), so the gem takes no new
  dependency. Outbound over REST (`POST /api/v4/posts`). jid is
  `mattermost:<channel_id>`; thread_id is the root post id. A post counts as
  inbound when it is a DM or @mentions the bot. Being part of a thread is not
  enough: a reply must tag the bot too (Adam, 2026-09-23). The bot's own
  posts, system posts, and other bots' posts are dropped (`ignore_bots`: no
  bot-to-bot loops).
  `allow:` limits senders. Handlers run on one worker thread, in order, so a
  minutes-long `Remuda.agent` never stalls pongs. Reconnect with backoff,
  then backfill posts since the cursor. Dedup is by post id.
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
- **Durable cursor**: Mattermost keeps its cursor (last `create_at`) in
  memory and accepts `since:`. Persisting it is a `channel_cursors` row once
  05-state lands, so a restarted daemon backfills too.
- Ordering/dedup guarantees per conversation (Agentworks had offset tokens;
  formalize per-`jid` serialization?).
- Outbound-only use (a workflow posting a digest) — does that go through the
  channel adapter directly (`Remuda.channels.telegram.send_message`), and does
  it self-record as a step? (Consistency says yes.)
