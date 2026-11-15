-- What the zoo scripts need from the game, on omegga-ue4ss's BR. Replaces the
-- natives of the desktop cppmod: bricks are placed through transactions as
-- BR.player.server() (many per transaction where the caller can batch), and a
-- brick handle is BR's 8-byte BrickHandle string, 0 on failure, as before.
-- State that should outlive one script run (builders, item lists) lives in
-- _G.ZOO_STATE for the whole game process.
local BR = require("omegga.brickadia")
local Z = {}

local S = _G.ZOO_STATE or { builders = {}, memo = {} }
_G.ZOO_STATE = S

local SCRIPT = "/Script/Brickadia."

local function is_a(o, path)
    local c = StaticFindObject(path)
    return c and c:IsValid() and o:IsA(c)
end

--- `fn()`'s result, computed once per game process for `key`. The scripts run
--- once per chunk, and enumerating every UObject for their item lists costs
--- about 300 ms each time.
function Z.memo(key, fn)
    local v = S.memo[key]
    if v == nil then
        v = fn()
        S.memo[key] = v
    end
    return v
end

function Z.registry() return BR.world.registry() end

--- The world grid's BrickGridComponent, which the scripts clear and place on.
function Z.grid()
    local g = Z.registry().CachedGlobalBrickGrid
    assert(g and g:IsValid(), "no world brick grid")
    return g
end

function Z.clear() Z.grid():ClearAndDeleteBricks() end

-- BR.brick.builder kept per setting: one costs about 9 ms to make, and every
-- brick of a kind on a grid shares it
local function builder(bt, grid, material, color)
    local key = table.concat({ __addr(bt), __addr(grid), material, color[1], color[2], color[3] }, "|")
    local b = S.builders[key]
    if not b then
        b = BR.brick.builder({ asset = bt, grid = grid, material = material, color = { color[1], color[2], color[3], 255 }, owner = BR.player.owner_index() })
        S.builders[key] = b
    end
    return b
end

local function tx(fn) return BR.brick.transaction(BR.player.server(), fn) end

--- A placement for Z.place_many: { grid, brickType, x, y, z, orientation?, material?, color? }.
--- `material` is an index into BRRegistry.MaterialCollections as the desktop
--- scripts give it (3..8 are Plastic .. Hologram, EBrickMaterial 0..5), default 3;
--- `color` is {r, g, b}, default light grey.
local function prepare(p)
    local g, bt = p[1], p[2]
    if not (g and g:IsValid() and bt and bt:IsValid()) then return nil end
    local actor = is_a(g, SCRIPT .. "BrickGridComponent") and g:GetOwner() or g
    return {
        builder = builder(bt, actor, math.max((p.material or 3) - 3, 0), p.color or { 200, 200, 200 }),
        pos = { p[3], p[4], p[5] },
        orient = p[6] or BR.brick.Z_UP,
        world = __addr(actor) == __addr(BR.world.global_grid()),
    }
end

--- Place every brick of `list` (placements as above); the world grid's go in one
--- transaction. Returns the handles in order, 0 for a brick that didn't place
--- (overlap, refused). A microchip plane isn't an entity a transaction can
--- name, so its bricks are placed one by one.
function Z.place_many(list)
    local prepared, ids, out = {}, {}, {}
    for i, p in ipairs(list) do prepared[i] = prepare(p) or false end
    local any = false
    for _, q in ipairs(prepared) do if q and q.world then any = true end end
    if any then
        tx(function(t)
            for i, q in ipairs(prepared) do
                if q and q.world then ids[i] = t.place(q.builder, q.pos, q.orient) end
            end
        end)
    end
    for i, q in ipairs(prepared) do
        if not q then
            out[i] = 0
        elseif q.world then
            out[i] = ids[i] and BR.brick.handle(ids[i]) or 0
        else
            out[i] = BR.brick.place(q.builder, q.pos[1], q.pos[2], q.pos[3], q.orient) or 0
        end
    end
    return out
end

function Z.place(grid, bt, x, y, z, orient, material, color)
    return Z.place_many({ { grid, bt, x, y, z, orient, material = material, color = color } })[1]
end

--- Like Z.place, bumping z up the ladder the desktop used until the brick fits
--- above the baseplate. Returns handle, z (0, z when it never fit).
local LADDER = { 0, 2, 4, 6, 8, 12, 18, 26, 40, 60, 90, 140, 220 }
function Z.place_up(grid, bt, x, y, z, orient, material, color, ladder)
    for _, dz in ipairs(ladder or LADDER) do
        local h = Z.place(grid, bt, x, y, z + dz, orient, material, color)
        if h ~= 0 then return h, z + dz end
    end
    return 0, z
end

--- Which way `port` of component `ct` on brick `h` goes: bit 0 input, bit 1
--- output (3 both, 0 no port); -4 when the brick doesn't carry the component,
--- -1 for a dead handle, the convention the desktop's native used.
function Z.port(ct, h, port)
    if type(h) ~= "string" or not BR.brick.valid(h) then return -1 end
    if not BR.component.handle(h, ct) then return -4 end
    local d = BR.component.port_direction(h, ct, port)
    return d == "both" and 3 or d == "output" and 2 or d == "input" and 1 or 0
end

--- Attach component type `ct` to brick `h`; true when attached.
function Z.attach(h, ct)
    if type(h) ~= "string" or not BR.brick.valid(h) then return false end
    local report = tx(function(t) t.attach(BR.brick.id(h), ct) end)
    return (report.ComponentsAttached or 0) > 0
end

local function name_of(ct) return ct:GetFName():ToString() end

--- A wire for Z.wire_many: { srcType, srcHandle, outputPort, dstType, dstHandle, inputPort }.
--- Connects all of them in one transaction; returns how many connected.
function Z.wire_many(wires)
    if #wires == 0 then return 0 end
    local report = tx(function(t)
        for _, w in ipairs(wires) do
            t.connect(BR.brick.id(w[2]), BR.component.output_port(name_of(w[1]), w[3]),
                BR.brick.id(w[5]), BR.component.input_port(name_of(w[4]), w[6]))
        end
    end)
    return report.WiresConnected or 0
end

--- Place rerouters and wire each to its port, all in one transaction:
--- `list` is { { grid, rerouterType, x, y, z, orientation, wire = function(id) -> { src, output, dst, input } } },
--- `id` being the new rerouter's, and src/dst brick ids, output/input port refs (Z.id, Z.ref). Returns
--- placed, connected and the handles (0 for a rerouter that didn't place).
--- Rerouters on a microchip plane, or that collided, are placed and wired one by one.
function Z.place_and_wire(list)
    local prepared = {}
    for i, p in ipairs(list) do prepared[i] = prepare(p) or false end
    local ids = {}
    local report = tx(function(t)
        for i, q in ipairs(prepared) do
            if q and q.world then
                local id = t.place(q.builder, q.pos, q.orient)
                ids[i] = id
                local w = list[i].wire(id)
                t.connect(w.src, w.output, w.dst, w.input)
            end
        end
    end)
    local handles, placed, connected = {}, report.BricksPlaced or 0, report.WiresConnected or 0
    for i, q in ipairs(prepared) do
        handles[i] = (q and q.world and ids[i]) and BR.brick.handle(ids[i]) or 0
    end
    return placed, connected, handles
end

--- For Z.place_and_wire's `wire` callbacks: the id of a placed brick (the
--- callback's own rerouter comes as an id already), and a port ref.
function Z.id(h) return BR.brick.id(h) end
function Z.ref(ct, port, output)
    return output and BR.component.output_port(name_of(ct), port) or BR.component.input_port(name_of(ct), port)
end

--- Set field `field` (default "Asset") of component `ct` on brick `h` to the name
--- `value`: the asset's name for an asset reference, an option's name for a
--- property gate's selector. Returns "ok" once the field reads back as set.
function Z.set_name(h, ct, value, field)
    field = field or "Asset"
    if type(h) ~= "string" or not BR.brick.valid(h) then return "ERR:bad-handle" end
    local ok, e = pcall(BR.component.set, h, ct, { [field] = value })
    if not ok then return "ERR:" .. tostring(e) end
    local at, kind = BR.component.field(h, ct, field)
    if not at then return "ERR:no-component" end
    if kind == "NameProperty" then return BR.component.get(h, ct, field) == value and "ok" or "ERR:not-applied" end
    -- an object or class field: set once the pointer is no longer null
    return string.unpack("<I8", __peek(at, 8)) ~= 0 and "ok" or "ERR:not-applied"
end

--- The primary asset names of a type, sorted (chunked scripts need the same list every call).
function Z.primary_names(ptype)
    local names = BR.world.primary_assets(ptype)
    table.sort(names)
    return names
end

--- The strings a gate's options function (BrickHandle -> TArray<FString>) returns for brick `h`.
function Z.gate_options(obj, fn_path, h)
    local class, fn = fn_path:match("^/Script/(.-):(.+)$")
    assert(class, "not a UFunction path: " .. tostring(fn_path))
    local param
    for name, p in pairs(__fn_layout(fn_path)) do
        if type(p) == "table" and p.size == 8 and name ~= "ReturnValue" then param = name end
    end
    assert(param, fn_path .. " takes no brick handle")
    local data, num = string.unpack("<I8i4", BR.raw.call(obj, class, fn, { [param] = h }).ReturnValue)
    local out = {}
    for i = 0, num - 1 do out[#out + 1] = BR.raw.fstring(__peek(data + i * 16, 16)) end
    return out
end

return Z
