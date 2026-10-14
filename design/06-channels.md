# 06 — Channels

Transports in the gem, bindings in the agent.

## Settled

- **Adapters live in the gem.** Mattermost is the first one shipped
  (`lib/remuda/channels/mattermost.rb`); it has first-class bot accounts.
  Telegram and Planet are proven in Agentworks and port when an agent needs
  them; Slack is demand-driven. The `Channel` protocol carries over:
  one class per transport, `owns_jid?`, `send_message` (text plus optional
  local file paths), poll/receive loop. Inbound `IncomingMessage.files` is a
  list of `Attachment` (id, name, mime_type, size, path).
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
  dependency. Outbound over REST (`POST /api/v4/posts`, files via
  `POST /api/v4/files` then `file_ids`). jid is
  `mattermost:<channel_id>`; thread_id is the root post id. A post counts as
  inbound when it is a DM or @mentions the bot. File-only posts count too;
  the adapter downloads them so `IncomingMessage.files` has a local path.
  Being part of a thread is not
  enough: a reply must tag the bot too. The bot's own
  posts, system posts, and other bots' posts are dropped (`ignore_bots`: no
  bot-to-bot loops).
  `allow:` limits senders. Handlers run on one worker thread, in order, so a
  minutes-long `Remuda.agent` never stalls pongs. While a handler runs, the
  bot pulses typing on the channel and the thread so the person sees it
  working (`POST /users/me/typing`). Reconnect with backoff,
  then backfill posts since the cursor. Dedup is by post id.
- **Teams specifics.** Inbound is a webhook: the Bot Connector POSTs
  activities, so the transport is a Rack app (`call(env)`) a host app mounts
  or any Rack server serves; TLS is the operator's. Each POST is
  authenticated by its Bot Framework JWT (RS256 against the OpenID metadata
  JWKS, cached and refetched on an unknown kid; issuer, audience = app id,
  expiry, `serviceUrl` claim = activity, key endorsed for the channel),
  answered 200 at once, and handed to `on_message` on a worker thread.
  Outbound is Bot Connector REST with a client-credentials token from the
  single-tenant Entra app, cached until expiry. jid is
  `teams:<conversation id>`; thread_id is the channel thread's root message
  id (`;messageid=`), else the activity id. Conversation references (service
  URL, conversation, tenant, bot) are `channel_sessions` rows, so proactive
  messages survive a restart. Dedup by activity id. Stdlib only (no `jwt`
  gem, no SDK). Text and Markdown in v1.
- **Channel state is rows** (`channel_cursors`, `channel_sessions`,
  `channel_messages`, `channel_threads` — see [05-state](./05-state.md)), not
  JSON files.
- **A thread maps to a Pi session** (`channel_threads`). One row per
  `(jid, thread_id)` holds the `session_id` passed to Pi as
  `--session-id`; it is minted (a UUID) on the first message in a thread and
  touched on every later one. Runs stay as they are: one agent call is one
  turn, and resuming the session is what carries context between turns. A
  listener calls `channels.session_for(msg)` and runs
  `Remuda.agent(..., session_id: …)`. A workflow that posts a new thread can
  `channels.bind_thread` the thread to the `session_id` of the run that
  wrote its root, so a later reply resumes that run's session. Session
  growth and compaction belong to Pi; Remuda only stores the mapping.
- **Outbound is a tool.** With any transport bound, `channels.send_message`
  is in the tool catalog. `Remuda.tool("channels.send_message", jid:, text:,
  thread_id:, files:)` sends through the registry and records a step like an
  MCP call. The sandboxed agent gets the same tool as `channels_send_message`:
  the runner adds a `channels` entry to the box's `.mcp.json` pointing at the
  per-run forwarder, which answers it in-process on the host
  (`Remuda::ChannelsMcp`). The token stays in `.env`, the send is a step on
  the run, and attachments resolve from `/agent/...` to the agent directory
  on the host, never to `.env` or `.remuda/`. `Remuda.channels(dir)` stays the
  direct API for listeners.
- **Reading a thread is a bounded tool.** `channels.read_thread(jid:,
  thread_id:, limit: 20, before:)` returns one thread's root plus a newest
  window of posts oldest-first, with `from_bot` on bot posts and attachment
  names (never downloads). The host bounds it — `limit` 1-50, each post
  truncated at 4k, ~16k of text per call, dropping the oldest and counting
  them in `omitted` — and pages with a `before` cursor until `nil`. It is
  what lets an agent that was tagged into a thread it has never seen catch up
  without every prompt carrying the whole thread. Pinning `jid`/`thread_id`
  (the `tools:` Hash form) scopes a run to the thread it was tagged in; a
  conflicting call is refused before the transport is touched. Only
  Mattermost implements it; Teams raises `NotImplementedError` for now.
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
- **Durable cursor**: Mattermost keeps its cursor (last `create_at`) in
  memory and accepts `since:`. Persisting it is a `channel_cursors` row once
  05-state lands, so a restarted daemon backfills too.
- Ordering/dedup guarantees per conversation (Agentworks had offset tokens;
  formalize per-`jid` serialization?).
