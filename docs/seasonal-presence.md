# Seasonal identity and presence

Molly selects one seasonal profile centrally in `src/seasonal.lua`. The
Halloween 2026 profile is active from **30 October 2026 00:00** up to (but not
including) **2 November 2026 00:00**, in **Europe/Berlin**. This corresponds to
`2026-10-29T23:00:00Z` through `2026-11-01T23:00:00Z`; daylight saving time has
already ended in Berlin for this interval.

During that window Molly uses the Succubus personality and 25 Halloween
presence lines. At every other time—including immediately after the end
boundary—she uses her default moderation/staff personality and 25 timeless
presence lines. There is no transformation state machine.

The single `src/presence/rotation.lua` writer updates Discord immediately on
READY and then every 120 seconds. A repeated READY re-applies the current
presence without adding another timer. The Discord library's supported
`Bot:change_presence` API sends a Gateway Presence Update to its active shard
or shards. Molly logs the selected profile and line index after the library
accepts the update; it does not claim that Discord has acknowledged or
displayed the update to every client.

The seasonal selector uses UTC timestamps and explicit Berlin-to-UTC bounds,
so the container's timezone setting does not affect the seasonal boundary.
