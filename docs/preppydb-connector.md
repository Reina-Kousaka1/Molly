# PreppyDB API connector

`src.preppydb.connector` provides Molly with an optional HTTP client boundary to
PreppyDB `/v1`. It includes a copy of PreppyDB's AGPL-3.0 Lua/Luvit client from
PR #1 (`clients/luvit/preppydb.lua`, remote commit `c5b0042`). Molly does not
open PreppyDB files. No existing Molly feature is routed to this connector and
no data is migrated by adding it.

```lua
local Connector = require("src.preppydb.connector")
local db = assert(Connector.new({
  url = "http://127.0.0.1:7077",
  token = os.getenv("MOLLY_PREPPYDB_TOKEN"),
  timeout_ms = 5000,
  max_response_bytes = 1024 * 1024,
}))

-- In Luvit's event loop, use the callback API.
db:request("GET", "/v1/version", nil, function(version, err)
  if err then return end
  print(version.version)
end)
```

The connector also exposes `health`, `ready`, `version`, `collections`,
`collection`, `create_collection`, `get`, `put`, `delete`, `scan`, `find`,
`range`, and `batch` with the official client's synchronous return convention:
`result, err`. Those methods require a synchronous injected transport or an
appropriate event-loop `wait` function. `request` uses the client's asynchronous
Luvit transport and reports `result, err` to the callback. API errors retain
their machine-readable `code`; `get` returns the full document envelope,
including its version for conditional writes. The default client does not
automatically retry writes. A transport failure after a write leaves its
outcome unknown; inspect the document before deciding whether to retry.

The token is provided at runtime, never stored in source. The current client
speaks plain HTTP. Keep it on loopback or a trusted private transport; do not
expose a bearer token over an untrusted network. Connecting this module to
Molly features, choosing data ownership, and Raspberry Pi deployment are
separate steps.
