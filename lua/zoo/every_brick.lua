local Z = require("zoo")
-- One of every BasicBrick shape, unwired, in a grid at baseY (the zoo's shapes phase).
-- Chunked with EB = { offset, limit }; returns { total, placed, fail, range = { first, last } }.
local C = { offset = 0, limit = 200, baseX = -600, baseY = 3000, cols = 24, cell = 50, material = 3 }
if type(EB) == "table" then for k, v in pairs(EB) do C[k] = v end end

local reg = Z.registry()
local grid = Z.grid()
if not (grid and grid:IsValid()) then return { error = "no grid" } end

local all = {}
ForEachUObject(function(o)
  if o and o:IsValid() then
    local fn = o:GetFullName()
    if string.sub(fn, 1, 11) == "BasicBrick " then
      local p = string.sub(fn, 12)
      -- Skip gate/wire bricks under /Wires/: they're the catalog phase's job (placed +
      -- wired there, with an attach-fallback for the grid-level WholeGrid* gates). Placing
      -- them here is redundant and makes the unplaceable ones look "lost" in this phase.
      if not string.find(p, "Default__") and not string.find(p, "/Categories/Wires/", 1, true) then
        all[#all + 1] = p
      end
    end
  end
end)
table.sort(all)

local placed, fail, fails = 0, 0, {}
local function markFail(p) fail = fail + 1; if #fails < 40 then fails[#fails + 1] = p end end
local first = C.offset + 1
local last = math.min(#all, C.offset + C.limit)
for i = first, last do
  local a = StaticFindObject(all[i])
  local bt = a and a.BrickType
  if bt and bt:IsValid() then
    local idx = i - 1
    local x = C.baseX + (idx % C.cols) * C.cell
    local y = C.baseY + math.floor(idx / C.cols) * C.cell
    local h = 0
    for _, z in ipairs({ 2, 4, 6, 8, 12, 18, 30, 50 }) do
      h = Z.place(grid, bt, x, y, z, 16, C.material, { 200, 200, 200 })
      if h ~= 0 then break end
    end
    if h ~= 0 then placed = placed + 1 else markFail(all[i]) end
  else
    markFail(all[i])
  end
end
return { total = #all, placed = placed, fail = fail, fails = fails, range = { first = first, last = last } }
