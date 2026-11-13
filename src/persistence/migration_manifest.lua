-- Deterministic, bounded manifest. The digest is an integrity checksum, not a
-- cryptographic signature; authenticate the manifest out of band if exported.
local Manifest = {}
local MAX_RECORDS, MAX_BYTES = 200000, 64 * 1024 * 1024

local function checksum(text)
  -- Four independent polynomial residues. Products remain exactly representable
  -- in IEEE-754 doubles used by Lua 5.1.
  local a, b, c, d = 0, 1, 7, 13
  for index = 1, #text do
    local byte = text:byte(index)
    a = (a * 65599 + byte) % 2147483647
    b = (b * 131 + byte) % 2147483629
    c = (c * 257 + byte) % 2147483587
    d = (d * 8191 + byte) % 2147483579
  end
  return string.format("%08x%08x%08x%08x", a, b, c, d)
end

local function encode(json, value)
  local ok, result = pcall(json.encode, value)
  if not ok or type(result) ~= "string" then return nil end
  return result
end

function Manifest.build(snapshot, json, target_identity)
  if type(snapshot) ~= "table" or type(snapshot.records) ~= "table"
    or type(json) ~= "table" or type(json.encode) ~= "function"
    or type(json.array) ~= "function"
    or type(snapshot.source_id) ~= "string" or snapshot.source_id == "" or #snapshot.source_id > 128
    or type(snapshot.snapshot_id) ~= "string" or snapshot.snapshot_id == "" or #snapshot.snapshot_id > 256
    or type(snapshot.format_version) ~= "string" or snapshot.format_version == "" or #snapshot.format_version > 64
    or type(snapshot.write_epoch) ~= "number" or snapshot.write_epoch < 0
    or snapshot.write_epoch ~= snapshot.write_epoch or snapshot.write_epoch == math.huge
    or snapshot.write_epoch % 1 ~= 0 then
    return nil, "invalid_snapshot"
  end
  if type(target_identity) ~= "string" or target_identity == "" or #target_identity > 256 then
    return nil, "invalid_target_identity"
  end
  if #snapshot.records > MAX_RECORDS then return nil, "resource_limit" end

  local records, areas, bytes, previous = json.array({}), {}, 0, nil
  for _, record in ipairs(snapshot.records) do
    if type(record) ~= "table" or type(record.collection) ~= "string" or #record.collection > 128
      or type(record.key) ~= "string" or #record.key == 0 or #record.key > 128
      or type(record.value) ~= "table" or record.value == json.null
      or type(json.is_array) == "function" and json.is_array(record.value) then
      return nil, "invalid_record"
    end
    local identity = record.collection .. "\0" .. record.key
    if previous and identity <= previous then return nil, "records_not_strictly_sorted" end
    previous = identity
    local encoded = encode(json, record.value)
    if not encoded then return nil, "serialization_failed" end
    bytes = bytes + #encoded
    if bytes > MAX_BYTES then return nil, "resource_limit" end
    local entry = { collection = record.collection, key = record.key,
      checksum = checksum(encoded), bytes = #encoded }
    records[#records + 1] = entry
    local area = record.area
    if area ~= "guild" and area ~= "global" then return nil, "invalid_record_area" end
    areas[area] = (areas[area] or 0) + 1
    if record.area == "guild" and record.value.guild ~= record.key then
      return nil, "guild_reference_mismatch"
    end
  end
  local body = {
    schema_version = 2, source = { identity = snapshot.source_id,
      format_version = snapshot.format_version, snapshot_id = snapshot.snapshot_id,
      write_epoch = snapshot.write_epoch },
    target = { identity = target_identity }, records = records,
    counts = { total = #records, bytes = bytes, areas = areas },
  }
  local canonical = encode(json, body)
  if not canonical then return nil, "serialization_failed" end
  body.digest = checksum(canonical)
  return body
end

function Manifest.verify(manifest, snapshot, json, target_identity)
  if type(manifest) ~= "table" or type(snapshot) ~= "table" then return false, "invalid_manifest" end
  local rebuilt, err = Manifest.build(snapshot, json, target_identity)
  if not rebuilt then return false, err end
  local encoded_a, encoded_b = encode(json, manifest), encode(json, rebuilt)
  if not encoded_a or not encoded_b or encoded_a ~= encoded_b then return false, "manifest_mismatch" end
  return true
end

Manifest.checksum = checksum
Manifest.limits = { records = MAX_RECORDS, bytes = MAX_BYTES }
return Manifest
