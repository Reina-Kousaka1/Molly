# Lua 5.5.1 migration assessment

Molly currently runs with Luvit/LuaJIT (Lua 5.1 semantics). The container
executes the separately supplied `runtime/luvit`; that binary and `deps/` are
not in the repository checkout. CI runs the service-independent suites with
PUC Lua 5.1. This document is a migration plan, not a change to the deployed
runtime.

## Evidence from the first pass

- Official Lua 5.5.1 source archive was checked against SHA-256
  `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`
  and built in an isolated Ubuntu WSL environment on 2026-11-06.
- `luac -p` parsed `molly.lua` and every Lua file under `src/` and `tests/`.
- The first CI-safe run under Lua 5.5.1 stopped at three stale assertions in
  `tests/economy_v2.lua`. Those same assertions failed in the Lua 5.1 GitHub
  CI. The tests now reflect the paid, ownership-gated look model and the
  current shop command tree. A retained Sephora request is resolved before
  current ownership, so replay remains stable if inventory changes.
- After those corrections, the full CI-safe matrix, including its stress
  profile and Python configuration checks, passed locally under both Lua 5.1
  and Lua 5.5.1. This still does not qualify the live Luvit runtime.
- The PreppyDB connector and its bundled client passed under Lua 5.5.1 up
  to that point. No live database or Discord service was used.

## Migration gates

1. Keep the repaired Lua 5.1 economy test baseline green in GitHub CI.
2. Add a separate, pinned Lua 5.5.1 job for all service-independent suites.
   Keep the Lua 5.1 job until the runtime cutover is qualified.
3. Inventory the deployed `runtime/luvit` and `deps/` binaries and versions.
   Build a Lua 5.5.1-capable Luvi/Luvit stack, or identify a replacement
   runtime with the same required `uv`, HTTP, TLS, coroutine, and Discord APIs.
   Rebuild native modules against the selected Lua ABI.
4. Run the Luvit-dependent tests, then disposable Discord, Lavalink, SeaWorld,
   and PreppyDB integration checks with no production credentials or data.
5. Qualify the complete runtime on Linux ARM64 hardware, including startup,
   shutdown, reconnects, memory use, and representative workload latency.
   Only then change the container entrypoint and Pi service artifact.

Lua 5.5.1 alone does not change SeaWorld or PreppyDB file formats. JSON number
and null semantics at the client boundary still need differential tests across
the old and new runtimes. Until the runtime gate is complete, production Molly
continues to use its existing Luvit binary.
