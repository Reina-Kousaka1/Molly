# KiddyyMolly's year-round preppy identity 🎀

KiddyyMolly uses a single **preppy** profile from `src/seasonal.lua` year-round. The Halloween 2026 / succubus identity is retired.

Her 25 presence lines feature baby pink, Sephora, Stanley cups, skincare, music, and moderation. The writer in `src/presence/rotation.lua` updates presence on READY and every **120 seconds**. Repeated READY events reapply presence without adding another timer.

The Discord library sends updates to active shards, but accepted writes do not guarantee every client immediately displays them. The selector still accepts a timestamp for compatibility but always returns the same profile.
