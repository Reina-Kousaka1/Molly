# Molly Personality Engine (V1.2)

The personality engine is a bounded, rule-based layer over the existing Discord message event and guild document. It does not replace command handlers, economy code, or SeaWorld. Each guild's state is stored additively in `molly_v2.personality` through the existing GuildStore and `guild_v2` section helper; legacy flat V1.2 fields are read and retained without a migration.

## Persisted state and privacy

The versioned state contains six clamped 0–100 values (`fomo`, `obsession`, `ego`, `self_esteem`, `social_energy`, and `mood`), a fixed set of topic-interest counters, the current topic, bounded timestamps, and a 128-entry Discord message receipt window. A decimal-string Snowflake watermark makes IDs evicted from that window permanently expired, including after restart; this avoids floating-point precision loss and prevents an old duplicate from becoming new after retention. Retained IDs are checked before the watermark so legitimate out-of-order IDs still found in the window remain idempotent. Once an ID is at or below the watermark and no longer retained, it is ignored as expired. This may drop a genuinely delayed, previously unseen old event, which is safer than replaying a stale event into personality state. Legacy `event_ids` are migrated into the window, with the oldest retained ID used as a conservative expiry boundary when the legacy ring was full. The map and ring remain bounded to 128 entries. It stores no message text, author history, or conversation transcript. Topic counters are capped at 1,000; malformed persisted event-window state and unsupported future schemas fail closed without overwriting the document.

Guilds are isolated by `GuildStore:run`. Store failures fail closed: Molly does not send a spontaneous response if the state update could not be persisted. The engine uses only the existing SeaWorld transaction/session interface; SeaWorld itself is unchanged.

## Activity and conversation behavior

Daypart behavior uses a configured fixed UTC offset, `MOLLY_PERSONALITY_UTC_OFFSET_MINUTES` (default `0`, valid range `-720` to `840`). This is an offset, not an IANA timezone; DST changes require updating the configured offset. State evolves lazily when a relevant message arrives because the current Store API does not enumerate guild documents. Topic changes are scheduled with a persisted randomized 40–80 minute interval rather than on the hour. Late-night FOMO spikes are probabilistic and bounded.

The handler ignores DMs, bots, webhooks, mass mentions, oversized text, irrelevant messages, repeated message IDs, recent duplicate content, and rapid repeat posts. Conversation intensity keeps only a short-lived set of at most 50 participants per channel. In-memory channel, user, fingerprint, and guild maps are capped/pruned. Response probability is capped, and guild/channel/user cooldowns plus a 15-minute restart/reconnect recovery and 15-minute activity ramp suppress bursts. Response text is static and never interpolates user-provided strings.

The personality listener uses the same `on_message` API already used by Molly's prefix router and registers once on the Bot object, not on each reconnect. Replies use the existing Discord REST `send_message` method. Failures are logged with guild/channel context, delivery outcome, and safe Discord HTTP/error codes or a fixed error category; raw exception text, message content, and REST payloads are never logged. A failed send keeps the persisted response cooldown to prevent retry loops. Molly only attempts a reply after a guild message passes validation, and REST permissions remain Discord's authorization boundary.

`molly.lua` already requests Discord's privileged Message Content intent. The Discord Developer Portal must have that intent enabled for live message content to arrive; no portal setting was changed as part of this repository work.

## Status awareness and integration boundary

Presence rotation's writer updates the engine's local status only after Discord accepts the presence update. A user question may trigger one of several status jokes; status self-praise is cooldown-limited and updates ego/self-esteem only when the response is selected. Bot-originated messages are ignored, preventing a self-talk loop. Reconnects do not register another event callback.

The implementation deliberately does not introduce an hourly background guild scan, an external LLM, message-history storage, or a new SeaWorld API. Guild state is updated on relevant conversation events. SeaWorld database outage behavior and concurrent session correctness continue to depend on the currently deployed SeaWorld implementation and should be covered by the existing integration environment.

## Extension points and limits

Personality values and topic state are isolated behind `Engine:_mutate` and the `molly_v2.personality` section. Future traits such as spoiledness, impatience, and persistent favorite products should be added as validated, bounded fields in this section, with behavior kept separate from economy balances and shop pricing. Fictional parent interactions, outfit inventory, and live reference pricing belong in separate domain services; they are not implemented by this engine. A future PreppyDB adapter should be introduced only after its real API and consistency guarantees are available, while the current GuildStore remains the persistence boundary.

Timezone handling intentionally remains a fixed UTC offset. The current runtime path does not provide a verified IANA timezone database, so the engine cannot safely apply DST transitions automatically without adding and validating a dependency or runtime capability. A later timezone enhancement should inject a tested local-time conversion function rather than use host-local time implicitly.
