local Z = require("zoo")
-- Asset Reference gates, one per asset (the zoo's assetrefs phase). Layout: one ROW per asset type, one COLUMN per asset of that type. Each gate is
-- placed and its Asset property is SET to that asset by name (Z.set_name: the asset's name in
-- a component property change, as the game's own edit sends it; the game resolves the asset).
-- The value is read back, so "sent" means it is really set.
-- One type per call, chunked: INVA = { type = "Audio", offset = 0, limit = 100 }.

local grid = Z.grid()
local bcs  = StaticFindObject("/Script/Brickadia.Default__BCSLibrary")
local GG   = "/Game/Bricks/Categories/Wires/GatesGenerated/B_1x1_Gate_"

-- type key -> { brick asset path, row index, primaryType = the Primary Asset type to enumerate
-- by name }. ALWAYS enumerate by primary-asset name, never by ForEachUObject class scan: this
-- script runs once per 100-item chunk, so the list must
-- be identical on every call. A live object scan is not -- if the resident set shifts between
-- chunks the offset window slides and gates are silently skipped or duplicated.
local TYPES = {
  Audio            = { brick = GG.."AudioReference.B_1x1_Gate_AudioReference",                       primaryType = "BrickAudioDescriptor",            row = 1 },
  OneShotAudio     = { brick = GG.."OneShotAudioReference.B_1x1_Gate_OneShotAudioReference",         primaryType = "BrickOneShotAudioDescriptor",     row = 2 },
  WheelEngineAudio = { brick = GG.."WheelEngineAudioReference.B_1x1_Gate_WheelEngineAudioReference", primaryType = "BrickWheelEngineAudioDescriptor", row = 3 },
  Particle         = { brick = GG.."ParticleReference.B_1x1_Gate_ParticleReference",                 primaryType = "BrickParticleSystemDescriptor", row = 4 },
  Font             = { brick = GG.."FontReference.B_1x1_Gate_FontReference",                         primaryType = "BrickFontDescriptor",             row = 5 },
  -- Item/Pickup/Projectile: ClassProperty; primaryType = the Asset field's MetaClass (= the
  -- Primary Asset type name).
  Item             = { brick = GG.."ItemReference.B_1x1_Gate_ItemReference",                         primaryType = "BRItemBase",         row = 6 },
  Pickup           = { brick = GG.."PickupReference.B_1x1_Gate_PickupReference",                     primaryType = "BRPickupBase",       row = 7 },
  Projectile       = { brick = GG.."ProjectileReference.B_1x1_Gate_ProjectileReference",             primaryType = "BRWeaponProjectile", row = 8 },
}

local C = {
  type       = "WheelEngineAudio",
  offset     = 0,
  limit      = 100000,
  baseX      = -600,
  baseY      = 1500,   -- separate area from the component inventory
  colStud    = 4,      -- column spacing (studs)
  rowStud    = 8,      -- row spacing (studs)
  clearFirst = false,
}
if type(INVA) == "table" then for k, v in pairs(INVA) do C[k] = v end end

local t = TYPES[C.type]
if not t then return { error = "unknown type: " .. tostring(C.type) } end
local asset = StaticFindObject(t.brick)
if not (asset and asset:IsValid()) then return { error = "no brick asset: " .. t.brick } end
local bt   = asset.BrickType
local comp = bcs:GetComponentType(grid, asset.DefaultComponentEntries[1].ComponentType)
if not (comp and comp:IsValid()) then return { error = "no component for " .. C.type } end

if C.clearFirst then pcall(function() grid:ClearAndDeleteBricks() end) end

local function placeAt(x, y)
  for _, z in ipairs({ 2, 4, 6, 8, 12, 18 }) do
    local h = Z.place(grid, bt, x, y, z, 19, 3, { 200, 200, 200 })
    if h ~= 0 then return h end
  end
  return 0
end

-- Primary Asset names of a type, sorted (loaded or not)
local enumPrimaryNames = Z.primary_names

local STUD = 10
if not t.primaryType then return { error = "no enumeration source for type " .. C.type .. " (set primaryType)" } end
local items = enumPrimaryNames(t.primaryType)
local y = C.baseY + (t.row - 1) * C.rowStud * STUD
local first = C.offset + 1
local last = math.min(#items, C.offset + C.limit)
-- `missed` names every asset that did NOT end up as a set gate, so a short count is
-- actionable ("340/347" alone can't tell you which 7 sounds are absent from the zoo).
-- `sent` counts values set and read back from the placed gate.
local s = { type = C.type, total = #items, placed = 0, sent = 0, fail = 0, errors = {}, missed = {} }
for i = first, last do
  local x = C.baseX + (i - 1) * C.colStud * STUD
  local name = items[i]
  local h = placeAt(x, y)
  if h ~= 0 then
    s.placed = s.placed + 1
    local r = Z.set_name(h, comp, name)
    if r == "ok" or string.sub(r, 1, 5) == "sent:" then s.sent = s.sent + 1
    else s.fail = s.fail + 1
      s.missed[#s.missed + 1] = tostring(name)
      if #s.errors < 10 then s.errors[#s.errors + 1] = tostring(name) .. "=" .. tostring(r) end
    end
  else
    s.fail = s.fail + 1
    s.missed[#s.missed + 1] = tostring(name)
    if #s.errors < 10 then s.errors[#s.errors + 1] = tostring(name) .. "=place-failed" end
  end
end
s.range = { first = first, last = last }
return s
