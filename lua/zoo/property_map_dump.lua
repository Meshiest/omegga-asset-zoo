-- Reflection pass for the Environment/Component property gates' option lists.
-- Returns (does not write a file):
--   spawnable    -- component types with bPlayerSpawnable (superset of the Component Type picker)
--   environments -- each BR*Environment class's own UPROPERTYs with their FProperty types
--   pickers      -- the gates' real Environment / Component Type option + label lists
-- The plugin (src/properties.ts) merges this with the zoo save's Environment.bp preset and
-- the brdb component schema into out/property_map.json.
--
-- Do NOT iterate BRReflectionTypeInfo.Categories / CachedProperties from Lua: reading those map
-- values crashed the game.

local function ptype(p)
  local t = { kind = p:GetClass():GetFName():ToString() }
  pcall(function() t.struct = p:GetStruct():GetFName():ToString() end)
  pcall(function() t.enum = p:GetEnum():GetFName():ToString() end)
  pcall(function() t.class = p:GetPropertyClass():GetFName():ToString() end)
  pcall(function() t.inner = p:GetInner():GetClass():GetFName():ToString() end)
  return t
end

local base = StaticFindObject("/Script/Brickadia.BCSComponentTypeBase")
local spawnable = {}
ForEachUObject(function(o)
  local ok, full = pcall(function() return o:GetFullName() end)
  if not ok or not full or not full:find("/Engine/Transient.", 1, true) then return end
  local okc, isa = pcall(function() return o:IsA(base) end)
  if not (okc and isa) then return end
  local okp, ps = pcall(function() return o.bPlayerSpawnable end)
  if not (okp and ps) then return end
  local e = { name = o:GetFName():ToString(), displayName = "", category = "" }
  pcall(function() e.displayName = o.DisplayName:ToString() end)
  pcall(function() e.category = o.Category:ToString() end)
  spawnable[#spawnable + 1] = e
end)
table.sort(spawnable, function(a, b) return a.displayName < b.displayName end)

-- Stop at engine base classes: their properties are never environment settings.
local stopAt = { Actor = true, Object = true, StaticMeshActor = true, BRPhysicsPlaneVolume = true }
local environments = {}
for _, env in ipairs({ "Sky", "Ground", "Water", "Ambience", "Space", "Studio" }) do
  local cls = StaticFindObject("/Script/Brickadia.BR" .. env .. "Environment")
  local e = { class = "BR" .. env .. "Environment", displayName = "", properties = {} }
  local cur = cls
  while cur and cur:IsValid() and not stopAt[cur:GetFName():ToString()] do
    cur:ForEachProperty(function(p)
      local t = ptype(p)
      t.name = p:GetFName():ToString()
      e.properties[#e.properties + 1] = t
    end)
    local ok, sup = pcall(function() return cur:GetSuperStruct() end)
    if not ok then break end
    cur = sup
  end
  ForEachUObject(function(x)
    local ok, f = pcall(function() return x:GetFullName() end)
    if ok and f:find("Transient.BRGameEngine", 1, true) and f:find("ClassInfo_" .. env .. "Environment", 1, true) then
      pcall(function() e.displayName = x.DisplayName:ToString() end)
    end
  end)
  environments[env] = e
end

-- The gates' own picker lists. These GetOptions functions ignore their GateBrick arg, so an empty
-- handle is safe here. GetPropertyOptions is NOT: it reads the gate's current selection through
-- the handle.
local function strings(a)
  local t = {}
  for _, v in ipairs(a) do
    -- Elements arrive as RemoteUnrealParam wrappers around an FString.
    local s = v
    if type(s) ~= "string" then pcall(function() s = v:get():ToString() end) end
    if type(s) ~= "string" then pcall(function() s = v:ToString() end) end
    t[#t + 1] = tostring(s)
  end
  return t
end
local function picker(cdoPath, optFn, labelFn)
  local cdo = StaticFindObject(cdoPath)
  local opts, labels = strings(cdo[optFn](cdo, {})), strings(cdo[labelFn](cdo, {}))
  local out = {}
  for i, o in ipairs(opts) do out[#out + 1] = { option = o, label = labels[i] or "" } end
  return out
end
local pickers = {
  environment = picker("/Script/Brickadia.Default__BrickComponentType_Exec_GetEnvironmentProperty",
    "GetEnvironmentOptions", "GetEnvironmentLabels"),
  componentType = picker("/Script/Brickadia.Default__BrickComponentType_Exec_GetComponentProperty",
    "GetComponentTypeOptions", "GetComponentTypeLabels"),
}

return { spawnable = spawnable, environments = environments, pickers = pickers }
