local Z = require("zoo")
local BR = require("omegga.brickadia")
local function tx(fn) return BR.brick.transaction(BR.player.server(), fn) end
-- The zoo's other pieces: paintable-material bricks, wheel entities, and one dynamic
-- brick grid, by EX.mode:
-- EX = { mode = "materials" }                       -- 6 bricks, one per paintable material (idx 3-8)
-- EX = { mode = "wheels", offset = 0, limit = 16 }   -- one frozen entity of every wheel type (chunked)
-- EX = { mode = "dynamicgrid" }                      -- a dynamic grid entity holding two bricks
-- On a server these go through transactions: the desktop froze wheels and split a selection
-- off with the local player's Manipulator and Selector, which a server doesn't have, and its
-- directly spawned wheel actors had no brick body.
local C = { mode = "materials", offset = 0, limit = 16 }
if type(EX) == "table" then for k, v in pairs(EX) do C[k] = v end end

local reg = Z.registry()
local grid = Z.grid()
local ROUND = "/Game/Bricks/Categories/Rounds/Round/B_1x1F_Round.B_1x1F_Round"

if C.mode == "materials" then
  -- paintable materials are 0-indexed into BRRegistry.MaterialCollections: 3-8 are paintable.
  local round = StaticFindObject(ROUND).BrickType
  local placed = 0
  for mat = 3, 8 do
    local h = 0
    for _, z in ipairs({ 2, 4, 6, 8 }) do
      h = Z.place(grid, round, -600 + (mat - 3) * 40, 5000, z, 16, mat, { 180, 140, 90 })
      if h ~= 0 then break end
    end
    if h ~= 0 then placed = placed + 1 end
  end
  return { mode = "materials", placed = placed, total = 6 }

elseif C.mode == "wheels" then
  -- once per game process: the scan visits every UObject
  local classes = Z.memo("wheels", function()
    local list = {}
    ForEachUObject(function(o)
      if o and o:IsValid() and o:GetClass():GetFName():ToString() == "BlueprintGeneratedClass" then
        local nm = o:GetFName():ToString()
        if nm:sub(1, 15) == "BP_Entity_Wheel" then list[#list + 1] = { nm = nm } end
      end
    end)
    table.sort(list, function(a, b) return a.nm < b.nm end)
    return list
  end)
  local first, last = C.offset + 1, math.min(#classes, C.offset + C.limit)
  local cols = C.cols or 10
  local spawned, frozen, errors = 0, 0, {}
  for i = first, last do
    local c = classes[i]
    local x = (C.baseX or -600) + ((i - 1) % cols) * (C.cell or 60)
    local y = (C.baseY or 6000) + math.floor((i - 1) / cols) * (C.cell or 60)
    local z = C.baseZ or 150
    -- BP_Entity_Wheel_X_C is the Blueprint base the desktop spawned; the type a
    -- transaction places is its subclass Entity_Wheel_X
    local name = c.nm:gsub("^BP_", ""):gsub("_C$", "")
    local ok, report = pcall(tx, function(t)
      t.place_entity(name, { pos = { x, y, z } }, { frozen = true, owner = BR.player.owner_index() })
    end)
    if ok and (report.EntitiesPlaced or 0) > 0 then
      spawned, frozen = spawned + 1, frozen + 1
    else
      errors[#errors + 1] = c.nm .. ": " .. (ok and "not placed" or tostring(report))
    end
  end
  return { mode = "wheels", total = #classes, spawned = spawned, frozen = frozen, errors = errors, range = { first = first, last = last } }
elseif C.mode == "dynamicgrid" then
  -- two stacked rounds on a dynamic grid entity, where the desktop split the
  -- same two bricks off the world grid (brick units are world units here)
  local x, y = -1000, 10000
  local g = BR.entity.spawn("Entity_DynamicBrickGrid", x, y, 6, { frozen = true, owner = BR.player.owner_index() })
  local b = BR.brick.builder({ asset = "B_1x1F_Round", grid = g, color = { 200, 60, 60, 255 }, material = "Metal", owner = BR.player.owner_index() })
  local report = tx(function(t)
    t.place(b, { 0, 0, -2 }, BR.brick.Z_UP, g)
    t.place(b, { 0, 0, 2 }, BR.brick.Z_UP, g)
  end)
  return { mode = "dynamicgrid", splitOk = (report.BricksPlaced or 0) == 2, report = BR.brick.changes(report) }
end

return { error = "unknown mode " .. tostring(C.mode) }
