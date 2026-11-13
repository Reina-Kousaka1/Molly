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

local net = assert(require("coro-net"))
assert(type(net.connect) == "function")
print("Luvit coro-net dependency: OK")

local http_client = assert(require("coro-http"))
assert(type(http_client.request) == "function")
print("Luvit coro-http dependency: OK")

package.loaded.http = http
package.loaded.uv = uv

-- Keep each native test in the same Luvit runtime context. Only these explicit
-- repository test entrypoints may be selected by the CI wrapper.
local allowed_tests = {
  integration = "tests/preppydb_integration.lua",
  restart = "tests/preppydb_restart.lua",
}
local selection = os.getenv("MOLLY_PREPPYDB_TEST")
local selected_test = selection and allowed_tests[selection]
assert(selected_test, "MOLLY_PREPPYDB_TEST must be 'integration' or 'restart'")
print("Selected PreppyDB test: " .. selection)
dofile(selected_test)
