-- The zoo's UE4SS mod. The omegga plugin (omegga.plugin.ts) drives everything
-- through the handlers below; the zoo's scripts live in lua/zoo, with
-- lua/zoo/zoo.lua as their helpers on omegga-ue4ss's BR.
local Omegga = require("omegga")
local BR = require("omegga.brickadia")
_G.BR = BR

-- this file is <plugin>/mods/Zoo/Scripts/main.lua
local root = debug.getinfo(1, "S").source:sub(2):gsub("/mods/Zoo/Scripts/main%.lua$", "")
local zoo = root .. "/lua/zoo/"
package.path = zoo .. "?.lua;" .. package.path

Omegga.handle("ping", function() return "pong" end)
Omegga.handle("ready", function() return BR.world.ready() end)

-- The game caches each procedural brick type it generates, but nothing holds
-- the types once the dump deletes their bricks: GC collects them, and the cache
-- hands the same sizes back as dead objects for the rest of the process (a map
-- reload doesn't clear it). So a dump is only right in a game process that
-- hasn't run one; this state lives as long as the process.
Omegga.handle("brick_count", function() return BR.brick.count() end)

-- how much is in the world, for waiting on omegga's clearAllBricks
Omegga.handle("world_counts", function()
    return { bricks = BR.brick.count(), entities = #BR.entity.list() }
end)

-- Destroy the entity actors br.World.ClearAll left. Entity_Wheel_Racing1_Decal
-- places as an actor the game doesn't register as an entity (a transaction
-- deleting it reports EntitiesInvalid, and saves drop it), so neither the clear
-- nor a transaction removes it.
Omegga.handle("destroy_entities", function()
    local n = 0
    for _, e in ipairs(BR.entity.list()) do
        if e:IsValid() then
            e:K2_DestroyActor()
            n = n + 1
        end
    end
    return n
end)

Omegga.handle("dumped", function() return _G.ZOO_DUMPED == true end)
Omegga.handle("mark_dumped", function() _G.ZOO_DUMPED = true end)

-- Run one zoo script with its config global set (the scripts read DUMP, CAT,
-- INV, ...), as the desktop CLI did with dofile.
Omegga.handle("run_file", function(name, global, config)
    assert(name:match("^[%w_]+%.lua$"), "not a zoo script name: " .. tostring(name))
    if global then _G[global] = config end
    return dofile(zoo .. name)
end)
