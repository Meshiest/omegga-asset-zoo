local Z = require("zoo")
-- The inventory dump. Where inventory.lua builds the zoo in the world, this writes
-- NDJSON (one record per brick) describing every brick, its built-in
-- component(s), and each component's wire ports (name, signal type, input/output) --
-- shaped like wirescript/logic_gate_inventory.full.json. Nothing about specific
-- gates/components is hardcoded; everything is discovered at runtime.
--
-- For each brick it:
--   1. reads brick metadata from asset.BrickType (Tab, HalfSize, Summary, Category,
--      DisplayName) -- placement-free, all accurate in the shipping build,
--   2. for each asset.DefaultComponentEntries[i].ComponentType, maps the class to the
--      registered component object (BCSLibrary:GetComponentType) and reads its metadata
--      (DisplayName, Category, Description, CurrentVersion, bPlayerSpawnable,
--      bCountsTowardsQuota, NoWireProperties) -- also placement-free and accurate,
--   3. discovers ALL wire ports: the component DataStruct + its super-structs + one-level
--      struct sub-property expansion (e.g. ExitOffset.X),
--   4. classifies each port input/output -- THIS step needs a live placed brick, so the
--      brick is placed at the origin, probed (Z.port), then immediately deleted
--      (place -> probe -> ClearAndDeleteBricks, one brick at a time; the grid never holds
--      more than one brick, so no layout/collision handling is needed).
--
-- Per-port tooltips and display names are editor-only metadata, stripped from shipping
-- builds, so a port's `tooltip` is "" and its `displayName` is derived from the field name
-- (camelCase and underscores to Title Case). Component- and brick-level DisplayName,
-- Category and Description are real cooked properties. (wirescript's
-- logic_gate_inventory.full.json came from an editor build, hence its port tooltips.)
--
-- Game access goes through zoo.lua (omegga-ue4ss's BR): Z.place, Z.port (port direction),
-- Z.attach (standalone phase).
--
-- The plugin (/zoo dump) runs it per chunk with DUMP = { offset, limit, outFile, ... }:
-- the catalog bricks (the first chunk has clearFirst, which truncates outFile and clears
-- the grid), then standalone = true for brickless components, then procedural = true,
-- all appended to the same file.

local json = require("omegga.json")

local DEFAULTS = {
  sections = { "Physics", "Mechanics", "LogicGates", "Wires/GatesGenerated", "Wires/Exec" },
  includeWiresRoot = true,   -- include rerouter / microchip / microchip I/O routers (depth-1 /Wires/)
  standalone = false,        -- dump brickless components (Light, TextDisplay, ...) instead of catalog
  procedural = false,        -- dump ProceduralBrick assets (/Game/Bricks/Procedural/) instead of catalog
  offset = 0,
  limit = 100000,            -- everything by default; the plugin sends 80 per call (5 s watchdog)
  clearFirst = false,        -- truncate outFile (open "w") + clear the grid before starting
  baseZ = 2,
  material = 3,
  skipTabs = { "DONOTUSE" },  -- skip deprecated/hidden bricks whose Tab contains any of these (substring)
  probeOrient = 19,          -- upright; orientation is irrelevant for probing, only placement
  hostBrick = "/Game/Bricks/Categories/Rounds/Round/B_1x1F_Round.B_1x1F_Round",
  outFile = "inventory_dump.ndjson",
}

local C = {}
for k, v in pairs(DEFAULTS) do C[k] = v end
if type(DUMP) == "table" then for k, v in pairs(DUMP) do C[k] = v end end

local reg = Z.registry()
local grid = Z.grid()
local bcs = StaticFindObject("/Script/Brickadia.Default__BCSLibrary")
local bh = StaticFindObject("/Script/Brickadia.Default__BrickHelpers")   -- for procedural brick-type generation
local regPath = reg:GetFullName():gsub("^%S+ ", "")
local hostAsset = StaticFindObject(C.hostBrick)
local hostBT = (hostAsset and hostAsset:IsValid()) and hostAsset.BrickType or nil

local summary = { written = 0, placeFail = 0, components = 0, ports = 0, probeErrors = 0, errors = {}, total = 0 }
local function err(m) if #summary.errors < 40 then summary.errors[#summary.errors + 1] = m end end

-- One object per component type. Older builds kept them as BRRegistry subobjects
-- (".../Plate.Plate:BRRegistry.Component_X"); since the BCS component rewrite they are loose
-- /Engine/Transient objects ("/Engine/Transient.BrickComponentType_Y"). Returns
-- { short, path, cls } for such an object, else nil.
local ctBase = StaticFindObject("/Script/Brickadia.BCSComponentTypeBase")
local ctoPath = {}   -- short name -> object path, filled by the standalone enumeration
local function registeredComponentType(o, fullName)
  local path = fullName:gsub("^%S+ ", "")
  if not (string.find(path, ":BRRegistry.", 1, true) or string.sub(path, 1, 18) == "/Engine/Transient.") then return nil end
  local short = path:gsub(".*[%.:]", "")
  if not (string.sub(short, 1, 10) == "Component_" or string.sub(short, 1, 18) == "BrickComponentType") then return nil end
  local ok, r = pcall(function()
    if ctBase and ctBase:IsValid() and not o:IsA(ctBase) then return nil end
    return { short = short, path = path, cls = o:GetClass():GetFullName() }
  end)
  return ok and r or nil
end

-- Readers for game data, each guarded: shipping data can be null.
local function txt(obj, field)
  local ok, v = pcall(function()
    local x = obj[field]
    if x == nil then return "" end
    if type(x) == "userdata" and x.ToString then return tostring(x:ToString()) end
    return tostring(x)
  end)
  return ok and v or ""
end
local function num(obj, field) local ok, v = pcall(function() return obj[field] end); return (ok and type(v) == "number") and v or 0 end
local function boolean(obj, field) local ok, v = pcall(function() return obj[field] end); return (ok and v) and true or false end
local function nameArray(obj, field)
  local res = {}
  pcall(function()
    local a = obj[field]
    local n = (a and a.GetArrayNum) and a:GetArrayNum() or 0
    for i = 1, n do
      local e = a[i]
      if type(e) == "userdata" and e.ToString then res[#res + 1] = tostring(e:ToString()) else res[#res + 1] = tostring(e) end
    end
  end)
  return res
end
local function halfSize(bt)
  local ok, v = pcall(function() return { X = bt.HalfSize.X, Y = bt.HalfSize.Y, Z = bt.HalfSize.Z } end)
  return ok and v or { X = 0, Y = 0, Z = 0 }
end

-- derive a human display name from a field name: drop hungarian bool prefix, split
-- camelCase, underscores -> spaces, keep a dotted sub-property suffix (".X") intact.
local function pretty(name)
  local base, suffix = name:match("^(.-)(%.%w+)$")
  base = base or name; suffix = suffix or ""
  base = base:gsub("^b(%u)", "%1")
  base = base:gsub("_", " ")
  base = base:gsub("(%l)(%u)", "%1 %2")
  base = base:gsub("(%d)(%u)", "%1 %2")
  return base .. suffix
end

-- Place a brick, bumping z for bricks too tall to sit at baseZ.
local function placeAt(bt)
  for _, dz in ipairs({ 0, 2, 4, 6, 8, 12, 18, 26, 40, 60, 90, 140, 220 }) do
    local h = Z.place(grid, bt, 0, 0, C.baseZ + dz, C.probeOrient, C.material, { 200, 200, 200 })
    if h and h ~= 0 then return h end
  end
  return 0
end

-- A handful of gates (CallableEntry_*, FunctionInput, MicrochipInput) refuse to
-- place on the global grid -- they only go on a microchip's plane. Placing a
-- microchip brick synchronously spawns a BrickGridMicrochipActor that owns its
-- own BrickGridComponent, so we place a host microchip and put the gate on that
-- actor's grid. Which plane accepts which gate isn't declared anywhere, so we
-- try each host kind until one takes the brick.
local MICROCHIP_HOSTS = {
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_ForEachArray.B_1x1_Microchip_ForEachArray",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_ForEachMap.B_1x1_Microchip_ForEachMap",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_CountFor.B_1x1_Microchip_CountFor",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_FunctionDefinition.B_1x1_Microchip_FunctionDefinition",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip.B_1x1_Microchip",
}

-- Name-keyed set of the microchip plane grids that exist right now. Matching on
-- the full name keeps this to string reads: touching a dynamic microchip actor's
-- struct properties (GetComponentByClass / TopLevelBrickGrid) hard-crashes the game.
local function microchipPlaneGrids()
  local set = {}
  for _, g in ipairs(FindAllOf("BrickGridComponent") or {}) do
    if g and g:IsValid() then
      local fn = g:GetFullName()
      if fn:find("MicrochipBrickGridDynamicActor", 1, true) then set[fn] = g end
    end
  end
  return set
end

-- Each gate belongs in one specific microchip kind. Trying hosts blindly leaves a
-- stray unwired microchip (and its plane actor) behind for every kind that didn't
-- take the brick, so derive the right host from the gate name and try it first.
local MICROCHIP_HOST_FOR = {
  B_1x1_Gate_CallableEntry_CountFor     = "B_1x1_Microchip_CountFor",
  B_1x1_Gate_CallableEntry_ForEachArray = "B_1x1_Microchip_ForEachArray",
  B_1x1_Gate_CallableEntry_ForEachMap   = "B_1x1_Microchip_ForEachMap",
  B_1x1_Gate_CallableEntry_Function     = "B_1x1_Microchip_FunctionDefinition",
  B_1x1_Gate_FunctionInput              = "B_1x1_Microchip_FunctionDefinition",
  B_1x1_Gate_MicrochipInput             = "B_1x1_Microchip",
}

-- Host paths to try, preferred kind first.
local function microchipHostOrder(assetName)
  local want = assetName and MICROCHIP_HOST_FOR[assetName]
  if not want then return MICROCHIP_HOSTS end
  local order, wantPath = {}, "/Game/Bricks/Categories/Wires/" .. want .. "." .. want
  order[1] = wantPath
  for _, p in ipairs(MICROCHIP_HOSTS) do
    if p ~= wantPath then order[#order + 1] = p end
  end
  return order
end

-- Place `bt` on a freshly-spawned microchip plane. Returns handle, planeGrid
-- (0, nil when no host kind accepts it).
local function placeOnMicrochipPlane(bt, assetName)
  for _, hostPath in ipairs(microchipHostOrder(assetName)) do
    local hostAsset = StaticFindObject(hostPath)
    local hostBt = (hostAsset and hostAsset:IsValid()) and hostAsset.BrickType or nil
    if hostBt and hostBt:IsValid() then
      local before = microchipPlaneGrids()
      local hostH = 0
      for _, dz in ipairs({ 0, 2, 4, 6, 8, 12, 18, 26, 40 }) do
        hostH = Z.place(grid, hostBt, 0, 0, C.baseZ + dz, C.probeOrient, C.material, { 200, 200, 200 })
        if hostH and hostH ~= 0 then break end
      end
      if hostH and hostH ~= 0 then
        for fn, pg in pairs(microchipPlaneGrids()) do
          if not before[fn] then
            for _, z in ipairs({ 2, 0, 4, 6, 8 }) do
              for _, xy in ipairs({ { 0, 0 }, { 10, 0 }, { 0, 10 }, { 10, 10 } }) do
                local h = Z.place(pg, bt, xy[1], xy[2], z, C.probeOrient, C.material, { 200, 200, 200 })
                if h and h ~= 0 then return h, pg end
              end
            end
          end
        end
      end
    end
  end
  return 0, nil
end

-- Returns wireInputPorts, wireOutputPorts as name-keyed objects:
--   { [portName] = { displayName = <derived>, tooltip = "", type = <FProperty class> } }
local function collectPorts(cto, h)
  local win, wout, seen, count = {}, {}, {}, 0
  -- name -> FProperty class for DataStruct fields that are NOT wire ports
  -- (probe returns 0). These back the component's config properties.
  local nowire = {}
  local probeFailed = false
  -- structType: for a StructProperty, the struct's name (BrickHandle, BCSComponentHandle,
  -- LinearColor, WireValue, ...) -- "StructProperty" alone can't tell a brick from a color.
  local function consider(name, ptype, structType)
    if seen[name] then return end
    seen[name] = true
    local d = Z.port(cto, h, name)
    -- negative = the probe itself failed (-4: component not on this brick, -1: dead handle).
    -- Not a port, but must not pass silently as "no ports".
    if d < 0 and not probeFailed then
      probeFailed = true
      summary.probeErrors = summary.probeErrors + 1
      err("portProbe " .. cto:GetFName():ToString() .. " = " .. tostring(d))
    end
    if d <= 0 then nowire[name] = ptype; return end
    local rec = { displayName = pretty(name), tooltip = "", type = ptype, structType = structType }
    if d == 1 then win[name] = rec else wout[name] = rec end
    count = count + 1
  end
  local function walk(s, depth)
    if not (s and s:IsValid()) or depth > 8 then return end
    s:ForEachProperty(function(p)
      local nm = p:GetFName():ToString()
      local pcls = p:GetClass():GetFName():ToString()
      local sub = nil
      if pcls == "StructProperty" then sub = p:GetStruct() end   -- safe: only on StructProperty
      consider(nm, pcls, (sub and sub:IsValid()) and sub:GetFName():ToString() or nil)
      if pcls == "StructProperty" then
        if sub and sub:IsValid() then
          sub:ForEachProperty(function(q) consider(nm .. "." .. q:GetFName():ToString(), q:GetClass():GetFName():ToString()) end)
        end
      end
    end)
    local ok, sup = pcall(function() return s:GetSuperStruct() end)
    if ok and sup and sup:IsValid() then walk(sup, depth + 1) end
  end
  if cto.DataStruct and cto.DataStruct:IsValid() then walk(cto.DataStruct, 0) end
  return win, wout, count, nowire
end

-- build the component record for a (placed) brick handle + component type object
local function componentRecord(cto, h)
  local win, wout, n, nowire = collectPorts(cto, h)
  summary.components = summary.components + 1
  summary.ports = summary.ports + n
  -- Config properties: the NoWireProperties (settings-menu fields, not wire
  -- pins) enriched with the FProperty class discovered during the walk.
  local nwNames = nameArray(cto, "NoWireProperties")
  local config = {}
  for _, name in ipairs(nwNames) do
    config[name] = { displayName = pretty(name), type = nowire[name] or "" }
  end
  return {
    componentType = cto:GetFName():ToString(),
    componentDisplayName = txt(cto, "DisplayName"),
    componentCategory = txt(cto, "Category"),
    componentDescription = txt(cto, "Description"),
    componentSearchTags = txt(cto, "SearchTags"),
    bCountsTowardsQuota = boolean(cto, "bCountsTowardsQuota"),
    bPlayerSpawnable = boolean(cto, "bPlayerSpawnable"),
    currentVersion = num(cto, "CurrentVersion"),
    noWireProperties = nwNames,
    configProperties = config,
    wireInputPorts = win,
    wireOutputPorts = wout,
    physicalPorts = {},   -- geometry lives on the placed instance; not captured
  }
end

local function dumpBrick(path)
  local asset = StaticFindObject(path)
  if not (asset and asset:IsValid()) then err("noAsset " .. path); return nil end
  local bt = asset.BrickType
  if not (bt and bt:IsValid()) then err("noBrickType " .. path); return nil end
  local assetName = path:match("([^/.]+)%.[^/.]+$") or path
  local tab = txt(bt, "Tab")
  for _, bad in ipairs(C.skipTabs) do
    if string.find(tab, bad, 1, true) then summary.skipped = (summary.skipped or 0) + 1; return nil end
  end
  local rec = {
    tab = tab,
    halfSize = halfSize(bt),
    assetName = assetName,
    brickSummary = txt(bt, "Summary"),
    brickCategory = txt(bt, "Category"),
    brickDisplayName = txt(bt, "DisplayName"),
    components = {},
  }
  local h = placeAt(bt)
  local attach = false
  local planeGrid = nil
  if h == 0 then
    -- The brick itself won't place (e.g. the grid-level WholeGrid* gates). Fall back to
    -- attaching its default component(s) to a generic host brick so their ports are still
    -- captured instead of lost. Still counted as a placement failure.
    summary.placeFail = summary.placeFail + 1; err("placeFail " .. path)
    rec.placeFailed = true
    -- First try a microchip plane: the CallableEntry_*/FunctionInput/MicrochipInput
    -- gates place there for real, so their ports get classified by the game instead
    -- of coming back empty from an attach that the registry won't validate.
    local ph, pg = placeOnMicrochipPlane(bt, assetName)
    if ph ~= 0 then
      h = ph; planeGrid = pg
      rec.placedOnMicrochipPlane = true
      summary.microchipPlane = (summary.microchipPlane or 0) + 1
    else
      if not (hostBT and hostBT:IsValid()) then return rec end
      h = placeAt(hostBT)
      if h == 0 then return rec end
      attach = true
      summary.brickless = (summary.brickless or 0) + 1
    end
  end
  local entries = asset.DefaultComponentEntries
  local nComp = (entries and entries.GetArrayNum) and entries:GetArrayNum() or 0
  for ci = 1, nComp do
    local ok = pcall(function()
      local cclass = entries[ci].ComponentType
      if not (cclass and cclass:IsValid()) then return end
      local cto = bcs:GetComponentType(planeGrid or grid, cclass)
      if cto and cto:IsValid() then
        if attach then pcall(Z.attach, h, cto) end
        rec.components[#rec.components + 1] = componentRecord(cto, h)
      end
    end)
    if not ok then err("comp " .. path .. "#" .. ci) end
  end
  if planeGrid then pcall(function() planeGrid:ClearAndDeleteBricks() end) end
  pcall(function() grid:ClearAndDeleteBricks() end)
  return rec
end

local function dumpStandalone(short)
  local cto = StaticFindObject(ctoPath[short] or (regPath .. "." .. short))
  if not (cto and cto:IsValid()) then err("noComp " .. short); return nil end
  if not (hostBT and hostBT:IsValid()) then err("noHostBrick"); return nil end
  local rec = {
    tab = "Standalone",
    halfSize = halfSize(hostBT),
    assetName = short,
    brickSummary = txt(cto, "Description"),
    brickCategory = txt(cto, "Category"),
    brickDisplayName = txt(cto, "DisplayName"),
    standalone = true,
    components = {},
  }
  local h = placeAt(hostBT)
  if h == 0 then summary.placeFail = summary.placeFail + 1; err("placeFail " .. short); return rec end
  pcall(Z.attach, h, cto)
  rec.components[1] = componentRecord(cto, h)
  pcall(function() grid:ClearAndDeleteBricks() end)
  return rec
end

-- ProceduralBrick assets have no fixed BrickType (asset.BrickType is a non-placeable
-- template). BrickHelpers::GetBrickTypeFromBrickAsset(asset, size) generates a placeable
-- BrickType for a given IntVector size; try a ladder of sizes until one generates AND places.
-- The recorded size is irrelevant downstream (procedural sizes live per-instance in saves),
-- so any valid size is fine -- we only need a placement to probe the default components.
local PROC_SIZES = {
  { X = 10, Y = 10, Z = 6 }, { X = 10, Y = 10, Z = 10 }, { X = 10, Y = 20, Z = 1 },
  { X = 10, Y = 5, Z = 10 }, { X = 20, Y = 20, Z = 6 }, { X = 10, Y = 10, Z = 2 },
  { X = 10, Y = 10, Z = 4 }, { X = 5, Y = 5, Z = 6 }, { X = 2, Y = 2, Z = 2 }, { X = 1, Y = 1, Z = 1 },
  -- composed bricks (only reached if the generic sizes above all fail): their generators
  -- accept a fixed Y=5 and a type-specific Z (slider joints Z=1, baguette Z=3, picket fence Z=12).
  { X = 10, Y = 5, Z = 1 }, { X = 20, Y = 5, Z = 3 }, { X = 20, Y = 5, Z = 12 },
}
local function placeProcedural(asset)
  if not (bh and bh:IsValid()) then return 0, nil end
  for _, sz in ipairs(PROC_SIZES) do
    local ok, bt = pcall(function() return bh:GetBrickTypeFromBrickAsset(asset, sz) end)
    if ok and bt and bt:IsValid() then
      local h = placeAt(bt)
      if h ~= 0 then return h, sz end
    end
  end
  return 0, nil
end
-- ProceduralGateBrick (a ProceduralBrick subclass, /Wires/GatesGenerated/PB_Gate_*) is a
-- gate whose brick comes in a fixed list of size Variants, each with its own physical
-- WirePorts (a longer brick exposes more numbered data ports; the rest of the logical ports
-- stay omniport-only). The procedural size that selects a variant is exactly that
-- variant's BrickType.HalfSize -- GetBrickTypeFromBrickAsset rejects any other size.
local function isGateBrickName(fullName) return string.sub(fullName, 1, 20) == "ProceduralGateBrick " end
local function round3(x)
  local r = math.floor(x * 1000 + 0.5) / 1000
  return r == 0 and 0 or r   -- fold -0 and float noise (5e-07) to a clean 0
end
local function vec3(v) return { X = round3(v.X), Y = round3(v.Y), Z = round3(v.Z) } end
local function gateVariants(asset)
  local out = {}
  local v = asset.Variants
  for i = 1, v:GetArrayNum() do
    local var = v[i]
    local rec = { index = i - 1, halfSize = halfSize(var.BrickType), physicalPorts = {} }
    local es = var.DefaultComponentEntries
    for j = 1, es:GetArrayNum() do
      local wp = es[j].WirePorts
      for k = 1, wp:GetArrayNum() do
        local p = wp[k]
        rec.physicalPorts[#rec.physicalPorts + 1] = { name = p.Name:ToString(), position = vec3(p.Position), normal = vec3(p.Normal) }
      end
    end
    out[#out + 1] = rec
  end
  return out
end
local function placeGateVariant(asset, hs)
  if not (bh and bh:IsValid()) then return 0 end
  local ok, bt = pcall(function() return bh:GetBrickTypeFromBrickAsset(asset, { X = hs.X, Y = hs.Y, Z = hs.Z }) end)
  if not (ok and bt and bt:IsValid()) then return 0 end
  return placeAt(bt)
end

local function dumpProcedural(path, isGate)
  local asset = StaticFindObject(path)
  if not (asset and asset:IsValid()) then err("noAsset " .. path); return nil end
  local assetName = path:match("([^/.]+)%.[^/.]+$") or path
  local dn = ""; pcall(function() dn = asset.DisplayName:ToString() end)
  local rec = {
    tab = "Procedural",
    halfSize = { X = 0, Y = 0, Z = 0 },   -- placeholder; procedural size is per-instance (saves), not asset-defined
    assetName = assetName,
    brickSummary = txt(asset, "Description"),
    brickCategory = txt(asset, "Category"),
    brickDisplayName = dn,
    procedural = true,
    components = {},
  }
  local h, sz
  if isGate then
    -- Probe on the LARGEST variant so every physical port exists on the placed instance;
    -- record the smallest (the catalog's default size) as the brick's halfSize.
    local vars = gateVariants(asset)
    if #vars == 0 then summary.placeFail = summary.placeFail + 1; err("noVariants " .. path); return rec end
    rec.tab = txt(asset, "Tab")
    rec.brickSummary = txt(asset, "Summary")
    rec.gateVariants = vars
    sz = vars[1].halfSize
    h = placeGateVariant(asset, vars[#vars].halfSize)
    summary.gateBricks = (summary.gateBricks or 0) + 1
  else
    h, sz = placeProcedural(asset)
  end
  if h == 0 then summary.placeFail = summary.placeFail + 1; err("placeFail " .. path); return rec end
  rec.halfSize = { X = sz.X, Y = sz.Y, Z = sz.Z }   -- the size actually placed (informational only)
  local entries = asset.DefaultComponentEntries
  local nComp = (entries and entries.GetArrayNum) and entries:GetArrayNum() or 0
  for ci = 1, nComp do
    local ok = pcall(function()
      local cclass = entries[ci].ComponentType
      if not (cclass and cclass:IsValid()) then return end
      local cto = bcs:GetComponentType(grid, cclass)
      if cto and cto:IsValid() then rec.components[#rec.components + 1] = componentRecord(cto, h) end
    end)
    if not ok then err("comp " .. path .. "#" .. ci) end
  end
  pcall(function() grid:ClearAndDeleteBricks() end)
  return rec
end

-- The item list is the same on every chunk, and enumerating every UObject for it costs
-- about 300 ms, so it is built once per game process (Z.memo).
local function buildItems()
  local items = {}
  local gateItem = {}   -- procedural pass: paths that are ProceduralGateBricks
  if C.procedural then
    -- every ProceduralBrick asset under /Game/Bricks/Procedural/ (aero surfaces, ramps,
    -- wedges, slider joints, zone projector, composed specials).
    -- Plus every ProceduralGateBrick (size-variant gates under /Wires/GatesGenerated/).
    ForEachUObject(function(o)
      if o and o:IsValid() then
        local nm = o:GetFullName()
        local path
        if string.sub(nm, 1, 16) == "ProceduralBrick " then path = string.sub(nm, 17)
        elseif isGateBrickName(nm) then path = string.sub(nm, 21); gateItem[path] = true end
        if path and not string.find(path, "Default__") then items[#items + 1] = path end
      end
    end)
  elseif C.standalone then
    -- components whose class is NOT the default component of any catalog brick.
    -- NOTE: kept BasicBrick-only (procedural mode is purely additive) so that components of
    -- procedural bricks that can't be placed standalone (slider joints, baguette, picket fence)
    -- are still captured here and never lost. ProceduralGateBricks always place at a variant
    -- size, so the procedural pass owns their components -- count them as used here.
    local used, reglist = {}, {}
    ForEachUObject(function(o)
      if o and o:IsValid() then
        local nm = o:GetFullName()
        if string.sub(nm, 1, 11) == "BasicBrick " or isGateBrickName(nm) then
          pcall(function()
            local e = o.DefaultComponentEntries
            local n = (e and e.GetArrayNum) and e:GetArrayNum() or 0
            for i = 1, n do local c = e[i].ComponentType; if c and c:IsValid() then used[c:GetFullName()] = true end end
          end)
        else
          local r = registeredComponentType(o, nm)
          if r then reglist[#reglist + 1] = r end
        end
      end
    end)
    local seen = {}
    for _, r in ipairs(reglist) do
      if not used[r.cls] and not seen[r.short] then
        seen[r.short] = true; ctoPath[r.short] = r.path; items[#items + 1] = r.short
      end
    end
  else
    local prefixes = {}
    for _, s in ipairs(C.sections) do prefixes[#prefixes + 1] = "/Game/Bricks/Categories/" .. s .. "/" end
    local wiresRoot = "/Game/Bricks/Categories/Wires/"
    ForEachUObject(function(o)
      if o and o:IsValid() then
        local nm = o:GetFullName()
        if string.sub(nm, 1, 11) == "BasicBrick " then
          local path = string.sub(nm, 12)
          local matched = false
          for _, pre in ipairs(prefixes) do if string.sub(path, 1, #pre) == pre then matched = true; break end end
          if not matched and C.includeWiresRoot and string.sub(path, 1, #wiresRoot) == wiresRoot then
            if not string.find(string.sub(path, #wiresRoot + 1), "/", 1, true) then matched = true end
          end
          if matched then items[#items + 1] = path end
        end
      end
    end)
  end
  table.sort(items)
  return { items = items, gateItem = gateItem, ctoPath = ctoPath }
end
local list = Z.memo(table.concat({ "dump", tostring(C.procedural), tostring(C.standalone), table.concat(C.sections, ","), tostring(C.includeWiresRoot) }, "|"), buildItems)
local items, gateItem = list.items, list.gateItem
for k, v in pairs(list.ctoPath) do ctoPath[k] = v end
summary.total = #items

if C.clearFirst then pcall(function() grid:ClearAndDeleteBricks() end) end
local f, ferr = io.open(C.outFile, C.clearFirst and "w" or "a")
if not f then return { error = "cannot open outFile: " .. tostring(ferr), outFile = C.outFile } end

local first = C.offset + 1
local last = math.min(#items, C.offset + C.limit)
for i = first, last do
  local ok, rec = pcall(function()
    if C.procedural then return dumpProcedural(items[i], gateItem[items[i]])
    elseif C.standalone then return dumpStandalone(items[i])
    else return dumpBrick(items[i]) end
  end)
  if ok and rec then
    f:write(json.encode(rec)); f:write("\n")
    summary.written = summary.written + 1
  elseif not ok then
    err("item#" .. i .. " " .. tostring(items[i]) .. " :: " .. tostring(rec))
  end  -- ok && nil == intentional skip (DONOTUSE) or already-logged error
end
f:close()
summary.processedRange = { first = first, last = last }
summary.outFile = C.outFile
return summary
