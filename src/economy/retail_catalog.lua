-- Versioned, reviewed retail snapshots live in data/retail/catalog.tsv.
-- Runtime reads stream the file so a large future catalog is never cached in full.
local Pricing = require("src.economy.retail_pricing")

local Catalog = { VERSION = 3, SCHEMA_VERSION = 3, PAGE_SIZE = 10, MAX_PAGE_SIZE = 10, MAX_VARIANTS_PER_PRODUCT = 500 }
local fields = { "catalog_version", "product_id", "id", "department", "brand", "name", "sku_eu", "sku_us",
  "product_ref_eu", "product_ref_us", "category",
  "description", "color", "variant", "kind", "slot", "eu_cents", "us_cents", "fx_usd_per_eur_x10000",
  "fx_as_of", "fx_source", "checked_at", "source_eu", "source_us", "price_note", "available" }
local function root_path()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  local root = source:match("^(.*)[/\\]src[/\\]economy[/\\]retail_catalog%.lua$")
  return (root and (root .. "/") or "") .. "data/retail/catalog.tsv"
end
local DATA_PATH = root_path()
do
  local file = io.open(DATA_PATH, "r")
  if file then
    local first = file:read("*l") or ""
    local second = file:read("*l") or ""
    local version = first:match("^# catalog_version=(%d+)$")
    if version then Catalog.VERSION = tonumber(version) end
    local schema = second:match("^# schema_version=(%d+)$")
    if tonumber(schema) ~= Catalog.SCHEMA_VERSION then Catalog.INVALID_SCHEMA = true end
    file:close()
  end
end
local function normalized_page(page, page_size)
  page = tonumber(page)
  if not page or page ~= page or page == math.huge or page == -math.huge then page = 1 end
  page = math.max(1, math.min(1000000, math.floor(page)))
  page_size = tonumber(page_size)
  if not page_size or page_size ~= page_size or page_size == math.huge or page_size == -math.huge then page_size = Catalog.PAGE_SIZE end
  page_size = math.min(Catalog.MAX_PAGE_SIZE, math.max(1, math.floor(page_size)))
  return page, page_size
end

local function split(line)
  local result, start = {}, 1
  while true do
    local at = line:find("\t", start, true)
    if not at then result[#result + 1] = line:sub(start); break end
    result[#result + 1] = line:sub(start, at - 1)
    start = at + 1
  end
  return result
end

local function valid_reference(value, optional)
  if optional and value == "-" then return true end
  return type(value) == "string" and #value > 0 and #value <= 100 and value:match("^[%w_%-]+$") ~= nil
end

local function read_row(line)
  if Catalog.INVALID_SCHEMA then return nil, "catalog_schema_unsupported" end
  local values = split(line)
  if #values ~= #fields then return nil, "catalog_invalid" end
  local row = {}
  for index, key in ipairs(fields) do row[key] = values[index] end
  row.catalog_version, row.eu_cents, row.us_cents, row.fx_usd_per_eur_x10000 =
    tonumber(row.catalog_version), tonumber(row.eu_cents), tonumber(row.us_cents), tonumber(row.fx_usd_per_eur_x10000)
  if row.catalog_version ~= Catalog.VERSION or type(row.id) ~= "string" or not row.id:match("^[%w_%-]+$")
    or #row.id > 32 or not row.product_id:match("^[%w_%-]+$") or #row.product_id > 64
    or (row.department ~= "sephora" and row.department ~= "lululemon" and row.department ~= "pandora")
    or row.brand == "" or row.name == "" or row.category == "" or row.variant == ""
    or not valid_reference(row.product_ref_eu, false) or not valid_reference(row.product_ref_us, false)
    or not valid_reference(row.sku_eu, true) or not valid_reference(row.sku_us, true)
    or (row.kind ~= "fashion" and row.kind ~= "collectible")
    or (row.slot ~= "-" and row.slot ~= "outfit" and row.slot ~= "head" and row.slot ~= "accessory"
      and row.slot ~= "ring" and row.slot ~= "necklace" and row.slot ~= "bracelet")
    or (row.available ~= "true" and row.available ~= "false") then return nil, "catalog_invalid" end
  local rate = { usd_per_eur_x10000 = row.fx_usd_per_eur_x10000, as_of = row.fx_as_of, source = row.fx_source }
  local price, snapshot = Pricing.snapshot(row.eu_cents, row.us_cents, rate, row.checked_at)
  if not price then return nil, "catalog_invalid" end
  row.price, row.price_snapshot = price, snapshot
  row.sku = row.sku_us ~= "-" and row.sku_us or (row.sku_eu ~= "-" and row.sku_eu or nil)
  row.available = row.available == "true"
  if row.color == "-" then row.color = nil end
  if row.slot == "-" then row.slot = nil end
  if row.price_note == "-" then row.price_note = nil end
  return row
end

local function each_product(callback)
  local file = io.open(DATA_PATH, "r")
  if not file then return false, "catalog_unavailable" end
  local current, current_id = nil, nil
  local function finish()
    if not current then return true end
    current.available = false
    for _, variant in ipairs(current.variants) do if variant.available then current.available = true end end
    return callback(current)
  end
  for line in file:lines() do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local row, reason = read_row(line)
      if not row then file:close(); return false, reason end
      if row.product_id ~= current_id then
        local keep_going, callback_reason = finish()
        if keep_going == false then
          file:close()
          if callback_reason == "stop" then return true end
          return false, callback_reason
        end
        current_id, current = row.product_id, {
          id = row.product_id, department = row.department, brand = row.brand, name = row.name, sku = row.sku,
          product_ref_eu = row.product_ref_eu, product_ref_us = row.product_ref_us,
          category = row.category, description = row.description, color = row.color,
          kind = row.kind, slot = row.slot,
          source_eu = row.source_eu, source_us = row.source_us, price_note = row.price_note,
          catalog_version = row.catalog_version, variants = {},
        }
      elseif current.brand ~= row.brand or current.name ~= row.name or current.department ~= row.department
        or current.category ~= row.category or current.product_ref_eu ~= row.product_ref_eu
        or current.product_ref_us ~= row.product_ref_us then file:close(); return false, "catalog_product_conflict" end
      if #current.variants >= Catalog.MAX_VARIANTS_PER_PRODUCT then file:close(); return false, "catalog_product_capacity" end
      current.variants[#current.variants + 1] = row
    end
  end
  local keep_going, callback_reason = finish()
  file:close()
  if keep_going == false then return callback_reason == "stop", callback_reason end
  return true
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function contains(haystack, needle)
  return needle == nil or needle == "" or haystack:lower():find(needle:lower(), 1, true) ~= nil
end
local function matches(product, filters, include_archived)
  filters = filters or {}
  if filters.department and filters.department ~= product.department then return false end
  if filters.brand and not contains(product.brand, filters.brand) then return false end
  if filters.category and not contains(product.category, filters.category) then return false end
  if filters.query and not (contains(product.name, filters.query) or contains(product.brand, filters.query)
    or contains(product.category, filters.query)) then return false end
  return include_archived or product.available
end

function Catalog.get(id)
  if type(id) ~= "string" or #id > 32 then return nil end
  local found
  local ok = each_product(function(product)
    for _, variant in ipairs(product.variants) do if variant.id == id then found = copy(variant); return false, "stop" end end
  end)
  if not ok then return nil end
  return found
end

function Catalog.get_product(id, page, page_size)
  if type(id) ~= "string" or #id > 64 then return nil end
  page, page_size = normalized_page(page, page_size)
  local found
  local ok = each_product(function(product)
    if product.id == id then
      local variants, available_count = {}, 0
      for _, variant in ipairs(product.variants) do
        if variant.available then
          available_count = available_count + 1
          if available_count > (page - 1) * page_size and #variants < page_size then variants[#variants + 1] = copy(variant) end
        end
      end
      product.variants, product.variant_count, product.page, product.page_size = variants, available_count, page, page_size
      product.pages = math.max(1, math.ceil(available_count / page_size))
      found = copy(product)
      return false, "stop"
    end
  end)
  if not ok then return nil end
  return found
end

function Catalog.page(filters, page, page_size)
  filters = type(filters) == "string" and { department = filters } or (filters or {})
  page, page_size = normalized_page(page, page_size)
  local products, total = {}, 0
  local ok, reason = each_product(function(product)
    if matches(product, filters, false) then
      total = total + 1
      if total > (page - 1) * page_size and #products < page_size then products[#products + 1] = copy(product) end
    end
  end)
  if not ok then return nil, reason end
  return { items = products, total = total, page = page, page_size = page_size, pages = math.max(1, math.ceil(total / page_size)) }
end

function Catalog.search_page(query, filters, page, page_size)
  if type(query) ~= "string" or #query < 1 or #query > 80 then return nil, "invalid_query" end
  filters = filters or {}; filters.query = query
  return Catalog.page(filters, page, page_size)
end

-- Compatibility helpers return only the first bounded page. New callers should use page().
function Catalog.list(department)
  local result = Catalog.page({ department = department }, 1, Catalog.MAX_PAGE_SIZE)
  return result and result.items or {}
end
function Catalog.search(query, department)
  local result = Catalog.search_page(query, { department = department }, 1, Catalog.MAX_PAGE_SIZE)
  return result and result.items or {}
end
function Catalog.variants(limit)
  limit = tonumber(limit)
  if not limit or limit ~= limit or limit == math.huge or limit == -math.huge then limit = 1000 end
  limit = math.min(1000, math.max(1, math.floor(limit)))
  local result = {}
  local ok = each_product(function(product)
    for _, variant in ipairs(product.variants) do
      if variant.available and #result < limit then result[#result + 1] = copy(variant) end
    end
  end)
  return ok and result or {}
end
function Catalog.departments() return { "sephora", "lululemon", "pandora" } end
return Catalog
