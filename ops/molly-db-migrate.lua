-- One-shot operator entry point. Live operations are policy-gated and currently
-- fail closed; --synthetic uses only deterministic in-memory test adapters.
local Cli = require("src.persistence.molly_db_migrator_cli")

local arguments = rawget(_G, "args") or arg or {}
local normalized = {}
for index = 1, #arguments do
  local value = arguments[index]
  if type(value) == "string" and not (index == 1 and value:match("%.lua$")) then
    normalized[#normalized + 1] = value
  end
end

local exit_code = Cli.execute(normalized)
os.exit(exit_code)
