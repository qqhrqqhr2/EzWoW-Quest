--===========================================================================
-- EzWoW - Quest
-- Modules/QuestSources.lua : where quests are turned in and where "event"
-- objectives are, from records checked in the game
--===========================================================================
-- 1. Learned while playing (saved, shared by all characters):
--    - the NPC or object a quest was handed in to, and the spot it stood at;
--    - the spot where an "event" objective (reach a place, scout an area)
--      was completed.
--    Records confirmed by other players of this addon (Modules/DataShare.lua)
--    are kept the same way.
-- 2. The built-in data the updater makes from such records (Map Finder's
--    quest table: turnIns, eventSpots).
-- Spots are { continent, worldX, worldY } like Map Finder's location data.
local _, ns = ...

local QuestSources = {}
ns.QuestSources = QuestSources

local type, ipairs, tonumber, pcall = type, ipairs, tonumber, pcall
local floor = math.floor

local function isSecret(v) return issecretvalue and issecretvalue(v) end

-----------------------------------------------------------------------------
-- Saved data
-----------------------------------------------------------------------------
local function store(key)
    if not ns.DB then return nil end
    if type(ns.DB[key]) ~= "table" then ns.DB[key] = {} end
    return ns.DB[key]
end

-- where the player stands: { continent, x, y }
local function playerSpot()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then return nil end
    local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or type(mapID) ~= "number" or isSecret(mapID) then return nil end
    local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not okPos or not pos then return nil end
    local okWorld, continent, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
    if not okWorld or type(continent) ~= "number" or isSecret(continent) or type(world) ~= "table" then return nil end
    local x, y = world.x, world.y
    if type(x) ~= "number" or type(y) ~= "number" or isSecret(x) or isSecret(y) then return nil end
    return { continent, floor(x * 10 + 0.5) / 10, floor(y * 10 + 0.5) / 10 }
end

-- "npc:123" / "object:123" for the NPC or object the quest window belongs to
local function guidKey(guid)
    if type(guid) ~= "string" or isSecret(guid) then return nil end
    local unitType, _, _, _, _, id = strsplit("-", guid)
    id = tonumber(id)
    if not id then return nil end
    if unitType == "Creature" or unitType == "Vehicle" then return "npc:" .. id end
    if unitType == "GameObject" then return "object:" .. id end
    return nil
end

local function questPartnerKey()
    for _, unit in ipairs({ "questnpc", "npc" }) do
        local ok, guid = pcall(UnitGUID, unit)
        if ok then
            local key = guidKey(guid)
            if key then return key end
        end
    end
    return nil
end

-----------------------------------------------------------------------------
-- Map Finder entries by kind and ID
-----------------------------------------------------------------------------
local ownByKey

local function ownEntry(kind, id)
    if not ownByKey then
        if not (ns.HasMapFinder and ns.HasMapFinder()) then return nil end
        ownByKey = {}
        for _, e in ipairs(ns.MapData()) do
            if (e.kind == "npc" or e.kind == "object") and e.id and type(e.spawns) == "table" and #e.spawns > 0 then
                local key = e.kind .. ":" .. e.id
                ownByKey[key] = ownByKey[key] or e
            end
        end
    end
    return ownByKey[kind .. ":" .. id]
end

local function entryFor(kind, id)
    if type(id) ~= "number" or id <= 0 then return nil end
    return ownEntry(kind, id)
end
QuestSources.entryFor = entryFor

-- name in the client's language when it can be had (the game's own NPC name)
local function nameOf(e)
    if not e or e.kind == "spot" then return nil end
    local name
    if ns.GetLocalizedEntityName then
        local ok, n = pcall(ns.GetLocalizedEntityName, e)
        if ok and type(n) == "string" and n ~= "" and not isSecret(n) then name = n end
    end
    if not name and e.names then name = e.names.enUS end
    return name
end
QuestSources.nameOf = nameOf

-----------------------------------------------------------------------------
-- Turn-in places
-----------------------------------------------------------------------------
-- Map Finder's quest table (built-in data made by the updater)
local function builtInQuestData()
    local qd = (type(ns.QuestData) == "function" and ns.QuestData()) or _G.EzWoWMapFinderQuestData
    return type(qd) == "table" and qd or nil
end

local function isSpot(spot)
    return type(spot) == "table" and type(spot[1]) == "number" and type(spot[2]) == "number" and type(spot[3]) == "number"
end

-- kind ("npc" / "object"), ID and an optional spot -> entries
local function turnInFrom(kind, id, spot)
    id = tonumber(id)
    local e = kind and id and entryFor(kind, id)
    if e then return { e } end
    if isSpot(spot) then
        return { { kind = kind or "npc", id = id, spawns = { spot }, learned = true } }
    end
    return nil
end

-- Returns a list of entries (each with spawns) where the quest is turned in,
-- or nil when neither source knows it.
function QuestSources.turnInEntries(questID)
    -- learned by this character (or confirmed by other players)
    local learned = ns.DB and type(ns.DB.questEnders) == "table" and ns.DB.questEnders[questID]
    if type(learned) == "table" then
        local kind, id
        if type(learned.key) == "string" then kind, id = learned.key:match("^(%a+):(%d+)$") end
        local list = turnInFrom(kind, id, learned.spot)
        if list then return list end
    end
    -- built-in data: turnIns[questID] = { "npc" | "object", ID, continent, x, y }
    local qd = builtInQuestData()
    local row = qd and type(qd.turnIns) == "table" and qd.turnIns[questID]
    if type(row) == "table" then
        local list = turnInFrom(row[1], row[2], row[3] and { row[3], row[4], row[5] })
        if list then return list end
    end
    return nil
end

-----------------------------------------------------------------------------
-- Objectives
-----------------------------------------------------------------------------
-- Spot(s) of an "event" objective: where it was completed before, else the
-- built-in data.
function QuestSources.eventEntries(questID, objIndex)
    local saved = ns.DB and type(ns.DB.questEventSpots) == "table" and ns.DB.questEventSpots[questID]
    local spot = type(saved) == "table" and saved[objIndex]
    if isSpot(spot) then
        return { { kind = "spot", spawns = { spot }, learned = true } }
    end
    -- built-in data: eventSpots[questID] = { [objective index] = { continent, x, y } }
    local qd = builtInQuestData()
    local row = qd and type(qd.eventSpots) == "table" and qd.eventSpots[questID]
    if type(row) == "table" and isSpot(row[objIndex]) then
        return { { kind = "spot", spawns = { row[objIndex] }, learned = true } }
    end
    return nil
end

-----------------------------------------------------------------------------
-- Learning
-----------------------------------------------------------------------------
local pendingTurnIn       -- { questID, key, spot } while the reward window is open
local eventState = {}     -- "questID:index" -> finished (this session)

local function onQuestComplete()
    local questID = type(GetQuestID) == "function" and tonumber(GetQuestID()) or nil
    if not questID or isSecret(questID) or questID <= 0 then pendingTurnIn = nil return end
    local key = questPartnerKey()
    -- a quest finished from the quest log (no NPC) tells nothing
    if not key then pendingTurnIn = nil return end
    pendingTurnIn = { questID = questID, key = key, spot = playerSpot() }
end

local function onQuestTurnedIn(questID)
    questID = tonumber(questID)
    local pending = pendingTurnIn
    pendingTurnIn = nil
    if not questID or isSecret(questID) or not pending or pending.questID ~= questID then return end
    local enders = store("questEnders")
    if not enders then return end
    enders[questID] = { key = pending.key, spot = pending.spot }
end

local function collectLogQuests()
    local ids = {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return ids end
    local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
    for index = 1, (ok and tonumber(count)) or 0 do
        local okInfo, info = pcall(C_QuestLog.GetInfo, index)
        if okInfo and type(info) == "table" and not info.isHeader and type(info.questID) == "number"
            and not isSecret(info.questID) then
            ids[#ids + 1] = info.questID
        end
    end
    return ids
end

-- An "event" objective that turns finished: the spot is kept (first time only).
local function checkEventObjectives()
    if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return end
    local learned = false
    for _, questID in ipairs(collectLogQuests()) do
        local ok, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)
        if ok and type(objectives) == "table" then
            for index, o in ipairs(objectives) do
                if type(o) == "table" and not isSecret(o.type) and o.type == "event" and not isSecret(o.finished) then
                    local key = questID .. ":" .. index
                    local finished = o.finished == true
                    if eventState[key] == false and finished then
                        local spots = store("questEventSpots")
                        local spot = playerSpot()
                        if spots and spot then
                            spots[questID] = spots[questID] or {}
                            local current = spots[questID][index]
                            if not current or current.shared then
                                spots[questID][index] = spot
                                learned = true
                            end
                        end
                    end
                    eventState[key] = finished
                end
            end
        end
    end
    if learned and ns.QuestObjectivePins and ns.QuestObjectivePins.refreshAll then
        pcall(ns.QuestObjectivePins.refreshAll)
    end
end

local checkQueued = false
local events = CreateFrame("Frame")
for _, event in ipairs({ "QUEST_COMPLETE", "QUEST_TURNED_IN", "QUEST_FINISHED", "QUEST_LOG_UPDATE", "PLAYER_LOGIN" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "QUEST_COMPLETE" then
        pcall(onQuestComplete)
    elseif event == "QUEST_TURNED_IN" then
        pcall(onQuestTurnedIn, arg1)
    elseif event == "QUEST_FINISHED" then
        -- the window closes before QUEST_TURNED_IN arrives: keep the pending
        -- turn-in a moment longer
        if pendingTurnIn and C_Timer and C_Timer.After then
            local p = pendingTurnIn
            C_Timer.After(2, function() if pendingTurnIn == p then pendingTurnIn = nil end end)
        end
    else
        if checkQueued or not (C_Timer and C_Timer.After) then return end
        checkQueued = true
        C_Timer.After(0.5, function()
            checkQueued = false
            pcall(checkEventObjectives)
        end)
    end
end)
