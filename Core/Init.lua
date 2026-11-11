--===========================================================================
-- EzWoW - Quest
-- Core/Init.lua : Namespace, SavedVariables, settings carry-over & map bridge
--===========================================================================
local ADDON_NAME, ns = ...
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall

ns.ADDON_NAME = ADDON_NAME or "EzWoW-Quest"
ns.VERSION = "1.0.0"

ns.Theme = {
    accent = { 0.478, 0.635, 0.969, 1.00 },
    text   = { 0.929, 0.957, 0.969, 1.00 },
    muted  = { 0.655, 0.725, 0.773, 1.00 },
    warn   = { 0.906, 0.486, 0.439, 1.00 },
}

ns.DEFAULTS = {
    lang = "Auto",
    -- tracker window handling (drag, Ctrl+wheel scale, quick reset clicks)
    enableMove = true,
    requireCtrl = false,
    enableScale = true,
    quickReset = true,
    clampToScreen = true,
    -- quest tracker
    enableTracker = true,
    hideDefaultTracker = true,
    trackerTrackAll = true,
    trackerShowZone = true,
    trackerShowBg = true,
    trackerLocked = false,
    npcQuestTooltip = true,  -- quests at an NPC on its tooltip and on the minimap tooltip   -- position and size can't be changed (header lock button)
    trackerExpanded = true,
    trackerWidth = 270,
    trackerHeight = 360,
    trackerCollapsedZones = {},
    trackerCollapsedQuests = {},
    trackerHiddenQuests = {},
    trackerWatchedQuests = {},
    -- automation and party messages
    questAutoAccept = false,
    questAutoComplete = false,
    questSkipRisky = true,
    questSkipItems = false,
    questPartyAnnounce = true,
    questMarkBest = true,
    -- quest sharing and party quest status
    questAutoShare = false,
    trackerPartyStatus = true,
    -- map and minimap marks
    questLogPins = true,
    questLogPinsAll = false,
    questGiverPins = true,
    questObjectivePins = true,
    questEngineRings = true,
    -- learned data
    questDropSources = {},
    questStarters = {},
    questEnders = {},
    questEventSpots = {},
    questDropItems = {},
    questEventShared = {},
    questGivers = {},
    -- sharing learned spots with other players of this addon
    questShareData = true,
    questShareChannel = true,
    questShareInbox = {},
}

-- Settings carried over once from the addons that had the quest features before.
local FRAME_MOVER_KEYS = {
    "lang", "enableMove", "requireCtrl", "enableScale", "quickReset", "clampToScreen",
    "enableTracker", "hideDefaultTracker", "trackerTrackAll", "trackerShowZone", "trackerShowBg",
    "trackerExpanded", "trackerWidth", "trackerHeight", "trackerPos", "trackerScale",
    "trackerCollapsedZones", "trackerCollapsedQuests", "trackerHiddenQuests", "trackerWatchedQuests",
    "questAutoAccept", "questAutoComplete", "questSkipRisky", "questSkipItems",
    "questPartyAnnounce", "questMarkBest",
}
local MAP_FINDER_KEYS = {
    "questLogPins", "questLogPinsAll", "questObjectivePins", "questEngineRings",
    "questDropSources", "questStarters",
}

local function copyValue(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copyValue(v) end
    return out
end

function ns:InitializeDatabase()
    if self.db and self.db == _G.EzWoW_QuestDB then
        return self.db
    end
    if type(_G.EzWoW_QuestDB) ~= "table" then
        _G.EzWoW_QuestDB = {}
    end
    local savedDB = _G.EzWoW_QuestDB
    -- the learned quest records live in the shared saved data of all EzWoW
    -- addons (Libs/EzWoWShare) and are read through this table
    if self.Share and self.Share.AttachQuestDB then self.Share.AttachQuestDB(savedDB) end
    for key, value in pairs(self.DEFAULTS) do
        if savedDB[key] == nil then
            savedDB[key] = copyValue(value)
        end
    end
    self.db = savedDB
    self.DB = savedDB
    return savedDB
end

-- Copies the quest settings of Frame Mover and Map Finder the first time this
-- addon runs. Their saved variables are loaded before this addon (OptionalDeps).
function ns:MigrateOldSettings()
    local savedDB = self:InitializeDatabase()
    if savedDB.migrationDone then return false end
    savedDB.migrationDone = true
    local copied = false
    local function take(source, keys)
        if type(source) ~= "table" then return end
        for _, key in ipairs(keys) do
            local value = source[key]
            if value ~= nil then
                savedDB[key] = copyValue(value)
                copied = true
            end
        end
    end
    take(_G.EzWoW_FrameMoverDB, FRAME_MOVER_KEYS)
    take(_G.EzWoW_MapFinderDB, MAP_FINDER_KEYS)
    -- Map Finder keeps its language as "auto"
    if savedDB.lang == "auto" then savedDB.lang = "Auto" end
    return copied
end

function ns:PrintMsg(msg)
    if not msg or msg == "" then return end
    local prefix = "|cff7aa2f7[EzWoW-Quest]|r "
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(prefix .. tostring(msg))
    else
        print(prefix .. tostring(msg))
    end
end

-----------------------------------------------------------------------------
-- Gamepad UI: the World Map or quest log opened by addon code taints the
-- game's gamepad navigation (Libs/EzWoWGamePad). With the gamepad on, only
-- secure clicks on the game's own buttons open them.
-----------------------------------------------------------------------------
function ns.IsGamePadUI()
    return ns.GamePad and ns.GamePad.IsActive() or false
end

-----------------------------------------------------------------------------
-- Work that has to wait for the end of combat
-----------------------------------------------------------------------------
ns.CombatQueue = {}

function ns:EnqueuePostCombatCallback(func, ...)
    self.CombatQueue[#self.CombatQueue + 1] = { func = func, args = { ... } }
end

function ns:FlushPostCombatCallbackQueue()
    if (InCombatLockdown and InCombatLockdown()) or #self.CombatQueue == 0 then return end
    local pending = self.CombatQueue
    self.CombatQueue = {}
    for index = 1, #pending do
        local item = pending[index]
        if item and item.func then
            local ok, err = pcall(item.func, unpack(item.args))
            if not ok and type(geterrorhandler) == "function" then
                geterrorhandler()(err)
            end
        end
    end
end

-----------------------------------------------------------------------------
-- Map Finder bridge: the map marks use Map Finder's location data and map
-- helpers through its public table (EzWoWMapFinderAPI) when it is loaded.
-----------------------------------------------------------------------------
local EMPTY = {}

local function isAddOnLoaded(name)
    local fn = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(fn) ~= "function" then return false end
    local ok, loaded = pcall(fn, name)
    return ok and loaded and true or false
end

function ns.MapAPI()
    local api = _G.EzWoWMapFinderAPI
    if type(api) ~= "table" then return nil end
    if not isAddOnLoaded("EzWoW-MapFinder") then return nil end
    return api
end

function ns.HasMapFinder()
    return ns.MapAPI() ~= nil
end

function ns.MapData()
    local api = ns.MapAPI()
    local data = api and type(api.GetData) == "function" and api.GetData()
    return type(data) == "table" and data or EMPTY
end

function ns.MapTranslations()
    local api = ns.MapAPI()
    local t = api and type(api.GetTranslations) == "function" and api.GetTranslations()
    return type(t) == "table" and t or nil
end

-- quest tables: the shared ones from EzWoW - Data (Data/SharedData.lua) when
-- loaded, else Map Finder's. Both only while Map Finder is loaded, so the
-- marks are the same with and without EzWoW - Data.
function ns.QuestData()
    local api = ns.MapAPI()
    if api and type(ns.SharedQuestData) == "table" then return ns.SharedQuestData end
    local q = api and type(api.GetQuestData) == "function" and api.GetQuestData()
    return type(q) == "table" and q or nil
end

-- function(spawn, mapID) -> mapID, x, y   (nil without Map Finder)
function ns.MapProjector()
    local api = ns.MapAPI()
    return api and type(api.ProjectSpawn) == "function" and api.ProjectSpawn or nil
end

-- names the waypoint just set for the on-screen arrow (Libs/EzWoWWaypointArrow)
function ns.SetWaypointArrowLabel(text)
    local arrow = _G.EzWoW_WaypointArrow
    if type(arrow) == "table" and type(arrow.SetLabel) == "function" then
        pcall(arrow.SetLabel, text, "EzWoW - Quest")
    end
end

-- labelText: what the on-screen arrow names
function ns.ApplyWaypointForSpawn(spawn, labelText)
    local api = ns.MapAPI()
    if api and type(api.ApplyWaypoint) == "function" then api.ApplyWaypoint(spawn, labelText or "", "EzWoW - Quest") end
end

function ns.PassMapRightClicks(frame)
    local api = ns.MapAPI()
    if api and type(api.PassMapRightClicks) == "function" then api.PassMapRightClicks(frame) end
end

function ns.GetLocalizedEntityName(entry)
    local api = ns.MapAPI()
    if api and type(api.LocalizedName) == "function" then return api.LocalizedName(entry) end
    return nil
end

function ns.IsAutoWaypoint()
    local api = ns.MapAPI()
    if api and type(api.IsAutoWaypoint) == "function" then return api.IsAutoWaypoint() and true or false end
    return true
end

-----------------------------------------------------------------------------
-- Start-up
-----------------------------------------------------------------------------
local migratedNote = false
local events = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        ns:InitializeDatabase()
        migratedNote = ns:MigrateOldSettings()
        if ns.InitUI then ns:InitUI() end
    elseif event == "PLAYER_LOGIN" then
        ns:InitializeDatabase()
        if migratedNote then
            migratedNote = false
            ns:PrintMsg(ns:L("MSG_MIGRATED"))
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns:FlushPostCombatCallbackQueue()
    end
end)
