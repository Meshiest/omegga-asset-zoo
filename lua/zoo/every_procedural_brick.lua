local Z = require("zoo")
-- One of every ProceduralBrick, unwired (the zoo's procedural phase). ProceduralBrick assets (aero surfaces, ramps, wedges, slider joints, zone projector,
-- composed specials -- all under /Game/Bricks/Procedural/) have no fixed BrickType; a
-- placeable BrickType is generated per size via BrickHelpers::GetBrickTypeFromBrickAsset(
-- asset, IntVector size). We try a ladder of sizes until one generates AND places.
-- (The chosen size is cosmetic -- procedural sizes are stored per-instance in saves.)
-- Chunked with EPB = { offset, limit }; returns { total, placed, fail, range = { first, last } }.
-- baseX far in +X: the other zoo phases occupy x -1000..700 (catalog/standalone/assetrefs/
-- shapes/materials/wheels) and materials sit at y=5000, so procedural gets its own column.
local C = { offset = 0, limit = 48, baseX = 2500, baseY = -600, cols = 12, cell = 60, material = 3 }
if type(EPB) == "table" then for k, v in pairs(EPB) do C[k] = v end end

local reg = Z.registry()
local grid = Z.grid()
if not (grid and grid:IsValid()) then return { error = "no grid" } end
local bh = StaticFindObject("/Script/Brickadia.Default__BrickHelpers")
if not (bh and bh:IsValid()) then return { error = "no BrickHelpers" } end

local PROC_SIZES = {
  { X = 10, Y = 10, Z = 6 }, { X = 10, Y = 10, Z = 10 }, { X = 10, Y = 20, Z = 1 },
  { X = 10, Y = 5, Z = 10 }, { X = 20, Y = 20, Z = 6 }, { X = 10, Y = 10, Z = 2 },
  { X = 10, Y = 10, Z = 4 }, { X = 5, Y = 5, Z = 6 }, { X = 2, Y = 2, Z = 2 }, { X = 1, Y = 1, Z = 1 },
  -- composed bricks (only reached if the generic sizes above all fail): their generators
  -- accept a fixed Y=5 and a type-specific Z (slider joints Z=1, baguette Z=3, picket fence Z=12).
  { X = 10, Y = 5, Z = 1 }, { X = 20, Y = 5, Z = 3 }, { X = 20, Y = 5, Z = 12 },
}

local all = {}
-- once per game process: the scan visits every UObject
all = Z.memo("procedural", function()
  ForEachUObject(function(o)
    if o and o:IsValid() then
      local fn = o:GetFullName()
      if string.sub(fn, 1, 16) == "ProceduralBrick " then
        local p = string.sub(fn, 17)
        if not string.find(p, "Default__") then all[#all + 1] = p end
      end
    end
  end)
  table.sort(all)
  return all
end)

local placed, fail, fails = 0, 0, {}
local first = C.offset + 1
local last = math.min(#all, C.offset + C.limit)
for i = first, last do
  local a = StaticFindObject(all[i])
  local idx = i - 1
  local x = C.baseX + (idx % C.cols) * C.cell
  local y = C.baseY + math.floor(idx / C.cols) * C.cell
  local h = 0
  if a and a:IsValid() then
    for _, sz in ipairs(PROC_SIZES) do
      local ok, bt = pcall(function() return bh:GetBrickTypeFromBrickAsset(a, sz) end)
      if ok and bt and bt:IsValid() then
        for _, z in ipairs({ 2, 4, 6, 8, 12, 18, 30, 50 }) do
          h = Z.place(grid, bt, x, y, z, 16, C.material, { 200, 200, 200 })
          if h ~= 0 then break end
        end
        if h ~= 0 then break end
      end
    end
  end
  if h ~= 0 then placed = placed + 1 else fail = fail + 1; if #fails < 40 then fails[#fails + 1] = all[i] end end
end
return { total = #all, placed = placed, fail = fail, fails = fails, range = { first = first, last = last } }
