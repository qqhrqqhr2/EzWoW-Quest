-- EzWoW - Quest : quest tables from EzWoW - Data when it is installed
--
-- EzWoW - Data is optional. The built-in tables (this addon's levels, Map
-- Finder's quest tables) come with every release, so they are never older than
-- EzWoW - Data's copies and are used whenever they are there. When EzWoW - Data
-- is installed, enabled and its modules have the shape this addon reads
-- (formatVersion 2), its copies only stand in for missing ones:
--   ns.QuestLevels       -> the shared quest levels (QuestLevels module, same rows as
--                           Data/QuestLevels.lua) when the built-in table is empty
--   ns.SharedQuestData   -> the shared quest tables (QuestMap module) when Map Finder
--                           loaded them (it does only when its own are missing);
--                           ns.QuestData() falls back to them
-- During combat (a /reload in a fight) the built-in levels are used for that
-- session. The shared tables are only read.
local _, ns = ...
local type, ipairs, pcall, next = type, ipairs, pcall, next

local FORMAT_VERSION = 2
local QUEST_TABLES = { "quests", "itemDrops", "itemObjects", "turnIns", "givers", "eventSpots" }

local function inCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function api()
    local D = _G.EzWoW_Data
    if type(D) ~= "table" or D.formatVersion ~= FORMAT_VERSION then return nil end
    for _, fn in ipairs({ "Load", "IsAvailable", "Peek", "OnModuleLoaded" }) do
        if type(D[fn]) ~= "function" then return nil end
    end
    return D
end

local function useQuestMap(m)
    if type(m) ~= "table" or m.formatVersion ~= FORMAT_VERSION then return end
    if type(m.quests) ~= "table" or next(m.quests) == nil then return end
    local view = {}
    for _, key in ipairs(QUEST_TABLES) do
        if type(m[key]) == "table" then view[key] = m[key] end
    end
    ns.SharedQuestData = view
end

local function useShared()
    local D = api()
    if not D then return end
    -- levels: this addon's own module, loaded only when the built-in levels or
    -- Map Finder's quest requirements are missing (they are the newer ones)
    local builtInLevels = type(ns.QuestLevels) == "table" and next(ns.QuestLevels) ~= nil
    local mapFinderData = type(_G.EzWoWMapFinderQuestRequirements) == "table"
    if not (builtInLevels and mapFinderData) then
        local ok, available = pcall(D.IsAvailable, "QuestLevels")
        if not (ok and available) and not inCombat() then
            pcall(D.Load, "QuestLevels")
        end
        local isOk, m = pcall(D.Peek, "QuestLevels")
        if isOk and type(m) == "table" and m.formatVersion == FORMAT_VERSION
            and type(m.levels) == "table" and next(m.levels) ~= nil then
            if not builtInLevels then ns.QuestLevels = m.levels end
            -- who may take a quest (race, class, profession): used only when Map
            -- Finder has none (ns.QuestRequirements)
            if type(m.requirements) == "table" and next(m.requirements) ~= nil then
                ns.SharedQuestRequirements = m.requirements
            end
        end
    end
    -- quest map tables: only when another addon (Map Finder) loads them
    pcall(D.OnModuleLoaded, "QuestMap", function(_, module) useQuestMap(module) end)
end

pcall(useShared)
