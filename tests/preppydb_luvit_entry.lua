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

-- Keep each native test in the same Luvit runtime context. Only these explicit
-- repository test entrypoints may be selected by the CI wrapper.
local allowed_tests = {
  ["tests/preppydb_integration.lua"] = true,
  ["tests/preppydb_restart.lua"] = true,
}
local selected_test = arg and arg[1] or "tests/preppydb_integration.lua"
assert(allowed_tests[selected_test], "unsupported PreppyDB integration test entrypoint")
dofile(selected_test)
