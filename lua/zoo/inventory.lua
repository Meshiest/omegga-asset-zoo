local Z = require("zoo")
-- The zoo's component phases: every brick with components, placed in a grid with a
-- wired rerouter on each of its ports, discovered at runtime (nothing about specific
-- gates or components is hardcoded). For every brick it:
--   1. places the brick on a grid (cells `studsApart` studs apart),
--   2. reads its DefaultComponentEntries -> component type(s),
--   3. discovers ALL wire ports: the component DataStruct + its super-structs + one-level
--      struct sub-property expansion (e.g. ExitOffset.X) -- NOT the physical WirePorts
--      array, which omits non-physical logical ports,
--   4. classifies each port input/output via the live game (Z.port),
--   5. places a rerouter per port (inputs on the x- side, outputs on the x+ side),
--   6. wires each port to its rerouter (output->rerouter.RER_Input,
--      rerouter.RER_Output->input),
-- then optionally places a single microchip brick.
--
-- Game access goes through zoo.lua (omegga-ue4ss's BR): Z.place / Z.place_up, Z.port (port
-- direction), Z.attach, Z.wire_many, and Z.place_and_wire, which places a gate's rerouters and
-- wires them in one transaction.
--
-- The plugin runs it per chunk (`/zoo build components`, `standalone`) with INV set to
-- { offset, limit, ... } over the defaults below; a mod callback must finish within the
-- bridge's 5 s watchdog, so a chunk is 24 bricks. Each call returns a summary (placed,
-- ports, rerouters, wiresOk, wiresFail, errors, total) and processedRange.

local DEFAULTS = {
  -- catalog folders under /Game/Bricks/Categories/ to enumerate.
  -- Physics / Mechanics / Wires(-Pure) / Wires/Exec(-Exec) per the in-game catalog.
  -- Specific folders (a bare "Wires" prefix would also swallow the reroute-node and
  -- microchip infra assets under /Wires/, so we list the gate subfolders explicitly).
  sections = {
    "Physics", "Mechanics", "LogicGates",
    "Wires/GatesGenerated", "Wires/Exec",
  },
  offset      = 0,      -- skip first N bricks (stable sorted order) -- for chunking
  limit       = 24,     -- bricks per call
  clearFirst  = false,  -- ClearAndDeleteBricks() before placing
  baseX       = -600,
  baseY       = -600,
  baseZ       = 2,      -- baseplate top is at z=0; a 4-unit-tall brick rests at z=2.
                        -- placeAt() bumps up in small steps for taller bricks.
  cols        = 16,     -- cells per row
  studsApart  = 8,      -- cell spacing in studs
  doRerouters = true,
  doMicrochip = false,  -- place one microchip brick (only worth doing on the last chunk)
  -- Include the wire-infra bricks that sit DIRECTLY under /Game/Bricks/Categories/Wires/
  -- (the rerouter, the microchip, and the microchip input/output "routers"). The section
  -- prefixes below all have a subfolder, so these depth-1 bricks would otherwise be skipped.
  includeWiresRoot = true,
  material    = 3,      -- index into BRRegistry.MaterialCollections: 3 is Plastic
  -- EBrickOrientation: 16 = Z_Positive_0 (upright, ports on local -Y/+Y). 19 = Z_Positive_270
  -- yaws those port faces onto X: Input/RER_Input -> -X, Output/RER_Output -> +X. Verified
  -- in-game that gates AND rerouters both want 19 (ports align, wires straight).
  gateOrient     = 19,
  rerouterOrient = 19,
  rerouterZStep  = 12,  -- vertical (Z) spacing between stacked rerouters on a side
  -- Standalone phase: when true, instead of catalog bricks, place each component that has
  -- NO catalog brick (Light, TextDisplay, ItemSpawn, Interact, Switch, ...) onto a generic
  -- host brick via AttachComponent, then wire its ports the same way (its own phase, at baseY 800).
  standalone  = false,
  hostBrick   = "/Game/Bricks/Categories/Rounds/Round/B_1x1F_Round.B_1x1F_Round",
  -- Diagnostic: if set, append "START i path" before processing each brick and "DONE i path"
  -- after. A brick logged START but never DONE is the one that crashed the game (used to
  -- hunt a wiring-crash culprit). Each line is flushed to disk so it survives a hard crash.
  progressFile = nil,
  skipPaths   = nil,   -- optional set { [assetPath]=true } of bricks to SKIP (e.g. a crasher)
}

-- merge INV overrides over defaults
local C = {}
for k, v in pairs(DEFAULTS) do C[k] = v end
if type(INV) == "table" then for k, v in pairs(INV) do C[k] = v end end

local STUD = 10
local CELL = C.studsApart * STUD
local REROUTE_ASSET = "/Game/Bricks/Categories/Wires/B_1x1_Reroute_Node.B_1x1_Reroute_Node"
local MICROCHIP_ASSET = "/Game/Bricks/Categories/Wires/B_1x1_Microchip.B_1x1_Microchip"

local reg = Z.registry()
local grid = Z.grid()
local bcs = StaticFindObject("/Script/Brickadia.Default__BCSLibrary")

local summary = {
  placed = 0, skipped = 0, placeFail = 0, components = 0, ports = 0, probeErrors = 0,
  rerouters = 0, wiresOk = 0, wiresFail = 0, total = 0, errors = {},
}
local function err(msg) if #summary.errors < 40 then summary.errors[#summary.errors+1] = msg end end

-- One object per component type. Older builds kept them as BRRegistry subobjects
-- (".../Plate.Plate:BRRegistry.Component_X"); since the BCS component rewrite they are loose
-- /Engine/Transient objects ("/Engine/Transient.BrickComponentType_Y"). Returns
-- { short, path, cls } for such an object, else nil.
local ctBase = StaticFindObject("/Script/Brickadia.BCSComponentTypeBase")
local ctoPath = {}   -- short name -> object path, filled by buildStandaloneList
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

-- resolve the rerouter brick type + component type once
local rerouteBT  = StaticFindObject(REROUTE_ASSET .. ":BrickType")
local rerouteAsset = StaticFindObject(REROUTE_ASSET)
local rerouteCT = (rerouteAsset and rerouteAsset:IsValid())
  and bcs:GetComponentType(grid, rerouteAsset.DefaultComponentEntries[1].ComponentType) or nil

-- for the standalone phase: the registry's object path + a generic host brick type
local regPath = reg:GetFullName():gsub("^%S+ ", "")   -- e.g. ".../Plate.Plate:BRRegistry"
local hostAsset = StaticFindObject(C.hostBrick)
local hostBT = (hostAsset and hostAsset:IsValid()) and hostAsset.BrickType or nil

if C.clearFirst then pcall(function() grid:ClearAndDeleteBricks() end) end

-- Try z, bumping up in small steps until the brick fits above the baseplate (taller
-- bricks just float a little). Returns handle, usedZ (handle 0 on failure).
local function placeAtGrid(g, bt, x, y, z, orient)
  for _, dz in ipairs({0, 2, 4, 6, 8, 12, 18, 26, 40, 60, 90, 140, 220}) do
    local h = Z.place(g, bt, x, y, z + dz, orient or 16, C.material, { 200, 200, 200 })
    if h and h ~= 0 then return h, z + dz end
  end
  return 0, z
end

local function placeAt(bt, x, y, z, orient) return placeAtGrid(grid, bt, x, y, z, orient) end

-- The CallableEntry_*/FunctionInput/MicrochipInput gates only place on a microchip's
-- plane. Placing a microchip brick synchronously spawns a BrickGridMicrochipActor
-- owning its own BrickGridComponent; we host one at the cell and put the gate there.
-- Which plane kind accepts which gate isn't declared, so try each until one takes it.
local MICROCHIP_HOSTS = {
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_ForEachArray.B_1x1_Microchip_ForEachArray",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_ForEachMap.B_1x1_Microchip_ForEachMap",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_CountFor.B_1x1_Microchip_CountFor",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip_FunctionDefinition.B_1x1_Microchip_FunctionDefinition",
  "/Game/Bricks/Categories/Wires/B_1x1_Microchip.B_1x1_Microchip",
}

-- Match on full name only: reading a dynamic microchip actor's struct properties
-- (GetComponentByClass / TopLevelBrickGrid) hard-crashes the game.
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

-- Host a microchip at (cx, cy) and place `bt` on its plane.
-- Returns gateHandle, planeGrid, gateZ, hostHandle, hostAsset, hostZ
-- (0, nil, z, 0, nil, z when no host kind accepts it).
local function placeOnMicrochipPlane(bt, cx, cy, z, orient, assetName)
  for _, hostPath in ipairs(microchipHostOrder(assetName)) do
    local hostAsset = StaticFindObject(hostPath)
    local hostBt = (hostAsset and hostAsset:IsValid()) and hostAsset.BrickType or nil
    if hostBt and hostBt:IsValid() then
      local before = microchipPlaneGrids()
      local hostH, hostZ = placeAtGrid(grid, hostBt, cx, cy, z, orient)
      if hostH and hostH ~= 0 then
        for fn, pg in pairs(microchipPlaneGrids()) do
          if not before[fn] then
            for _, pz in ipairs({2, 0, 4, 6, 8}) do
              local h = Z.place(pg, bt, 0, 0, pz, orient or 16, C.material, { 200, 200, 200 })
              if h and h ~= 0 then return h, pg, pz, hostH, hostAsset, hostZ end
            end
          end
        end
      end
    end
  end
  return 0, nil, z, 0, nil, z
end

-- A few inputs are meaningless fed from a rerouter: FunctionCall's Definition only
-- does anything when it points at an actual FunctionDefinition microchip. For those,
-- place the real upstream brick and wire it in instead of a rerouter.
local FUNCTION_CALL_SOURCES = {
  Definition = {
    asset = "/Game/Bricks/Categories/Wires/B_1x1_Microchip_FunctionDefinition.B_1x1_Microchip_FunctionDefinition",
    port  = "Definition",
  },
}
local SPECIAL_SOURCES = {
  BrickComponentType_FunctionCall           = FUNCTION_CALL_SOURCES,
  BrickComponentType_WireGraph_FunctionCall = FUNCTION_CALL_SOURCES,   -- name before the BCS component rewrite
}

-- `g` is the grid the component lives on (the global grid, or a microchip plane for
-- the plane-only gates); rerouters must land on the same grid for the wire to connect.
local function wirePorts(cto, h, cx, cy, z, ins, outs, g)
  local ctoName = cto:GetFName():ToString()
  local specials = SPECIAL_SOURCES[ctoName]
  -- Rerouters on a side are stacked VERTICALLY (Z), not spread along Y, so each cell
  -- stays compact in the XY plane. Inputs column on x-, outputs column on x+.
  local ZS = C.rerouterZStep
  g = g or grid
  if g ~= grid then cx, cy, z = 0, 0, 2 end   -- plane grids are small; keep it local to the origin
  local batch = {}
  for j, nm in ipairs(ins) do
    local spec = specials and specials[nm]
    if spec then
      -- Real upstream brick, placed clear of this cell's rerouter column (cx - 3*STUD).
      local sa = StaticFindObject(spec.asset)
      local sh = (sa and sa:IsValid()) and placeAtGrid(g, sa.BrickType, cx - 10 * STUD, cy, z, C.gateOrient) or 0
      if sh ~= 0 then
        local se = sa.DefaultComponentEntries
        local sn = (se and se.GetArrayNum) and se:GetArrayNum() or 0
        for si = 1, sn do
          pcall(function()
            local scls = se[si].ComponentType
            if not (scls and scls:IsValid()) then return end
            local scto = bcs:GetComponentType(g, scls)
            if not (scto and scto:IsValid()) then return end
            local w = (Z.wire_many({ { scto, sh, spec.port, cto, h, nm } }) > 0 and 0 or -3)
            if w == 0 then summary.wiresOk = summary.wiresOk + 1
            else summary.wiresFail = summary.wiresFail + 1; err("wireSrc "..nm.."="..tostring(w)) end
            -- and give the source its own rerouters so it isn't left bare
            local sin, sout = collectPorts(scto, sh)
            wirePorts(scto, sh, cx - 10 * STUD, cy, z, sin, sout, g)
          end)
        end
        summary.specialSources = (summary.specialSources or 0) + 1
      else
        summary.wiresFail = summary.wiresFail + 1; err("srcPlace "..nm)
      end
      goto continue_in
    end
    batch[#batch + 1] = {
      g, rerouteBT, cx - 3 * STUD, cy, z + (j - 1) * ZS, C.rerouterOrient, material = C.material,
      wire = function(id) return { src = id, output = Z.ref(rerouteCT, "RER_Output", true), dst = Z.id(h), input = Z.ref(cto, nm, false) } end,
      alone = function(rh) return Z.wire_many({ { rerouteCT, rh, "RER_Output", cto, h, nm } }), "wireIn " .. nm end,
    }
    ::continue_in::
  end
  for j, nm in ipairs(outs) do
    batch[#batch + 1] = {
      g, rerouteBT, cx + 3 * STUD, cy, z + (j - 1) * ZS, C.rerouterOrient, material = C.material,
      wire = function(id) return { src = Z.id(h), output = Z.ref(cto, nm, true), dst = id, input = Z.ref(rerouteCT, "RER_Input", false) } end,
      alone = function(rh) return Z.wire_many({ { cto, h, nm, rerouteCT, rh, "RER_Input" } }), "wireOut " .. nm end,
    }
  end
  -- every rerouter at its first-choice spot and its wire in one transaction; one that
  -- collided (or sits on a microchip plane, which a transaction can't name) is placed up the
  -- z ladder and wired on its own
  local placed, connected, handles = Z.place_and_wire(batch)
  summary.rerouters = summary.rerouters + placed
  summary.wiresOk = summary.wiresOk + connected
  if connected < placed then summary.wiresFail = summary.wiresFail + placed - connected; err("wires " .. ctoName .. " " .. connected .. "/" .. placed) end
  for i, b in ipairs(batch) do
    if handles[i] == 0 then
      local rh = placeAtGrid(b[1], b[2], b[3], b[4], b[5], b[6])
      if rh ~= 0 then
        summary.rerouters = summary.rerouters + 1
        local ok, what = b.alone(rh)
        if ok > 0 then summary.wiresOk = summary.wiresOk + 1 else summary.wiresFail = summary.wiresFail + 1; err(what) end
      end
    end
  end
end

-- The authoritative source is the component's DataStruct, walked up its super-structs
-- (inherited ports, e.g. MathClamp's Input/Output live on a base struct). Struct fields
-- (e.g. FVector ExitOffset) are also expanded one level into sub-property ports
-- ("ExitOffset.X"). Z.port validates each candidate against the live instance and
-- classifies it (so non-wire fields and bad sub-props are filtered out automatically).
-- NOTE: the brick's physical WirePorts array is a SUBSET (only ports with a physical
-- position on the brick) and misses non-physical logical ports -- do not rely on it.
local function collectPorts(cto, h)
  local ins, outs, seen = {}, {}, {}
  local probeFailed = false
  local function consider(name)
    if seen[name] then return end
    seen[name] = true
    local d = Z.port(cto, h, name)  -- bit0=input, bit1=output; <0 = probe failed
    if d < 0 and not probeFailed then
      probeFailed = true
      summary.probeErrors = summary.probeErrors + 1
      err("portProbe " .. cto:GetFName():ToString() .. " = " .. tostring(d))
    end
    if d == 1 then ins[#ins+1] = name
    elseif d == 2 or d == 3 then outs[#outs+1] = name end
  end
  local function walk(s, depth)
    if not (s and s:IsValid()) or depth > 8 then return end
    s:ForEachProperty(function(p)
      local nm = p:GetFName():ToString()
      consider(nm)
      if p:GetClass():GetFName():ToString() == "StructProperty" then  -- expand sub-properties
        local sub = p:GetStruct()                                     -- safe: only on StructProperty
        if sub and sub:IsValid() then
          sub:ForEachProperty(function(q) consider(nm .. "." .. q:GetFName():ToString()) end)
        end
      end
    end)
    local sup = s:GetSuperStruct()
    if sup and sup:IsValid() then walk(sup, depth + 1) end
  end
  if cto.DataStruct and cto.DataStruct:IsValid() then walk(cto.DataStruct, 0) end
  return ins, outs
end

-- A ProceduralGateBrick (/Wires/GatesGenerated/PB_Gate_*) has no BrickType of its own; it
-- comes in size Variants, each exposing a different number of physical ports. Items for
-- them are "<path>#<variant index>" and each variant is placed in its own cell at exactly
-- its HalfSize -- the only procedural size GetBrickTypeFromBrickAsset accepts for it.
local brickHelpers = StaticFindObject("/Script/Brickadia.Default__BrickHelpers")
local function gateVariantBrickType(asset, vi)
  local var = asset.Variants[vi + 1]
  local hs = var.BrickType.HalfSize
  return brickHelpers:GetBrickTypeFromBrickAsset(asset, { X = hs.X, Y = hs.Y, Z = hs.Z })
end

local function processBrick(item, cx, cy)
  local path, variant = item:match("^(.-)#(%d+)$")
  path = path or item
  local asset = StaticFindObject(path)
  if not (asset and asset:IsValid()) then summary.skipped = summary.skipped + 1; return end
  local bt
  if variant then
    local ok, vbt = pcall(gateVariantBrickType, asset, tonumber(variant))
    bt = ok and vbt or nil
    summary.gateVariants = (summary.gateVariants or 0) + 1
  else
    bt = asset.BrickType
  end
  if not (bt and bt:IsValid()) then summary.skipped = summary.skipped + 1; err("noBrickType "..item); return end

  local h, z = placeAt(bt, cx, cy, C.baseZ, C.gateOrient)
  local attach = false
  local planeGrid = nil
  local hostMcH, hostMcAsset, hostMcZ = 0, nil, C.baseZ
  if h == 0 then
    summary.placeFail = summary.placeFail + 1; err("place "..path)
    -- First try a microchip plane -- the CallableEntry_*/FunctionInput/MicrochipInput
    -- gates place there for real, so they land in the zoo as genuine bricks with
    -- game-classified ports rather than as an attach the registry won't validate.
    local assetName = path:match("([^/.]+)%.[^/.]+$")
    local ph, pg, pz, hh, ha, hz = placeOnMicrochipPlane(bt, cx, cy, C.baseZ, C.gateOrient, assetName)
    if ph ~= 0 then
      h, planeGrid, z = ph, pg, pz
      hostMcH, hostMcAsset, hostMcZ = hh, ha, hz
      summary.microchipPlane = (summary.microchipPlane or 0) + 1
    else
      -- Brick won't place anywhere (grid-level WholeGrid* gates); fall back to a host
      -- brick + attach so the component still lands in the zoo instead of being lost.
      -- Still counted in placeFail, and separately as brickless.
      if not (hostBT and hostBT:IsValid()) then return end
      h, z = placeAt(hostBT, cx, cy, C.baseZ, C.gateOrient)
      if h == 0 then return end
      attach = true
      summary.brickless = (summary.brickless or 0) + 1
    end
  else
    summary.placed = summary.placed + 1
  end

  local entries = asset.DefaultComponentEntries
  local nComp = (entries and entries.GetArrayNum) and entries:GetArrayNum() or 0
  for ci = 1, nComp do
    local ok = pcall(function()
      local entry = entries[ci]
      local cclass = entry.ComponentType
      if not (cclass and cclass:IsValid()) then return end
      local cto = bcs:GetComponentType(planeGrid or grid, cclass)
      if not (cto and cto:IsValid()) then return end
      if attach then pcall(Z.attach, h, cto) end
      local ins, outs = collectPorts(cto, h)
      summary.components = summary.components + 1
      summary.ports = summary.ports + #ins + #outs
      if C.doRerouters then wirePorts(cto, h, cx, cy, z, ins, outs, planeGrid) end
    end)
    if not ok then err("comp "..path.."#"..ci) end
  end

  -- The microchip hosting a plane-placed gate is a real brick sitting in the world, so
  -- wire its own ports too -- otherwise the zoo shows a bare, rerouter-less microchip
  -- next to every plane gate. Not counted in components/ports: it's scaffolding, and the
  -- same component type is already counted by its own catalog entry.
  if planeGrid and hostMcAsset and hostMcH ~= 0 and C.doRerouters then
    local he = hostMcAsset.DefaultComponentEntries
    local hn = (he and he.GetArrayNum) and he:GetArrayNum() or 0
    for ci = 1, hn do
      local ok = pcall(function()
        local cclass = he[ci].ComponentType
        if not (cclass and cclass:IsValid()) then return end
        local hcto = bcs:GetComponentType(grid, cclass)
        if not (hcto and hcto:IsValid()) then return end
        local ins, outs = collectPorts(hcto, hostMcH)
        wirePorts(hcto, hostMcH, cx, cy, hostMcZ, ins, outs, nil)
      end)
      if not ok then err("hostComp "..path.."#"..ci) end
    end
  end
end

-- Components whose class is NOT the default component of any catalog brick (Light,
-- TextDisplay, ItemSpawn, Interact, Switch, sliders, ...). Discovered dynamically.
local function buildStandaloneList()
  local used, reglist = {}, {}
  ForEachUObject(function(o)
    if o and o:IsValid() then
      local nm = o:GetFullName()
      -- ProceduralGateBricks are placed (per variant) by the catalog phase -- not standalone.
      if string.sub(nm,1,11) == "BasicBrick " or string.sub(nm,1,20) == "ProceduralGateBrick " then
        pcall(function()
          local e = o.DefaultComponentEntries
          local n = (e and e.GetArrayNum) and e:GetArrayNum() or 0
          for i=1,n do local c = e[i].ComponentType; if c and c:IsValid() then used[c:GetFullName()] = true end end
        end)
      else
        local r = registeredComponentType(o, nm)
        if r then reglist[#reglist+1] = r end
      end
    end
  end)
  local list, seen = {}, {}
  for _, r in ipairs(reglist) do
    if not used[r.cls] and not seen[r.short] then
      seen[r.short] = true; ctoPath[r.short] = r.path; list[#list+1] = r.short
    end
  end
  table.sort(list)
  return list
end

local function processStandalone(short, cx, cy)
  local cto = StaticFindObject(ctoPath[short] or (regPath .. "." .. short))
  if not (cto and cto:IsValid()) then summary.skipped = summary.skipped + 1; err("noComp "..short); return end
  if not (hostBT and hostBT:IsValid()) then summary.skipped = summary.skipped + 1; err("noHostBrick"); return end
  local h, z = placeAt(hostBT, cx, cy, C.baseZ, C.gateOrient)
  if h == 0 then summary.placeFail = summary.placeFail + 1; err("place "..short); return end
  summary.placed = summary.placed + 1
  Z.attach(h, cto)
  local ins, outs = collectPorts(cto, h)
  summary.components = summary.components + 1
  summary.ports = summary.ports + #ins + #outs
  if C.doRerouters then wirePorts(cto, h, cx, cy, z, ins, outs) end
end

-- Built once per game process (Z.memo): enumerating every UObject costs about 300 ms,
-- and the list is the same for every chunk.
local function buildItems()
  local items = {}
  if C.standalone then
    items = buildStandaloneList()
  else
    local prefixes = {}
    for _, s in ipairs(C.sections) do prefixes[#prefixes+1] = "/Game/Bricks/Categories/" .. s .. "/" end
    local wiresRoot = "/Game/Bricks/Categories/Wires/"
    ForEachUObject(function(o)
      if o and o:IsValid() then
        local nm = o:GetFullName()
        if string.sub(nm, 1, 11) == "BasicBrick " then
          local path = string.sub(nm, 12)
          local matched = false
          for _, pre in ipairs(prefixes) do
            if string.sub(path, 1, #pre) == pre then matched = true; break end
          end
          -- also include bricks sitting DIRECTLY under /Wires/ (rerouter, microchip, microchip
          -- in/out "routers") -- their path has no further '/' after the /Wires/ prefix.
          if not matched and C.includeWiresRoot and string.sub(path, 1, #wiresRoot) == wiresRoot then
            local rest = string.sub(path, #wiresRoot + 1)
            if not string.find(rest, "/", 1, true) then matched = true end
          end
          if matched then items[#items+1] = path end
        elseif string.sub(nm, 1, 20) == "ProceduralGateBrick " then
          local path = string.sub(nm, 21)
          if not string.find(path, "Default__", 1, true) then
            local n = 0
            pcall(function() n = o.Variants:GetArrayNum() end)
            for vi = 0, n - 1 do items[#items+1] = path .. "#" .. vi end
          end
        end
      end
    end)
    table.sort(items)
  end
  return { items = items, ctoPath = ctoPath }
end
local list = Z.memo(table.concat({ "zoo", tostring(C.standalone), table.concat(C.sections, ","), tostring(C.includeWiresRoot) }, "|"), buildItems)
local items = list.items
for k, v in pairs(list.ctoPath) do ctoPath[k] = v end
summary.total = #items

local first = C.offset + 1
local last = math.min(#items, C.offset + C.limit)
local function logp(msg)
  if not C.progressFile then return end
  local f = io.open(C.progressFile, "a")
  if f then f:write(msg .. "\n"); f:close() end   -- close each time => flushed before any crash
end
for i = first, last do
  if C.skipPaths and C.skipPaths[items[i]] then
    summary.skipped = summary.skipped + 1
    logp("SKIP " .. i .. " " .. tostring(items[i]))
  else
    local idx = i - 1                         -- 0-based cell index
    local col = idx % C.cols
    local row = math.floor(idx / C.cols)
    local cx = C.baseX + col * CELL
    local cy = C.baseY + row * CELL
    logp("START " .. i .. " " .. tostring(items[i]))
    local ok = pcall(function()
      if C.standalone then processStandalone(items[i], cx, cy) else processBrick(items[i], cx, cy) end
    end)
    if not ok then err("item#"..i.." "..tostring(items[i])) end
    logp("DONE " .. i .. " " .. tostring(items[i]))
  end
end
summary.processedRange = { first = first, last = last }

if C.doMicrochip then
  local mc = StaticFindObject(MICROCHIP_ASSET .. ":BrickType")
  if mc and mc:IsValid() then
    local mx = C.baseX - CELL                -- one cell to the left of the grid
    local h = placeAt(mc, mx, C.baseY, C.baseZ, C.rerouterOrient)
    summary.microchip = (h ~= 0) and ("ok:"..tostring(h)) or "fail"
  else
    summary.microchip = "no asset"
  end
end

summary.brickCount = grid:GetBrickCount()
return summary
