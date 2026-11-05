local Store = require("src.persistence.guild_store")
local Catalog = require("src.economy.catalog")

local Shop = {}
Shop.__index = Shop

function Shop.new(settings, ledger, modes, sephora)
  assert(type(settings) == "table" and type(settings.get_domain) == "function", "guild settings are required")
  assert(type(ledger) == "table" and type(ledger.purchase) == "function", "economy ledger is required")
  assert(type(modes) == "table" and type(modes.get) == "function", "mode registry is required")
  assert(type(sephora) == "table" and type(sephora.try_on) == "function"
    and type(sephora.select) == "function", "virtual Sephora mode is required")
  return setmetatable({ settings = settings, ledger = ledger, modes = modes, sephora = sephora }, Shop)
end

function Shop:lookbook()
  return self.sephora:lookbook()
end

function Shop:list(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  local mode_ok, mode = self.modes:get(guild)
  if not mode_ok then return false, mode end
  if mode.commerce == "try_on" then
    return true, { mode = "sephora", items = self.sephora:lookbook(), enabled = true, virtual = true }
  end
  if mode.commerce ~= "ledger" then return false, "invalid_mode" end
  local enabled, config = self.settings:get_domain(guild, "shop")
  if not enabled then return false, config end
  if not config.enabled then return false, "shop_disabled" end
  return true, { mode = "kiddy", items = Catalog.list() }
end

function Shop:status(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  local mode_ok, mode = self.modes:get(guild)
  if not mode_ok then return false, mode end
  if mode.commerce == "try_on" then
    return true, { mode = "sephora", enabled = true, ledger_enabled = false, virtual = true }
  end
  if mode.commerce ~= "ledger" then return false, "invalid_mode" end
  local enabled, config = self.settings:get_domain(guild, "shop")
  if not enabled then return false, config end
  return true, { mode = "kiddy", enabled = config.enabled, ledger_enabled = config.enabled, virtual = false }
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
  quantity = quantity or 1
  local mode_ok, mode = self.modes:get(guild)
  if not mode_ok then return false, mode end
  if mode.commerce == "try_on" then
    if not self.sephora:is_look(item_id) then return false, "virtual_item" end
    if type(quantity) ~= "number" or quantity ~= 1 then return false, "virtual_quantity" end
    local selected, result = self.sephora:select(guild, user, item_id, request_id)
    if not selected then return false, result end
    local name = item_id
    for _, look in ipairs(self.sephora:lookbook()) do
      if look.id == item_id then name = look.name; break end
    end
    result.mode, result.name, result.quantity, result.charged = "sephora", name, 1, 0
    return true, result
  end
  if mode.commerce ~= "ledger" then return false, "invalid_mode" end
  local item = Catalog.get(item_id)
  if not item then return false, self.sephora:is_look(item_id) and "virtual_mode" or "unknown_item" end
  local enabled, config = self.settings:get_domain(guild, "shop")
  if not enabled then return false, config end
  if not config.enabled then return false, "shop_disabled" end
  local bought, result = self.ledger:purchase(guild, user, request_id, item.id, item.price, quantity, request_type)
  if not bought then return false, result end
  result.mode, result.name, result.price_each, result.charged = "standard", item.name, item.price, result.amount
  return true, result
end

function Shop:sell(guild, user, request_id, item_id, quantity, request_type)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not Store.valid_id(request_id) then return false, "invalid_argument" end
  local mode_ok, mode = self.modes:get(guild)
  if not mode_ok then return false, mode end
  if mode.commerce == "try_on" then return false, "virtual_mode" end
  if mode.commerce ~= "ledger" then return false, "invalid_mode" end
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
