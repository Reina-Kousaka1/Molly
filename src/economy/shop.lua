local Store = require("src.persistence.guild_store")
local Catalog = require("src.economy.catalog")

local Shop = {}
Shop.__index = Shop

function Shop.new(settings, ledger, modes, sephora)
  assert(type(settings) == "table" and type(settings.get_domain) == "function", "guild settings are required")
  assert(type(ledger) == "table" and type(ledger.purchase) == "function", "economy ledger is required")
  assert(type(modes) == "table" and type(modes.get) == "function", "mode registry is required")
  assert(type(sephora) == "table" and type(sephora.try_on) == "function", "virtual Sephora mode is required")
  return setmetatable({ settings = settings, ledger = ledger, modes = modes, sephora = sephora }, Shop)
end

function Shop:lookbook()
  return self.sephora:lookbook()
end

function Shop:list(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  local ok, mode = self.modes:get(guild)
  if not ok then return false, mode end
  if mode.commerce == "try_on" then return true, { mode = mode.id, items = self.sephora:lookbook() } end
  local enabled, config = self.settings:get_domain(guild, "shop")
  if not enabled then return false, config end
  if not config.enabled then return false, "shop_disabled" end
  return true, { mode = mode.id, items = Catalog.list() }
end

function Shop:status(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  local ok, mode = self.modes:get(guild)
  if not ok then return false, mode end
  local enabled, config = self.settings:get_domain(guild, "shop")
  if not enabled then return false, config end
  return true, { mode = mode.id, enabled = mode.commerce == "try_on" or config.enabled,
    ledger_enabled = config.enabled, virtual = mode.commerce == "try_on" }
end

function Shop:set_enabled(guild, enabled)
  if not Store.valid_id(guild) or type(enabled) ~= "boolean" then return false, "invalid_argument" end
  return self.settings:update_domain(guild, "shop", function(config)
    if config.enabled == enabled then return false end
    config.enabled = enabled
    return true
  end)
end

function Shop:buy(guild, user, request_id, item_id, quantity, request_type)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not Store.valid_id(request_id) then return false, "invalid_argument" end
  local ok, mode = self.modes:get(guild)
  if not ok then return false, mode end
  quantity = quantity or 1
  if mode.commerce == "try_on" then
    if quantity ~= 1 then return false, "virtual_quantity" end
    if not self.sephora:is_look(item_id) then return false, "virtual_item" end
    local selected, result = self.sephora:try_on(guild, user, item_id, request_id)
    if not selected then return false, result end
    return true, { mode = "sephora", item_id = result.look_id, quantity = 1, charged = 0, replayed = result.replayed }
  end
  if self.sephora:is_look(item_id) then return false, "virtual_mode" end
  local enabled, config = self.settings:get_domain(guild, "shop")
  if not enabled then return false, config end
  if not config.enabled then return false, "shop_disabled" end
  local item = Catalog.get(item_id)
  if not item then return false, self.sephora:is_look(item_id) and "virtual_mode" or "unknown_item" end
  local bought, result = self.ledger:purchase(guild, user, request_id, item.id, item.price, quantity, request_type)
  if not bought then return false, result end
  result.mode, result.name, result.price_each, result.charged = "standard", item.name, item.price, result.amount
  return true, result
end

function Shop:sell(guild, user, request_id, item_id, quantity, request_type)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not Store.valid_id(request_id) then return false, "invalid_argument" end
  local ok, mode = self.modes:get(guild)
  if not ok then return false, mode end
  if mode.commerce == "try_on" then return false, "virtual_mode" end
  local enabled, config = self.settings:get_domain(guild, "shop")
  if not enabled then return false, config end
  if not config.enabled then return false, "shop_disabled" end
  local item = Catalog.get_resource(item_id)
  if not item then return false, "unknown_item" end
  quantity = quantity or 1
  local sold, result = self.ledger:sell(guild, user, request_id, item_id, quantity, request_type)
  if not sold then return false, result end
  result.mode, result.name, result.charged = "standard", item.name, result.amount
  return true, result
end

return Shop
