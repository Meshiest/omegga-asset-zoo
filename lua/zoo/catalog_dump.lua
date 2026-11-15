local Z = require("zoo")
-- The non-component catalog as JSON, with no placement. Where inventory_dump.lua captures bricks + their
-- components + wire ports (which requires placing each brick to probe ports), this
-- script captures the pieces that are pure reflection and need no live grid:
--   * assets      -- every selectable Asset-Reference target, per reference type, by
--                    Primary Asset name
--   * materials   -- BRRegistry.MaterialCollections (indices 3-8 are paintable)
--   * shapes      -- EVERY BasicBrick asset (all shapes, not just the gate sections),
--                    with BrickType metadata + its default component type name(s)
--
-- Writes one JSON object to CAT.outFile (the plugin's /zoo dump sets it). Nothing is
-- placed, so it is safe in any world.

local json = require("omegga.json")

local C = { outFile = "catalog_dump.json" }
if type(CAT) == "table" then for k, v in pairs(CAT) do C[k] = v end end

local reg = StaticFindObject("/Game/Maps/Plate/Plate.Plate:BRRegistry") or FindFirstOf("BRRegistry")
if not (reg and reg:IsValid()) then return { error = "no BRRegistry" } end

local summary = { assets = {}, assetsWithoutMetadata = {}, materialCount = 0, shapeCount = 0, errors = {} }
local function err(m) if #summary.errors < 40 then summary.errors[#summary.errors + 1] = m end end

local function txt(obj, field)
  local ok, v = pcall(function()
    local x = obj[field]
    if x == nil then return "" end
    if type(x) == "userdata" and x.ToString then return tostring(x:ToString()) end
    return tostring(x)
  end)
  return ok and v or ""
end
local function halfSize(bt)
  local ok, v = pcall(function() return { X = bt.HalfSize.X, Y = bt.HalfSize.Y, Z = bt.HalfSize.Z } end)
  return ok and v or { X = 0, Y = 0, Z = 0 }
end

-- Every type is enumerated by Primary Asset name. That is the same source the in-game picker
-- uses (BRCatalogSubsystem::SyncGetOrGeneratePrimaryAssetCatalog takes a PrimaryAssetType), and
-- unlike a ForEachUObject class scan it is load-independent -- a descriptor that happens not to
-- be resident at dump time is still listed. `cls` only finds the loaded object to read
-- CatalogData off. Mirrors asset_reference.lua's TYPES.
local ASSET_TYPES = {
  { key = "Audio",            primaryType = "BrickAudioDescriptor",            cls = "BrickAudioDescriptor" },
  { key = "OneShotAudio",     primaryType = "BrickOneShotAudioDescriptor",     cls = "BrickOneShotAudioDescriptor" },
  { key = "WheelEngineAudio", primaryType = "BrickWheelEngineAudioDescriptor", cls = "BrickWheelEngineAudioDescriptor" },
  { key = "Font",             primaryType = "BrickFontDescriptor",             cls = "BrickFontDescriptor" },
  { key = "Particle",         primaryType = "BrickParticleSystemDescriptor",   cls = "BrickParticleSystemDescriptor" },
  { key = "Item",             primaryType = "BRItemBase" },
  { key = "Pickup",           primaryType = "BRPickupBase" },
  { key = "Projectile",       primaryType = "BRWeaponProjectile" },
}

-- name -> loaded UObject, for reading CatalogData. Only assets currently resident are found;
-- the name list itself comes from the (complete) primary-asset enumeration above.
local function loadedByName(clsName)
  local m = {}
  ForEachUObject(function(o)
    if o and o:IsValid() and o:GetClass():GetFName():ToString() == clsName then
      local nm = o:GetFName():ToString()
      if string.sub(nm, 1, 9) ~= "Default__" then m[nm] = o end
    end
  end)
  return m
end

-- FBRCatalogData (/Script/Brickadia.BRCatalogData) -- the struct behind every picker entry.
-- This is how the game groups assets (Tab > Category) and labels them; matching on the raw
-- asset FName instead gives wrong answers (category "Typewriter" vs item Weapon_TypewriterSMG).
local CD_TEXT = { "DisplayName", "Category", "Tab", "Summary", "SearchTags" }
local CD_BOOL = { "bShouldDisplay", "bAdvanced" }
local function catalogData(o)
  if not o then return nil end
  local cd
  if not pcall(function() cd = o.CatalogData end) or cd == nil then return nil end
  local r, any = {}, false
  for _, f in ipairs(CD_TEXT) do
    local v = ""
    pcall(function() v = tostring(cd[f]:ToString()) end)
    if v ~= "" then r[f] = v; any = true end
  end
  for _, f in ipairs(CD_BOOL) do
    pcall(function() r[f] = (tostring(cd[f]) == "true"); any = true end)
  end
  return any and r or nil
end
local enumPrimaryNames = Z.primary_names

local assets = {}
for _, t in ipairs(ASSET_TYPES) do
  local names = enumPrimaryNames(t.primaryType) or {}
  local objs = t.cls and loadedByName(t.cls) or {}
  -- `entries` carries the picker metadata; `names` is kept as-is for existing consumers.
  local entries, noMeta = {}, 0
  for _, nm in ipairs(names) do
    local e = { name = nm }
    local cd = catalogData(objs[nm])
    if cd then e.catalog = cd else noMeta = noMeta + 1 end
    entries[#entries + 1] = e
  end
  assets[t.key] = {
    source = "primary:" .. t.primaryType,
    count = #names,
    names = names,
    entries = entries,
    withoutMetadata = noMeta,   -- not resident at dump time, so CatalogData was unreadable
  }
  summary.assets[t.key] = #names
  if noMeta > 0 then summary.assetsWithoutMetadata[t.key] = noMeta end
end

-- MaterialCollections is 0-indexed; 3-8 are the paintable materials (see extras.lua).
local materials = {}
pcall(function()
  local mc = reg.MaterialCollections
  local n = (mc and mc.GetArrayNum) and mc:GetArrayNum() or 0
  for i = 1, n do
    local idx = i - 1
    local e = mc[i]
    local name = ""
    if type(e) == "userdata" then
      name = txt(e, "DisplayName")
      if name == "" and e.GetFName then name = e:GetFName():ToString() end
    else
      name = tostring(e)
    end
    materials[#materials + 1] = { index = idx, name = name, paintable = (idx >= 3 and idx <= 8) }
  end
end)
summary.materialCount = #materials

-- every BasicBrick asset with its BrickType metadata and component names
local shapes = {}
ForEachUObject(function(o)
  if o and o:IsValid() and string.sub(o:GetFullName(), 1, 11) == "BasicBrick " then
    pcall(function()
      local path = string.sub(o:GetFullName(), 12)
      local assetName = path:match("([^/.]+)%.[^/.]+$") or path
      local bt = o.BrickType
      local comps = {}
      local entries = o.DefaultComponentEntries
      local nComp = (entries and entries.GetArrayNum) and entries:GetArrayNum() or 0
      for ci = 1, nComp do
        pcall(function()
          local c = entries[ci].ComponentType
          if c and c:IsValid() then comps[#comps + 1] = c:GetFName():ToString() end
        end)
      end
      shapes[#shapes + 1] = {
        assetName = assetName,
        path = path,
        tab = bt and txt(bt, "Tab") or "",
        brickCategory = bt and txt(bt, "Category") or "",
        brickDisplayName = bt and txt(bt, "DisplayName") or "",
        brickSummary = bt and txt(bt, "Summary") or "",
        halfSize = bt and halfSize(bt) or { X = 0, Y = 0, Z = 0 },
        components = comps,
      }
    end)
  end
end)
table.sort(shapes, function(a, b) return a.assetName < b.assetName end)
summary.shapeCount = #shapes

local doc = { assets = assets, materials = materials, shapes = shapes,
              counts = { assets = summary.assets, materials = #materials, shapes = #shapes } }
local f, ferr = io.open(C.outFile, "w")
if not f then return { error = "cannot open outFile: " .. tostring(ferr), outFile = C.outFile } end
f:write(json.encode(doc))
f:close()
summary.outFile = C.outFile
return summary
