package.path = "./?.lua;./?/init.lua;" .. package.path

local Preview = require("src.economy.shop_preview")
local Catalog = require("src.economy.catalog")
local Router = require("src.commands.router")
local ShopCommands = require("src.commands.shop")
local Settings = require("src.settings.guild")
local Response = require("src.discord.response")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

test("fictional collection extends the catalog without replacing legacy items", function()
  local ids = {
    "molly_berryglass_lip_oil", "molly_cloudberry_sleep_mask", "molly_petal_veil_blush",
    "molly_pink_cloud_mist", "molly_satin_bow_claw",
  }
  for _, id in ipairs(ids) do
    local item = Catalog.get(id)
    assert(item and item.id == id and item.price > 0 and item.virtual_value_eur_cents > 0)
    local rendered = Preview.for_item(item)
    assert(rendered and rendered.image_url and Preview.allowed_url(rendered.image_url))
  end
  assert(Catalog.get("rose_glow"), "legacy catalog ID disappeared")
  assert(Catalog.get("rose_crown"), "legacy catalog ID disappeared")
  local first = Catalog.page(1, 8)
  local second = Catalog.page(2, 8)
  assert(first.total >= #ids and first.pages >= 2 and #first.items == 8)
  assert(second.total == first.total and second.page == 2 and #second.items > 0)
end)

test("shop preview maps supported departments to original trusted assets", function()
  local beauty = Preview.for_item({ id = "lip-oil", department = "sephora" })
  local fashion = Preview.for_item({ id = "jacket", department = "lululemon" })
  local jewelry = Preview.for_item({ id = "ring", department = "pandora" })
  assert(beauty and beauty.image_url and Preview.allowed_url(beauty.image_url))
  assert(fashion and fashion.image_url and Preview.allowed_url(fashion.image_url))
  assert(jewelry and jewelry.image_url and Preview.allowed_url(jewelry.image_url))
  assert(beauty.image_url ~= fashion.image_url and fashion.image_url ~= jewelry.image_url)
  assert(not Preview.allowed_url("https://example.com/product.png"))
  assert(not Preview.allowed_url("http://raw.githubusercontent.com/Reina-Kousaka1/Molly/main/assets/shop/molly-beauty-preview.png"))
  assert(not Preview.allowed_url(beauty.image_url .. "?redirect=https://example.com"))
end)

test("items without matching art use a harmless fallback without a fake image URL", function()
  local result = Preview.for_item({ id = "pickaxe", kind = "tool" })
  assert(result and result.image_url == nil and result.fallback == "🎀")
end)

local function run_detail(product_id, retail_product)
  local settings = { get = function() return true, { currency_name = "coins", currency_symbol = "" } end }
  local shop = { lookbook = function() return {} end }
  function shop:retail_item(_, id)
    if id == "retail-test" then return true, retail_product end
    return false, "unknown_item"
  end
  local router, captured = Router.new(), nil
  ShopCommands.register(router, shop, settings)
  local ctx = {
    guild = { id = "73" }, author = { id = "74" }, interaction_id = "75", interaction_token = "fixture",
    molly_subcommand = "item", _molly_category = "Economy", _molly_command_name = "shop",
    args = { product = product_id, page = 1 },
    bot = { application_id = "1", rest = { create_interaction_response = function() return true end } },
    get_arg = function(self, key) return self.args[key] end,
    respond = function(_, _, options) captured = options; return true end,
    edit = function(_, _, options) captured = options; return true end,
  }
  Response.decorate(ctx)
  assert(router:dispatch("shop", ctx))
  return captured and captured.embeds and captured.embeds[1]
end

test("standard virtual item detail is branded and shows the image and Molly Coin price", function()
  local item = Catalog.get("rose_glow")
  assert(item)
  local embed = run_detail("rose_glow")
  assert(embed and embed.title == item.name and embed.description == item.description)
  assert(embed.thumbnail and Preview.allowed_url(embed.thumbnail.url))
  local fields = {}
  for _, field in ipairs(embed.fields or {}) do fields[field.name] = field.value end
  assert(fields.Price and fields.Price:find("coins", 1, true))
  assert(fields["Item ID"] and fields["Item ID"]:find("rose_glow", 1, true))
  assert(embed.author.name == "KiddyyMolly 🎀" and embed.footer.text:find("KiddyyMolly", 1, true))
end)

test("retail detail embeds variants with a department-specific Molly preview", function()
  local product = {
    id = "retail-test", brand = "Fictional source record", name = "Example Lip Oil",
    description = "Catalog facts are summarized here.", category = "makeup/lip-care", department = "sephora",
    available = true, page = 1, pages = 1,
    variants = { { id = "variant-one", variant = "Berry; 5 ml", price = 5000 } },
  }
  local embed = run_detail("retail-test", product)
  assert(embed and embed.title == product.name and embed.thumbnail)
  assert(Preview.allowed_url(embed.thumbnail.url))
  local found = false
  for _, field in ipairs(embed.fields or {}) do
    if field.name == "Variants · page 1/1" then
      found = true
      assert(field.value:find("Berry; 5 ml", 1, true) and field.value:find("variant-one", 1, true))
    end
  end
  assert(found)
end)

io.stdout:write(string.format("%d shop preview tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
