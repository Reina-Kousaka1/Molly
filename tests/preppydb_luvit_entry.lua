-- Molly's source modules are loaded from disk using Lua's package.path, while
-- Luvit's own libraries live in the executable bundle. Resolve them through
-- Luvit's native loader first, then expose those same modules to standard Lua
-- require for the duration of this isolated integration-test process.
local http = assert(require("http"))
assert(type(http.request) == "function")
assert(type(http.parseUrl) == "function")
print("Luvit HTTP transport: OK")

local uv = assert(require("uv"))
assert(type(uv.run) == "function")
print("Luvit uv module: OK")

package.loaded.http = http
package.loaded.uv = uv

-- Keep the smoke check and the real integration suite in the same Luvit
-- process and runtime context. This script is invoked from the repository root.
dofile("tests/preppydb_integration.lua")
