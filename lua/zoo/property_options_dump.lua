local Z = require("zoo")
-- The game's own PropertyName picker for every Environment and every Component Type, read by
-- placing one gate per selection, setting the selection, and calling GetPropertyOptions/Labels.
-- CLEARS THE GRID. Returns { environments = { [option] = {options, labels} }, components = {...} }.
--
-- The selection is set by name (Z.set_name), as a real edit sends it and as an asset-reference
-- gate's Asset is.
-- GetPropertyOptions must be called on the REGISTERED component type (/Engine/Transient.*); on the
-- CDO it has no world to find the gate brick in and returns an empty list.

local reg  = FindFirstOf("BRRegistry")
local grid = reg.CachedGlobalBrickGrid
local bcs  = StaticFindObject("/Script/Brickadia.Default__BCSLibrary")
if not (grid and grid:IsValid()) then return { error = "no live brick grid" } end
local GG = "/Game/Bricks/Categories/Wires/GatesGenerated/B_1x1_Gate_"



local function gateKind(name)
  local asset = StaticFindObject(GG .. name .. ".B_1x1_Gate_" .. name)
  return {
    bt = asset.BrickType,
    comp = bcs:GetComponentType(grid, asset.DefaultComponentEntries[1].ComponentType),
    cdo = StaticFindObject("/Script/Brickadia.Default__BrickComponentType_" .. name),
  }
end

local function place(kind, x, y)
  for _, z in ipairs({ 2, 4, 6, 8 }) do
    local h = Z.place(grid, kind.bt, x, y, z, 19, 3, { 200, 200, 200 })
    if h ~= 0 then return h end
  end
  return 0
end

local function strings(a)
  local t = {}
  for _, v in ipairs(a) do
    local s = v
    if type(s) ~= "string" then pcall(function() s = v:get():ToString() end) end
    t[#t + 1] = tostring(s)
  end
  return t
end

-- Phase "set" places and configures the gates; the edits apply on a LATER tick, so the options
-- must be read by a second call (phase "read"), which uses the handles kept in PO_STATE.
local function set(kind, prop, base, optionsFn, row)
  local opts = strings(kind.cdo[optionsFn](kind.cdo, {}))
  local placed, failed = {}, {}
  for i, opt in ipairs(opts) do
    local h = place(kind, (i - 1) * 40, row * 80)
    if h ~= 0 then
      Z.set_name(h, kind.comp, opt, prop)
      placed[#placed + 1] = { opt = opt, h = h }
    else
      failed[#failed + 1] = opt
    end
  end
  return { kind = kind, base = base, placed = placed, failed = failed }
end

local function ptype(p)
  local t = { kind = p:GetClass():GetFName():ToString() }
  pcall(function() t.struct = p:GetStruct():GetFName():ToString() end)
  pcall(function() t.enum = p:GetEnum():GetFName():ToString() end)
  pcall(function() t.class = p:GetPropertyClass():GetFName():ToString() end)
  pcall(function() t.inner = p:GetInner():GetClass():GetFName():ToString() end)
  return t
end

-- ForEachProperty only walks a struct's OWN fields; shared ones (the interaction prompt fields,
-- the light fields) live on a parent data struct.
local function findProp(struct, name)
  local found
  local cur = struct
  while cur and not found do
    cur:ForEachProperty(function(p)
      if not found and p:GetFName():ToString() == name then found = p end
    end)
    local ok, sup = pcall(function() return cur:GetSuperStruct() end)
    cur = (ok and sup and sup:IsValid()) and sup or nil
  end
  return found
end

-- FProperty type of a picker name ("Brightness", "Color.R") inside a component's DataStruct.
-- Includes transient fields (bHeld, PressCount, ...) that a save's schema never carries.
local function typeIn(struct, path)
  local cur, p = struct, nil
  for part in string.gmatch(path, "[^.]+") do
    if not cur then return nil end
    p = findProp(cur, part)
    if not p then return nil end
    cur = nil
    pcall(function() cur = p:GetStruct() end)
  end
  return p and ptype(p)
end

-- Re-resolve the receiver by path on every call: the component-type userdata kept in PO_STATE
-- from the set call makes GetPropertyOptions return an empty list.
local function read(s, gate, withTypes)
  local out = {}
  local comp = StaticFindObject("/Engine/Transient.BrickComponentType_" .. gate)
  for _, p in ipairs(s.placed) do
    local e = {
      options = Z.gate_options(comp, s.base .. "GetPropertyOptions", p.h),
      labels = Z.gate_options(comp, s.base .. "GetPropertyLabels", p.h),
    }
    if withTypes then
      local ds
      pcall(function() ds = StaticFindObject("/Engine/Transient." .. p.opt).DataStruct end)
      e.types = {}
      for _, name in ipairs(e.options) do
        e.types[name] = (ds and typeIn(ds, name)) or { kind = "unresolved" }
      end
    end
    out[p.opt] = e
  end
  for _, opt in ipairs(s.failed) do out[opt] = { error = "place failed" } end
  return out
end

local phase = (type(PO) == "table" and PO.phase) or "set"
if phase == "set" then
  pcall(function() grid:ClearAndDeleteBricks() end)
  PO_STATE = {
    environments = set(gateKind("Exec_GetEnvironmentProperty"), "Environment",
      "/Script/Brickadia.BrickComponentType_Exec_EnvironmentPropertyBase:", "GetEnvironmentOptions", 0),
    components = set(gateKind("Exec_GetComponentProperty"), "ComponentType",
      "/Script/Brickadia.BrickComponentType_Exec_ComponentPropertyBase:", "GetComponentTypeOptions", 1),
  }
  return { phase = "set", environments = #PO_STATE.environments.placed, components = #PO_STATE.components.placed }
end
if not PO_STATE then return { error = "run phase 'set' first" } end
return {
  environments = read(PO_STATE.environments, "Exec_GetEnvironmentProperty", false),
  components = read(PO_STATE.components, "Exec_GetComponentProperty", true),
}
