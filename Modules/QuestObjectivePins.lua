--===========================================================================
-- EzWoW - Quest
-- Modules/QuestObjectivePins.lua : objective spots of quests in progress
--===========================================================================
-- For quests in the player's log that are not finished yet, the monsters and
-- objects named in their objectives are looked up in Map Finder's location
-- data (exact name match only) and their spawn points are drawn as small
-- dots: red for creatures to kill, gold for things to collect or use; nearby
-- dots are joined by thin lines. Quests without such spots get a hollow gold
-- ring at the game's own quest position. The minimap shows the marks nearby.
local _, ns = ...
-- frames made on the World Map are made without a parent and put in after
-- (Libs/EzWoWGamePad MakeFrame: keeps the game's gamepad cursor untainted)
local CreateFrame = (ns.GamePad and ns.GamePad.MakeFrame) or CreateFrame

-- Click pass-through can't be changed in combat: it is set once combat ends.
local pendingPropagate = {}
local propagateFrame
local function setPropagateClicks(frame, value)
    if not frame.SetPropagateMouseClicks then return end
    if InCombatLockdown and InCombatLockdown() then
        pendingPropagate[frame] = value
        if not propagateFrame then
            propagateFrame = CreateFrame("Frame")
            propagateFrame:SetScript("OnEvent", function()
                for f, v in pairs(pendingPropagate) do
                    pendingPropagate[f] = nil
                    f:SetPropagateMouseClicks(v)
                end
            end)
            pcall(propagateFrame.RegisterEvent, propagateFrame, "PLAYER_REGEN_ENABLED")
        end
        return
    end
    pendingPropagate[frame] = nil
    frame:SetPropagateMouseClicks(value)
end

-- The hovered mark comes to the front of marks that overlap it, and goes back
-- to its own level when the mouse leaves.
local function raisePin(self)
    if self.ezBaseLevel == nil then self.ezBaseLevel = self:GetFrameLevel() end
    self:SetFrameLevel(self.ezBaseLevel + 500)
end
local function lowerPin(self)
    if self.ezBaseLevel ~= nil then
        self:SetFrameLevel(self.ezBaseLevel)
        self.ezBaseLevel = nil
    end
end

-- Marks grow a little when the map is zoomed in (less than the map itself,
-- at most 3x), so they stay readable without covering the map.
local function zoomGrow(cScale)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local minScale
    if sc and sc.GetScaleForMinZoom then
        local ok, v = pcall(sc.GetScaleForMinZoom, sc)
        if ok and type(v) == "number" and v > 0 then minScale = v end
    end
    if not minScale or not cScale or cScale <= minScale then return 1 end
    local f = (cScale / minScale) ^ 0.6
    if f > 3 then f = 3 end
    return f
end
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local floor, abs, sqrt, sin, cos = math.floor, math.abs, math.sqrt, math.sin, math.cos

local QuestObjectivePins = ns.QuestObjectivePins or {}
ns.QuestObjectivePins = QuestObjectivePins

local Theme = ns.Theme

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DOT_SIZE = 7
local AREA_SIZE = 11

-- One colour per quest, only bright ones that stand out on the yellow, brown
-- and green map art (no dark colours; no gold: gold is the game's quest ring).
local QUEST_COLORS = {
    { 1.00, 0.32, 0.28 },  -- red
    { 0.35, 0.68, 1.00 },  -- blue
    { 0.35, 0.92, 0.42 },  -- green
    { 0.98, 0.45, 0.92 },  -- pink
    { 1.00, 0.60, 0.15 },  -- orange
    { 0.30, 0.95, 0.95 },  -- cyan
    { 0.68, 0.52, 1.00 },  -- violet
    { 0.96, 0.96, 0.96 },  -- white
    { 0.75, 1.00, 0.20 },  -- lime
    { 1.00, 0.20, 0.65 },  -- magenta
    { 1.00, 0.68, 0.62 },  -- salmon
    { 0.65, 1.00, 0.80 },  -- mint
    { 0.72, 0.88, 1.00 },  -- pale sky
    { 0.88, 0.75, 1.00 },  -- lavender
    { 0.30, 1.00, 0.65 },  -- spring green
    { 0.95, 0.60, 1.00 },  -- orchid
}
local COLOR_TITLE = { 1.00, 0.82, 0.00 }
local function objectiveColor(obj, quest)
    return (quest and quest.dotColor) or QUEST_COLORS[1]
end
local MERGE_PIXELS = 7
local MAX_WORLD_DOTS = 700
local MAX_MINIMAP_DOTS = 80
local MAX_SPAWNS_PER_ENTRY = 400
local MINIMAP_DOT_SIZE = 6
local MINIMAP_MERGE = 4

local function isSecret(v) return issecretvalue and issecretvalue(v) end

-- The game's own quest point (C_QuestLog.GetQuestsOnMap) is shown as a ring for
-- quests that have no objective dots on the map (e.g. items dropped by mobs).
-- It can sit on the map's decoration art, which the client doesn't tell apart,
-- so a ring is only drawn where our data has NPCs or objects nearby.
local function engineRingsOn()
    return ns.DB and ns.DB.questEngineRings ~= false
end

local GRID = 32
local occupiedByMap = {}

-- grid[cell] = true where any NPC or object of our data stands on this map
local function occupiedGrid(mapID)
    local cached = occupiedByMap[mapID]
    if cached ~= nil then return cached end
    occupiedByMap[mapID] = false
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return false end
    local ok0, cont0, w0 = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0, 0))
    local ok1, cont1, w1 = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(1, 1))
    if not (ok0 and ok1 and w0 and w1 and cont0 and cont0 == cont1) then return false end
    local x0, y0 = w0:GetXY()
    local x1, y1 = w1:GetXY()
    if not (x0 and y0 and x1 and y1) or x1 == x0 or y1 == y0 then return false end
    local grid = {}
    for _, e in ipairs(ns.MapData()) do
        if (e.kind == "npc" or e.kind == "object") and e.spawns then
            for _, sp in ipairs(e.spawns) do
                if sp[1] == cont0 and type(sp[2]) == "number" and type(sp[3]) == "number" then
                    -- map x runs along world Y, map y along world X
                    local mx = (sp[3] - y0) / (y1 - y0)
                    local my = (sp[2] - x0) / (x1 - x0)
                    if mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then
                        grid[floor(mx * GRID) * GRID + floor(my * GRID)] = true
                    end
                end
            end
        end
    end
    occupiedByMap[mapID] = grid
    return grid
end

-- true when the point has our data near it (or no grid could be made)
local function ringPlaceOK(mapID, x, y)
    local grid = occupiedGrid(mapID)
    if not grid then return true end
    local cx, cy = floor(x * GRID), floor(y * GRID)
    for dx = -1, 1 do
        for dy = -1, 1 do
            if grid[(cx + dx) * GRID + (cy + dy)] then return true end
        end
    end
    return false
end

local function enabled()
    return ns.DB and ns.DB.questObjectivePins ~= false and ns.HasMapFinder()
end

local function clientLocale()
    local loc = (GetLocale and GetLocale()) or "enUS"
    if loc == "esMX" then loc = "esES" elseif loc == "enGB" then loc = "enUS" end
    return loc
end

-----------------------------------------------------------------------------
-- Name index: exact (case-folded) names of NPC and object entries
-----------------------------------------------------------------------------
local nameIndex   -- kind -> normalized name -> { entry, ... }
local displayName = {}   -- normalized name -> name as written

local function normalize(s)
    if type(s) ~= "string" or s == "" or isSecret(s) then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == "" then return nil end
    return string.lower(s)
end

local function addName(kind, name, entry)
    local key = normalize(name)
    if not key then return end
    displayName[key] = displayName[key] or name
    local byName = nameIndex[kind]
    local list = byName[key]
    if not list then
        byName[key] = { entry }
        return
    end
    for _, existing in ipairs(list) do
        if existing == entry then return end
    end
    list[#list + 1] = entry
end

function QuestObjectivePins.buildNameIndex()
    if nameIndex then return end
    nameIndex = { npc = {}, object = {} }
    local loc = clientLocale()
    local translations = ns.MapTranslations()
    local locTable = type(translations) == "table" and translations[loc] or nil
    for _, e in ipairs(ns.MapData()) do
        local kind = e.kind
        if (kind == "npc" or kind == "object") and e.id and type(e.spawns) == "table" and #e.spawns > 0 then
            if e.names then
                addName(kind, e.names.enUS, e)
                if loc ~= "enUS" then addName(kind, e.names[loc], e) end
            end
            local kt = locTable and locTable[kind]
            if kt and kt[e.id] then addName(kind, kt[e.id], e) end
        end
    end
end

-- Words around the name in "kill" objectives ("X slain", "X 처치", ...).
-- They are only taken off when what is left is a known name.
local KILL_SUFFIXES = {
    " slain", " killed", " destroyed", " defeated",
    " 처치", " 처치함", " 죽임", " 격파", " 파괴",
    " getötet", " erschlagen", " vernichtet", " besiegt",
    " tué", " tués", " tuée", " tuées", " vaincu", " vaincus", " détruit", " détruits",
    " muerto", " muertos", " muerta", " muertas", " asesinado", " asesinados", " asesinada", " asesinadas",
    " derrotado", " derrotados", " destruido", " destruidos",
    " убит", " убита", " убито", " убиты", " уничтожен", " уничтожено", " уничтожены",
    "已杀死", "被杀死", "杀死", "已消灭", "消灭",
    "已殺死", "被殺死", "殺死", "擊殺", "已消滅", "消滅",
}
local KILL_PREFIXES = {
    "убито: ", "Убито: ", "убито ", "Убито ", "убит ", "Убит ",
    "杀死", "击杀", "消灭", "殺死", "擊殺", "消滅",
}

-- Takes the counter ("1/10", ": 1/10") and a trailing "(...)" off the text.
local function stripCounts(text)
    local s = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("\239\188\154", ":")   -- full-width colon
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^%d+%s*/%s*%d+%s*", "")
    s = s:gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
    s = s:gsub("%s+%d+%s*/%s*%d+%s*$", "")
    s = s:gsub("%s*%([^%(%)]*%)%s*$", "")
    s = s:gsub("%s*:%s*$", ""):gsub("^%s*:%s*", "")
    return s
end

local function lookup(kind, name)
    local key = normalize(name)
    return key and nameIndex[kind][key] or nil
end

local function endsWith(s, suffix)
    return #s > #suffix and s:sub(-#suffix) == suffix
end

local function startsWith(s, prefix)
    return #s > #prefix and s:sub(1, #prefix) == prefix
end

-- Returns the matching entries (or nil) for one objective.
function QuestObjectivePins.matchObjective(objType, text)
    if type(text) ~= "string" or text == "" or isSecret(text) then return nil end
    QuestObjectivePins.buildNameIndex()
    local base = stripCounts(text)
    if base == "" then return nil end
    if objType == "item" then
        -- only things that can be picked up from the world carry the item's name
        return lookup("object", base)
    end
    local kind = (objType == "monster") and "npc" or "object"
    local found = lookup(kind, base)
    if found then return found end
    for _, suffix in ipairs(KILL_SUFFIXES) do
        if endsWith(base, suffix) then
            found = lookup(kind, base:sub(1, #base - #suffix))
            if found then return found end
        end
    end
    for _, prefix in ipairs(KILL_PREFIXES) do
        if startsWith(base, prefix) then
            found = lookup(kind, base:sub(#prefix + 1))
            if found then return found end
        end
    end
    return nil
end

-----------------------------------------------------------------------------
-- Items that creatures drop. There is no drop table in our data, so:
--  1. learned: when a quest item is looted, the creature it came from is
--     remembered (saved), and its spawns are shown from then on;
--  2. guessed: creatures whose name holds a word of the item's name
--     ("Intact Raptor Horn" -> "... Raptor"), only on the quest's own zone map.
-----------------------------------------------------------------------------
local npcById        -- npc id -> entry
local objectById, itemById   -- id -> entry (with spawns)
local npcByWord      -- last word of an NPC name (lower case) -> { entry, ... }
-- guesses are drawn only inside the quest's own zone, so this is just a safety cap
local MAX_GUESS_ENTRIES = 80

local function buildDropIndexes()
    if npcById then return end
    QuestObjectivePins.buildNameIndex()
    npcById, npcByWord, objectById, itemById = {}, {}, {}, {}
    for _, e in ipairs(ns.MapData()) do
        if e.id and type(e.spawns) == "table" and #e.spawns > 0 then
            if e.kind == "npc" then
                npcById[e.id] = npcById[e.id] or e
            elseif e.kind == "object" then
                objectById[e.id] = objectById[e.id] or e
            elseif e.kind == "item" then
                itemById[e.id] = itemById[e.id] or e
            end
        end
    end
    for name, list in pairs(nameIndex.npc) do
        local last = name:match("(%S+)$")
        if last then
            local bucket = npcByWord[last]
            if not bucket then
                bucket = {}
                npcByWord[last] = bucket
            end
            for _, e in ipairs(list) do bucket[#bucket + 1] = e end
        end
    end
end

local function dropStore()
    if not ns.DB then return nil end
    if type(ns.DB.questDropSources) ~= "table" then ns.DB.questDropSources = {} end
    return ns.DB.questDropSources
end

-- the same records by item ID: itemID -> { [npcID] = true | "s", ["o:objectID"] = spot }
local function itemDropStore()
    if not ns.DB then return nil end
    if type(ns.DB.questDropItems) ~= "table" then ns.DB.questDropItems = {} end
    return ns.DB.questDropItems
end

-- every spot of a looted object: the first one, plus the other places
-- players reported for it (value.more)
local function objectSpots(value)
    local spots = { value }
    if type(value.more) == "table" then
        for _, sp in ipairs(value.more) do
            if type(sp) == "table" and type(sp[1]) == "number" then spots[#spots + 1] = sp end
        end
    end
    return spots
end

local function learnedDropEntries(itemKey)
    local store = dropStore()
    local ids = store and store[itemKey]
    if type(ids) ~= "table" then return nil end
    buildDropIndexes()
    local list = {}
    for id, value in pairs(ids) do
        local e
        if type(id) == "string" and id:sub(1, 2) == "o:" then
            -- an object: the spot where it was looted (the built-in position of
            -- the same object ID can be elsewhere)
            if type(value) == "table" and type(value[1]) == "number" then
                local objectID = tonumber(id:sub(3))
                local known = objectID and objectById[objectID]
                e = { id = objectID, kind = "object", names = known and known.names, spawns = objectSpots(value) }
            end
        else
            e = npcById[tonumber(id)]
        end
        if e then list[#list + 1] = e end
    end
    return #list > 0 and list or nil
end

-- a word is worth looking up when it is not tiny (Hangul/CJK count 3 bytes each)
local function usefulWord(word)
    if word:find("[\128-\255]") then return #word >= 6 end
    return #word >= 4
end

local function guessedDropEntries(itemKey)
    buildDropIndexes()
    local words = {}
    for word in itemKey:gmatch("%S+") do words[#words + 1] = word end
    -- the last word is the part itself (horn, claw, ring ...); a possessive
    -- ending (Korean "...의", English "...'s") is taken off the others
    local list, seen = {}, {}
    for i = 1, #words - 1 do
        local word = words[i]:gsub("\236\157\152$", ""):gsub("'s$", "")
        if usefulWord(word) then
            for last, bucket in pairs(npcByWord) do
                if last == word or (#last > #word and last:sub(-#word) == word) then
                    for _, e in ipairs(bucket) do
                        if not seen[e] then
                            seen[e] = true
                            list[#list + 1] = e
                        end
                    end
                end
            end
        end
    end
    if #list == 0 or #list > MAX_GUESS_ENTRIES then return nil end
    return list
end

-- quest ID -> the zone heading it sits under in the quest log
local function questZones()
    local zones = {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return zones end
    local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
    count = ok and tonumber(count) or 0
    local heading
    for i = 1, count do
        local okInfo, info = pcall(C_QuestLog.GetInfo, i)
        if okInfo and type(info) == "table" then
            if info.isHeader then
                heading = (type(info.title) == "string" and not isSecret(info.title)) and normalize(info.title) or nil
            elseif info.questID and not isSecret(info.questID) then
                zones[info.questID] = heading
            end
        end
    end
    return zones
end

local mapNameCache = {}
local function mapName(mapID)
    local cached = mapNameCache[mapID]
    if cached ~= nil then return cached end
    local name = false
    if C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and type(info) == "table" then name = normalize(info.name) or false end
    end
    mapNameCache[mapID] = name
    return name
end

-- guesses are kept only for creatures that live in the quest's own zone (a
-- quest under a class or profession heading gets no guesses)
local function entriesInZone(list, zone)
    local project = (type(ns.MapProjector) == "function" and ns.MapProjector()) or ns.ProjectSpawnToWorldMapCoords
    if not (list and zone and project) then return nil end
    local kept = {}
    for _, e in ipairs(list) do
        local n = math.min(#e.spawns, 20)
        for i = 1, n do
            local mapID = project(e.spawns[i], nil)
            if mapID and mapName(mapID) == zone then
                kept[#kept + 1] = e
                break
            end
        end
    end
    return #kept > 0 and kept or nil
end

-- guessed spots are only drawn on the map of the quest's zone
local function spotsAllowed(obj, mapID)
    if not obj.zoneOnly then return true end
    local name = mapName(mapID)
    return name and name == obj.zoneOnly or false
end

-----------------------------------------------------------------------------
-- Quests in progress and their objectives
-----------------------------------------------------------------------------
local quests = {}        -- current list: { id, title, color, objectives = { ... } }
local questByID = {}

local function readObjectives(questID)
    local list = {}
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local ok, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)
        if ok and type(objectives) == "table" then
            for _, o in ipairs(objectives) do
                if type(o) == "table" and type(o.text) == "string" and not isSecret(o.text) then
                    list[#list + 1] = {
                        text = o.text,
                        type = (type(o.type) == "string" and not isSecret(o.type)) and o.type or nil,
                        finished = o.finished == true,
                        numFulfilled = tonumber(o.numFulfilled),
                        numRequired = tonumber(o.numRequired),
                    }
                end
            end
            return list
        end
    end
    -- older clients: leader board text by quest log index
    if type(GetNumQuestLeaderBoards) == "function" and type(GetQuestLogLeaderBoard) == "function"
        and C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        local okIndex, logIndex = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
        if okIndex and type(logIndex) == "number" then
            local count = tonumber(GetNumQuestLeaderBoards(logIndex)) or 0
            for i = 1, count do
                local text, objType, finished = GetQuestLogLeaderBoard(i, logIndex)
                if type(text) == "string" and not isSecret(text) then
                    list[#list + 1] = { text = text, type = objType, finished = finished == true or finished == 1 }
                end
            end
        end
    end
    return list
end

local function questTitle(quest)
    local prefix = ns.QuestLevelPrefix and ns.QuestLevelPrefix(quest.id) or ""
    local title = quest.title
    if type(title) == "string" and title ~= "" and not isSecret(title) then return prefix .. title end
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, t = pcall(C_QuestLog.GetTitleForQuestID, quest.id)
        if ok and type(t) == "string" and t ~= "" and not isSecret(t) then return prefix .. t end
    end
    return prefix .. "#" .. tostring(quest.id)
end

-----------------------------------------------------------------------------
-- Quests whose objectives name nothing to look up ("pass the trial", "use it
-- there"): creatures and objects named in the quest text are shown instead,
-- each only on its own map.
-----------------------------------------------------------------------------
-- the places a quest is taken and turned in at: never shown as things to do
local function spotKeyOf(sp)
    return sp[1] .. ":" .. floor(sp[2]) .. ":" .. floor(sp[3])
end

local function questEndSpots(questID)
    local qlp = ns.QuestLogPins
    local spots = qlp and qlp.questSpots and qlp.questSpots(questID)
    local set = {}
    for _, sp in ipairs(spots or {}) do set[spotKeyOf(sp)] = true end
    return set
end

local function atQuestEnds(entry, ends)
    for _, sp in ipairs(entry.spawns) do
        if ends[spotKeyOf(sp)] then return true end
    end
    return false
end

local MENTION_MAX_NAMES = 6
local MENTION_MAX_SPAWNS = 12
local mentionCache = {}   -- quest ID -> list, or false when nothing was found

local function questText(questID)
    local parts = {}
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID and type(GetQuestLogQuestText) == "function" then
        local okIndex, logIndex = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
        if okIndex and type(logIndex) == "number" and not isSecret(logIndex) then
            local ok, desc, objText = pcall(GetQuestLogQuestText, logIndex)
            if ok then
                if type(desc) == "string" and not isSecret(desc) then parts[#parts + 1] = desc end
                if type(objText) == "string" and not isSecret(objText) then parts[#parts + 1] = objText end
            end
        end
    end
    if #parts == 0 then return nil end
    return normalize(table.concat(parts, " "))
end

-- short names ("bear", two Hangul letters) would match too much text
local function mentionNameOK(key)
    if key:find("[\128-\255]") then return #key >= 9 end
    return #key >= 5
end

local function mentionedObjectives(questID)
    local cached = mentionCache[questID]
    if cached ~= nil then return cached or nil end
    local text = questText(questID)
    if not text then return nil end   -- not loaded yet: try again next time
    QuestObjectivePins.buildNameIndex()
    local found = {}
    local ends = questEndSpots(questID)
    for _, kind in ipairs({ "npc", "object" }) do
        for key, list in pairs(nameIndex[kind]) do
            if mentionNameOK(key) then
                local pos = text:find(key, 1, true)
                if pos then
                    -- a name found in many places (a zone name on signs, a common
                    -- creature) says nothing about where to go: left out
                    local entries, total = {}, 0
                    for _, e in ipairs(list) do
                        total = total + #e.spawns
                        if not atQuestEnds(e, ends) then entries[#entries + 1] = e end
                    end
                    if #entries > 0 and total <= MENTION_MAX_SPAWNS then
                        found[#found + 1] = { key = key, pos = pos, entries = entries }
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b)
        if a.pos ~= b.pos then return a.pos < b.pos end
        return a.key < b.key
    end)
    local result = {}
    for _, f in ipairs(found) do
        -- a name that is part of a longer name also found is left out
        local inner = false
        for _, g in ipairs(found) do
            if g ~= f and #g.key > #f.key and g.key:find(f.key, 1, true) then
                inner = true
                break
            end
        end
        if not inner and #result < MENTION_MAX_NAMES then
            result[#result + 1] = {
                text = displayName[f.key] or f.key, type = "mention",
                entries = f.entries, guess = true, mention = true,
            }
        end
    end
    mentionCache[questID] = #result > 0 and result or false
    return #result > 0 and result or nil
end

-- Objective targets from the quest data, in the game's own order; nil when
-- the lists don't line up.
local function questDataTable()
    local qd = (type(ns.QuestData) == "function" and ns.QuestData()) or _G.EzWoWMapFinderQuestData
    return type(qd) == "table" and qd or nil
end

local function questDataObjectives(questID, count)
    local qd = questDataTable()
    local q = qd and type(qd.quests) == "table" and qd.quests[questID]
    local objs = type(q) == "table" and q.obj
    if type(objs) ~= "table" or #objs ~= count then return nil end
    return objs
end

local function entriesFromId(objType, id)
    if type(id) ~= "number" or id <= 0 then return nil end
    buildDropIndexes()
    if objType == "monster" then
        return npcById[id] and { npcById[id] } or nil
    elseif objType == "object" then
        return objectById[id] and { objectById[id] } or nil
    elseif objType == "item" then
        local list = {}
        if itemById[id] then list[1] = itemById[id] end
        local qd = questDataTable()
        local seen = {}
        local function addNpc(npcId)
            local e = npcById[npcId]
            if e and not seen[e] and #list < MAX_GUESS_ENTRIES then
                seen[e] = true
                list[#list + 1] = e
            end
        end
        local drops = qd and type(qd.itemDrops) == "table" and qd.itemDrops[id]
        if type(drops) == "table" then
            for _, npcId in ipairs(drops) do addNpc(npcId) end
        end
        -- objects the item is looted from (built-in data: object IDs)
        local objects = qd and type(qd.itemObjects) == "table" and qd.itemObjects[id]
        if type(objects) == "table" then
            for _, objectID in ipairs(objects) do
                local e = objectById[objectID]
                if e and not seen[e] and #list < MAX_GUESS_ENTRIES then
                    seen[e] = true
                    list[#list + 1] = e
                end
            end
        end
        -- learned by this character or confirmed by other players
        local idStore = itemDropStore()
        local learned = idStore and idStore[id]
        if type(learned) == "table" then
            for key, value in pairs(learned) do
                if type(key) == "number" then
                    addNpc(key)
                elseif type(key) == "string" and type(value) == "table" and type(value[1]) == "number" then
                    local objectID = tonumber(key:match("^o:(%d+)$"))
                    local known = objectID and objectById[objectID]
                    if #list < MAX_GUESS_ENTRIES then
                        list[#list + 1] = { id = objectID, kind = "object", names = known and known.names, spawns = objectSpots(value) }
                    end
                end
            end
        end
        return #list > 0 and list or nil
    end
    return nil
end

-- quest items already looted somewhere and named in the quest text
-- ("find the two halves of the pendant")
-- names (normalized) of the items in the bags
local function bagItemNames()
    local names = {}
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return names end
    local bags = { 0, 1, 2, 3, 4 }
    local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    if reagent then bags[#bags + 1] = reagent end
    for _, bag in ipairs(bags) do
        local okSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        for slot = 1, (okSlots and tonumber(slots)) or 0 do
            local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
            local link = ok and type(info) == "table" and info.hyperlink
            local name = type(link) == "string" and not isSecret(link) and link:match("%[(.-)%]")
            local key = name and normalize(name)
            if key then names[key] = true end
        end
    end
    return names
end

-- Returns the places for quest items named in the text that are still to get,
-- and how many named items are already in the bags.
local function learnedMentions(questID)
    local store = dropStore()
    if not store or not next(store) then return nil, 0 end
    local text = questText(questID)
    if not text then return nil, 0 end
    local result, have, inBags = nil, 0, nil
    for key in pairs(store) do
        if mentionNameOK(key) and text:find(key, 1, true) then
            inBags = inBags or bagItemNames()
            if inBags[key] then
                have = have + 1
            else
                local entries = learnedDropEntries(key)
                if entries then
                    result = result or {}
                    result[#result + 1] = { text = key, type = "mention", entries = entries, mention = true, learned = true }
                end
            end
        end
    end
    return result, have
end

-- Quests whose text only says "ask around": places to search, taken from the
-- built-in location data (object IDs; no positions are written here).
local SEA_LION = {
    -- agility half: lockboxes on Kalimdor (the Barrens, Darkshore)
    { item = 15883, objects = { 177794, 177792 } },
    -- endurance half: lockboxes in the Eastern Kingdoms (Silverpine coast, Westfall coast)
    { item = 15882, objects = { 177790, 177844 } },
}
local LAKE_TRIAL = {
    -- the shrine bauble: bauble containers at the bottom of the lake
    { objects = { 177785 } },
}
local QUEST_PLACE_HINTS = {
    [30] = SEA_LION, [272] = SEA_LION,
    [28] = LAKE_TRIAL, [29] = LAKE_TRIAL,
}

local function itemInBags(itemID)
    if not (itemID and C_Item and C_Item.GetItemCount) then return false end
    local ok, count = pcall(C_Item.GetItemCount, itemID)
    return ok and type(count) == "number" and not isSecret(count) and count > 0
end

-- places still worth searching: a place whose item is already in the bags is left out
local function placeHints(questID)
    local hint = QUEST_PLACE_HINTS[questID]
    if not hint then return nil end
    buildDropIndexes()
    local result
    for _, place in ipairs(hint) do
        if not itemInBags(place.item) then
            for _, id in ipairs(place.objects) do
                local e = objectById[id]
                if e then
                    local name = (ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(e)) or (e.names and e.names.enUS) or "?"
                    result = result or {}
                    result[#result + 1] = { text = name, type = "mention", entries = { e }, mention = true, noteKey = "questObjSearch" }
                end
            end
        end
    end
    return result
end

function QuestObjectivePins.rebuildQuests()
    quests, questByID = {}, {}
    if not enabled() then return end
    local collect = ns.QuestLogPins and ns.QuestLogPins.collectQuests
    if not collect then return end
    local okList, list = pcall(collect)
    if not okList or type(list) ~= "table" then return end
    local zones
    local colorIndex = 0
    for _, q in ipairs(list) do
        if not q.complete then
            colorIndex = colorIndex + 1
            local quest = {
                id = q.id,
                title = questTitle(q),
                color = COLOR_TITLE,
                dotColor = QUEST_COLORS[(colorIndex - 1) % #QUEST_COLORS + 1],
                objectives = readObjectives(q.id),
            }
            local dataObjs = questDataObjectives(q.id, #quest.objectives)
            local sources = ns.QuestSources
            for objIndex, obj in ipairs(quest.objectives) do
                local dataObj = dataObjs and dataObjs[objIndex]
                if not obj.finished and (obj.type == "monster" or obj.type == "object" or obj.type == "item") then
                    local byId = type(dataObj) == "table" and dataObj[1] == obj.type and entriesFromId(obj.type, dataObj[2]) or nil
                    obj.entries = byId or QuestObjectivePins.matchObjective(obj.type, obj.text)
                    if obj.type == "item" then
                        obj.itemKey = normalize(stripCounts(obj.text))
                        if type(dataObj) == "table" and dataObj[1] == "item" and type(dataObj[2]) == "number"
                            and dataObj[2] > 0 then
                            obj.itemID = dataObj[2]
                        end
                        local learned = obj.itemKey and learnedDropEntries(obj.itemKey)
                        -- no guessed spots (creatures named like the item): they were often wrong
                        if learned then
                            obj.entries = learned
                        end
                    end
                elseif not obj.finished and obj.type == "event" and sources then
                    local okEvent, spots = pcall(sources.eventEntries, q.id, objIndex)
                    if okEvent then obj.entries = spots end
                end
            end
            local pointed = false
            for _, obj in ipairs(quest.objectives) do
                if obj.entries and not obj.finished then
                    pointed = true
                    break
                end
            end
            if not pointed then
                local learned = learnedMentions(q.id)
                -- names picked out of the quest text are not used: their spots were often wrong
                for _, extra in ipairs({ learned or {}, placeHints(q.id) or {} }) do
                    for _, m in ipairs(extra) do quest.objectives[#quest.objectives + 1] = m end
                end
            end
            quests[#quests + 1] = quest
            questByID[quest.id] = quest
        end
    end
end

-- "Ragefire Trogg slain: 1/10" already carries the count; add it otherwise.
local function objectiveLine(obj)
    local text = obj.text or ""
    if obj.numRequired and obj.numRequired > 1 and not text:find("%d+%s*/%s*%d+") then
        text = text .. string.format(" (%d/%d)", obj.numFulfilled or 0, obj.numRequired)
    end
    return text
end

local function hexColor(c)
    return string.format("|cff%02x%02x%02x", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5))
end

-- tooltip: per quest its title, then the objectives that point at this spot
-- (or, for the quest area marker, every objective)
local function showGroupTooltip(owner, group, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    local first = true
    for _, item in ipairs(group.items) do
        local quest = item.quest
        -- the title takes the quest's dot colour, so dots and quest are easy to match
        local c = quest.dotColor or quest.color
        local r, g, b = c[1], c[2], c[3]
        if first then
            GameTooltip:SetText(quest.title, r, g, b)
            first = false
        else
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(quest.title, r, g, b)
        end
        local objs = item.objectives or quest.objectives
        for _, obj in ipairs(objs) do
            if obj.finished then
                GameTooltip:AddLine("  " .. objectiveLine(obj), 0.5, 0.5, 0.5, true)
            else
                GameTooltip:AddLine("  " .. objectiveLine(obj), 0.929, 0.957, 0.969, true)
                local note = item.objectives and ((obj.noteKey and ns:L(obj.noteKey))
                    or (obj.guess and ns:L(obj.mention and "questObjMention" or "questObjGuess")))
                if note then
                    GameTooltip:AddLine("    " .. note, unpack(Theme.muted))
                end
            end
        end
    end
    if group.isArea then
        GameTooltip:AddLine(ns:L("questObjArea"), unpack(Theme.muted))
    end
    if group.spawn or group.mapPoint then
        GameTooltip:AddLine(ns:L("questObjHint"), unpack(Theme.muted))
    end
    GameTooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
    GameTooltip:Show()
    if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
end

local function setWaypointAt(mapID, x, y)
    if not ns.IsAutoWaypoint() then return end
    if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then return end
    pcall(function()
        if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then return end
        local point = UiMapPoint.CreateFromCoordinates(mapID, x, y)
        if point then
            C_Map.SetUserWaypoint(point)
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end
    end)
end

local function onPinClick(self)
    local group = self.group
    if not group then return end
    if group.mapPoint then
        setWaypointAt(group.mapPoint[1], group.mapPoint[2], group.mapPoint[3])
    elseif group.spawn then
        ns.ApplyWaypointForSpawn(group.spawn)
    end
end

-----------------------------------------------------------------------------
-- World Map
-----------------------------------------------------------------------------
local dotPins, areaPins = {}, {}

local function canvas()
    return (WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas())
        or (_G.EzWoWWorldMapDock and _G.EzWoWWorldMapDock:GetCanvas())
        or WorldMapFrame
end

local function newDisc(parent, layer, sublevel, size)
    local tex = parent:CreateTexture(nil, layer, nil, sublevel)
    tex:SetTexture(DISC)
    tex:SetSize(size, size)
    tex:SetPoint("CENTER")
    return tex
end

local function obtainDot(index)
    local pin = dotPins[index]
    if pin then return pin end
    pin = CreateFrame("Button", nil, canvas())
    pin:EnableMouse(true)
    pin:RegisterForClicks("LeftButtonUp")
    setPropagateClicks(pin, false)
    pin:SetSize(DOT_SIZE, DOT_SIZE)
    pin:SetFrameStrata("HIGH")
    pin.border = newDisc(pin, "ARTWORK", 1, DOT_SIZE)
    pin.border:SetVertexColor(0, 0, 0, 0.95)
    pin.fill = newDisc(pin, "ARTWORK", 2, DOT_SIZE - 3)
    pin:SetScript("OnEnter", function(self) if self.group then showGroupTooltip(self, self.group) end end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:HookScript("OnEnter", raisePin)
    pin:HookScript("OnLeave", lowerPin)
    pin:SetScript("OnClick", onPinClick)
    ns.PassMapRightClicks(pin)
    dotPins[index] = pin
    return pin
end

local function obtainArea(index)
    local pin = areaPins[index]
    if pin then return pin end
    pin = CreateFrame("Button", nil, canvas())
    pin:EnableMouse(true)
    pin:RegisterForClicks("LeftButtonUp")
    setPropagateClicks(pin, false)
    pin:SetSize(AREA_SIZE, AREA_SIZE)
    pin:SetFrameStrata("HIGH")
    pin.shadow = newDisc(pin, "ARTWORK", 0, AREA_SIZE)
    pin.shadow:SetVertexColor(0, 0, 0, 0.7)
    -- the "fill" is the gold ring; a dark disc on top leaves only its edge
    pin.fill = newDisc(pin, "ARTWORK", 1, AREA_SIZE - 2)
    pin.core = newDisc(pin, "ARTWORK", 2, AREA_SIZE - 7)
    pin.core:SetVertexColor(0.05, 0.05, 0.05, 0.75)
    pin:SetAlpha(0.85)
    pin:SetScript("OnEnter", function(self) if self.group then showGroupTooltip(self, self.group) end end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:HookScript("OnEnter", raisePin)
    pin:HookScript("OnLeave", lowerPin)
    pin:SetScript("OnClick", onPinClick)
    ns.PassMapRightClicks(pin)
    areaPins[index] = pin
    return pin
end

-----------------------------------------------------------------------------
-- Net: spots of one objective that lie close together are joined by thin
-- lines (each spot to its two nearest neighbours), so a spread-out hunting
-- ground reads as one area instead of loose dots.
-----------------------------------------------------------------------------
local NET_RADIUS = 70        -- screen pixels: spots closer than this are joined
local NET_NEIGHBOURS = 2
local MAX_NET_LINES = 1200
local netFrame
local netLines = {}

local function hideNets()
    for _, line in ipairs(netLines) do line:Hide() end
end

local function drawNets(groups, canvasFrame, cScale, baseLevel)
    if not netFrame then
        netFrame = CreateFrame("Frame", nil, canvasFrame)
        netFrame:EnableMouse(false)
    end
    netFrame:SetParent(canvasFrame)
    netFrame:ClearAllPoints()
    netFrame:SetAllPoints(canvasFrame)
    netFrame:SetFrameStrata("HIGH")
    netFrame:SetFrameLevel(baseLevel + 140)
    netFrame:Show()
    -- one net per quest and objective kind
    local sets, order = {}, {}
    for _, g in ipairs(groups) do
        local key = tostring(g.items[1].quest.id) .. ":" .. tostring(g.color)
        if not sets[key] then
            sets[key] = {}
            order[#order + 1] = key
        end
        local list = sets[key]
        list[#list + 1] = g
    end
    local used = 0
    local radius = NET_RADIUS / cScale
    local r2 = radius * radius
    local thickness = 1.2 / cScale
    for _, key in ipairs(order) do
        local pts = sets[key]
        local n = #pts
        if n >= 2 then
            local edges = {}
            for i = 1, n do
                local a = pts[i]
                local near = {}
                for j = 1, n do
                    if j ~= i then
                        local b = pts[j]
                        local dx, dy = a.px - b.px, a.py - b.py
                        local d = dx * dx + dy * dy
                        if d <= r2 then near[#near + 1] = { j = j, d = d } end
                    end
                end
                table.sort(near, function(x, y) return x.d < y.d end)
                for k = 1, math.min(NET_NEIGHBOURS, #near) do
                    local j = near[k].j
                    local lo, hi = math.min(i, j), math.max(i, j)
                    local edgeKey = lo * 100000 + hi
                    if not edges[edgeKey] and used < MAX_NET_LINES then
                        edges[edgeKey] = true
                        used = used + 1
                        local line = netLines[used]
                        if not line then
                            line = netFrame:CreateLine(nil, "ARTWORK")
                            netLines[used] = line
                        end
                        local c = a.color
                        line:SetColorTexture(c[1], c[2], c[3], 0.45)
                        line:SetThickness(thickness)
                        line:SetStartPoint("TOPLEFT", netFrame, a.px, -a.py)
                        line:SetEndPoint("TOPLEFT", netFrame, pts[j].px, -pts[j].py)
                        line:Show()
                    end
                end
            end
        end
    end
    for i = used + 1, #netLines do netLines[i]:Hide() end
end

function QuestObjectivePins.hideWorld()
    for _, pin in ipairs(dotPins) do pin:Hide() end
    for _, pin in ipairs(areaPins) do pin:Hide() end
    hideNets()
end

-- Objective dots are only drawn on zone-sized maps (not on continents).
local function isDetailMap(mapID)
    if not (C_Map and C_Map.GetMapInfo) then return true end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if not ok or type(info) ~= "table" or type(info.mapType) ~= "number" then return true end
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    return info.mapType >= zoneType
end

local function anchorPin(pin, canvasFrame, cw, ch, cScale)
    local group = pin.group
    local pinScale = zoomGrow(cScale) / cScale
    local px = group.px * (cw / (group.cw or cw))
    local py = group.py * (ch / (group.ch or ch))
    pin:SetScale(pinScale)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", canvasFrame, "TOPLEFT", px / pinScale, -py / pinScale)
end

-- Spots of one objective entry on the given map (normalized coordinates).
-- ownZoneOnly: skip spots whose own zone is another map (a zone map also shows
-- the edges of its neighbours); used for guessed drop creatures
local function eachSpot(entries, mapID, project, fn, ownZoneOnly)
    for _, entry in ipairs(entries) do
        local spawns = entry.spawns
        local n = #spawns
        if n > MAX_SPAWNS_PER_ENTRY then n = MAX_SPAWNS_PER_ENTRY end
        for i = 1, n do
            local sp = spawns[i]
            local mapID2, mx, my = project(sp, mapID)
            if mx and my and mapID2 == mapID then
                if not ownZoneOnly or project(sp) == mapID then fn(mx, my, sp, entry) end
            end
        end
    end
end

function QuestObjectivePins.refreshWorld()
    QuestObjectivePins.hideWorld()
    if not enabled() or #quests == 0 then return end
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    local project = ns.MapProjector()
    local mapID = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    if not mapID or isSecret(mapID) then return end
    local canvasFrame = canvas()
    local cw, ch = canvasFrame:GetWidth(), canvasFrame:GetHeight()
    if not cw or not ch or cw <= 0 or ch <= 0 then return end
    local cScale = (WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale()) or 1
    if not cScale or cScale <= 0 then cScale = 1 end
    local baseLevel = canvasFrame:GetFrameLevel() or 10

    -- 1) objective dots, merged per quest when closer than a few pixels
    local dotCount = 0
    local withDots = {}
    if project and isDetailMap(mapID) then
        local groups, cells = {}, {}
        for _, quest in ipairs(quests) do
            for _, obj in ipairs(quest.objectives) do
                if obj.entries and not obj.finished and spotsAllowed(obj, mapID) then
                    eachSpot(obj.entries, mapID, project, function(mx, my, sp)
                        local px, py = mx * cw, my * ch
                        local cx = floor(px * cScale / MERGE_PIXELS)
                        local cy = floor(py * cScale / MERGE_PIXELS)
                        local key = quest.id .. ":" .. cx .. ":" .. cy
                        local group = cells[key]
                        if not group then
                            if #groups >= MAX_WORLD_DOTS then return end
                            group = { px = px, py = py, cw = cw, ch = ch, spawn = sp, color = objectiveColor(obj, quest),
                                items = { { quest = quest, objectives = {} } }, seen = {} }
                            cells[key] = group
                            groups[#groups + 1] = group
                        end
                        if not group.seen[obj] then
                            group.seen[obj] = true
                            local objs = group.items[1].objectives
                            objs[#objs + 1] = obj
                        end
                    end, obj.guess)
                end
            end
        end
        for _, group in ipairs(groups) do
            withDots[group.items[1].quest.id] = true
        end
        for index, group in ipairs(groups) do
            local pin = obtainDot(index)
            pin:SetParent(canvasFrame)
            pin:SetFrameLevel(baseLevel + 150)
            pin.group = group
            pin.fill:SetVertexColor(group.color[1], group.color[2], group.color[3], 1)
            anchorPin(pin, canvasFrame, cw, ch, cScale)
            pin:Show()
        end
        drawNets(groups, canvasFrame, cScale, baseLevel)
        dotCount = #groups
    end

    -- 2) the game's own position for each quest on this map
    local areaCount = 0
    if engineRingsOn() and C_QuestLog and C_QuestLog.GetQuestsOnMap then
        local ok, onMap = pcall(C_QuestLog.GetQuestsOnMap, mapID)
        if ok and type(onMap) == "table" then
            local shown = {}
            for _, info in ipairs(onMap) do
                local qid, x, y = info.questID, info.x, info.y
                if type(qid) == "number" and type(x) == "number" and type(y) == "number"
                    and not isSecret(qid) and not isSecret(x) and not isSecret(y)
                    and questByID[qid] and not shown[qid] and not withDots[qid]
                    and x >= 0 and x <= 1 and y >= 0 and y <= 1 and ringPlaceOK(mapID, x, y) then
                    shown[qid] = true
                    areaCount = areaCount + 1
                    local quest = questByID[qid]
                    local group = { px = x * cw, py = y * ch, cw = cw, ch = ch, isArea = true,
                        mapPoint = { mapID, x, y }, items = { { quest = quest } } }
                    local pin = obtainArea(areaCount)
                    pin:SetParent(canvasFrame)
                    pin:SetFrameLevel(baseLevel + 170)
                    pin.group = group
                    pin.fill:SetVertexColor(quest.color[1], quest.color[2], quest.color[3], 1)
                    anchorPin(pin, canvasFrame, cw, ch, cScale)
                    pin:Show()
                end
            end
        end
    end
    return dotCount + areaCount
end

-- zoom: move the marks at once, regroup once zooming has stopped
local regroupPending, lastRescaleAt = false, 0
local REGROUP_DELAY = 0.3

local function regroupWhenSettled()
    local waited = GetTime() - lastRescaleAt
    if waited < REGROUP_DELAY then
        C_Timer.After(REGROUP_DELAY - waited, regroupWhenSettled)
        return
    end
    regroupPending = false
    QuestObjectivePins.refreshWorld()
end

function QuestObjectivePins.rescaleWorld()
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    local canvasFrame = canvas()
    local cw, ch = canvasFrame:GetWidth(), canvasFrame:GetHeight()
    if not cw or not ch or cw <= 0 or ch <= 0 then return end
    local cScale = (WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale()) or 1
    if not cScale or cScale <= 0 then cScale = 1 end
    local any = false
    for _, list in ipairs({ dotPins, areaPins }) do
        for _, pin in ipairs(list) do
            if pin:IsShown() and pin.group then
                anchorPin(pin, canvasFrame, cw, ch, cScale)
                any = true
            end
        end
    end
    if not any then return end
    lastRescaleAt = GetTime()
    if not regroupPending and C_Timer and C_Timer.After then
        regroupPending = true
        C_Timer.After(REGROUP_DELAY, regroupWhenSettled)
    end
end

-----------------------------------------------------------------------------
-- Minimap: dots of the player's current zone that fall inside the minimap
-----------------------------------------------------------------------------
local miniPins = {}
local miniPoints = {}   -- { x, y, group } in coordinates of miniMapID
local miniMapID
local miniDriver
local miniElapsed = 0

-- outdoor / indoor view radius in yards by minimap zoom level (0-5)
local OUTDOOR_RADIUS = { [0] = 233.33, 200, 166.67, 133.33, 100, 66.67 }
local INDOOR_RADIUS = { [0] = 150, 120, 90, 60, 40, 25 }

local function minimapRadiusYards()
    if C_Minimap and C_Minimap.GetViewRadius then
        local ok, r = pcall(C_Minimap.GetViewRadius)
        if ok and type(r) == "number" and not isSecret(r) and r > 0 then return r end
    end
    if not (Minimap and Minimap.GetZoom) then return nil end
    local zoom = Minimap:GetZoom()
    if type(zoom) ~= "number" or isSecret(zoom) then return nil end
    local indoors = type(IsIndoors) == "function" and IsIndoors() == true
    return (indoors and INDOOR_RADIUS or OUTDOOR_RADIUS)[zoom]
end

local function hideMinimap()
    for _, pin in ipairs(miniPins) do pin:Hide() end
end

local function obtainMiniPin(index)
    local pin = miniPins[index]
    if pin then return pin end
    pin = CreateFrame("Frame", nil, Minimap)
    pin:SetSize(MINIMAP_DOT_SIZE, MINIMAP_DOT_SIZE)
    pin:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 5)
    pin.border = newDisc(pin, "ARTWORK", 1, MINIMAP_DOT_SIZE)
    pin.border:SetVertexColor(0, 0, 0, 0.95)
    pin.fill = newDisc(pin, "ARTWORK", 2, MINIMAP_DOT_SIZE - 2)
    pin:EnableMouse(true)
    setPropagateClicks(pin, true)
    pin:SetScript("OnEnter", function(self) if self.group then showGroupTooltip(self, self.group, "ANCHOR_LEFT") end end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:HookScript("OnEnter", raisePin)
    pin:HookScript("OnLeave", lowerPin)
    miniPins[index] = pin
    return pin
end

local function playerMapPosition(mapID)
    if not (C_Map and C_Map.GetPlayerMapPosition) then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or not pos or not pos.GetXY then return nil end
    local x, y = pos:GetXY()
    if type(x) ~= "number" or type(y) ~= "number" or isSecret(x) or isSecret(y) then return nil end
    if x == 0 and y == 0 then return nil end
    return x, y
end

function QuestObjectivePins.updateMinimap()
    if not (Minimap and miniMapID and #miniPoints > 0 and enabled()) then hideMinimap() return end
    local px, py = playerMapPosition(miniMapID)
    local radius = minimapRadiusYards()
    local okSize, mapW, mapH = false, nil, nil
    if C_Map and C_Map.GetMapWorldSize then okSize, mapW, mapH = pcall(C_Map.GetMapWorldSize, miniMapID) end
    if not (px and radius and okSize and type(mapW) == "number" and type(mapH) == "number"
        and not isSecret(mapW) and not isSecret(mapH) and mapW > 0 and mapH > 0) then
        hideMinimap()
        return
    end
    local getCVar = (C_CVar and C_CVar.GetCVar) or (type(GetCVar) == "function" and GetCVar) or nil
    local okCVar, rotateValue = false, nil
    if getCVar then okCVar, rotateValue = pcall(getCVar, "rotateMinimap") end
    local rotate = okCVar and rotateValue == "1"
    local facing = 0
    if rotate then
        facing = type(GetPlayerFacing) == "function" and GetPlayerFacing() or nil
        if type(facing) ~= "number" or isSecret(facing) then hideMinimap() return end
    end
    local cf, sf = cos(facing), sin(facing)
    local halfW = (Minimap:GetWidth() or 0) / 2
    if halfW <= 0 then hideMinimap() return end
    local scale = halfW / radius
    local limit = radius * 0.94
    local placed = {}
    local count = 0
    for _, p in ipairs(miniPoints) do
        local east = (p.x - px) * mapW
        local north = -(p.y - py) * mapH
        if abs(east) <= limit and abs(north) <= limit and sqrt(east * east + north * north) <= limit then
            local ex, ny = east, north
            if rotate then
                ex = east * cf + north * sf
                ny = -east * sf + north * cf
            end
            local sx, sy = ex * scale, ny * scale
            local key = floor(sx / MINIMAP_MERGE) .. ":" .. floor(sy / MINIMAP_MERGE) .. ":" .. tostring(p.group.items[1].quest.id)
            if not placed[key] and count < MAX_MINIMAP_DOTS then
                placed[key] = true
                count = count + 1
                local pin = obtainMiniPin(count)
                pin.group = p.group
                local c = p.color
                pin.fill:SetVertexColor(c[1], c[2], c[3], 1)
                local size = p.group.isArea and (MINIMAP_DOT_SIZE + 4) or MINIMAP_DOT_SIZE
                pin:SetSize(size, size)
                pin.border:SetSize(size, size)
                pin.fill:SetSize(size - 2, size - 2)
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
                pin:Show()
            end
        end
    end
    for i = count + 1, #miniPins do miniPins[i]:Hide() end
end

function QuestObjectivePins.rebuildMinimapPoints()
    miniPoints = {}
    miniMapID = nil
    if not enabled() or #quests == 0 or not Minimap then
        hideMinimap()
        if miniDriver then miniDriver:Hide() end
        return
    end
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if type(mapID) ~= "number" or isSecret(mapID) then
        hideMinimap()
        if miniDriver then miniDriver:Hide() end
        return
    end
    miniMapID = mapID
    local miniWithDots = {}
    local project = ns.MapProjector()
    if project then
        for _, quest in ipairs(quests) do
            for _, obj in ipairs(quest.objectives) do
                if obj.entries and not obj.finished and spotsAllowed(obj, mapID) then
                    local color = objectiveColor(obj, quest)
                    local group = { color = color, items = { { quest = quest, objectives = { obj } } } }
                    eachSpot(obj.entries, mapID, project, function(mx, my)
                        miniPoints[#miniPoints + 1] = { x = mx, y = my, color = color, group = group }
                        miniWithDots[quest.id] = true
                    end, obj.guess)
                end
            end
        end
    end
    if engineRingsOn() and C_QuestLog and C_QuestLog.GetQuestsOnMap then
        local ok, onMap = pcall(C_QuestLog.GetQuestsOnMap, mapID)
        if ok and type(onMap) == "table" then
            for _, info in ipairs(onMap) do
                local qid, x, y = info.questID, info.x, info.y
                if type(qid) == "number" and type(x) == "number" and type(y) == "number"
                    and not isSecret(qid) and not isSecret(x) and not isSecret(y) and questByID[qid]
                    and not miniWithDots[qid] and ringPlaceOK(mapID, x, y) then
                    local quest = questByID[qid]
                    miniPoints[#miniPoints + 1] = { x = x, y = y, color = quest.color,
                        group = { isArea = true, items = { { quest = quest } } } }
                end
            end
        end
    end
    if #miniPoints == 0 then
        hideMinimap()
        if miniDriver then miniDriver:Hide() end
        return
    end
    if not miniDriver then
        miniDriver = CreateFrame("Frame")
        miniDriver:SetScript("OnUpdate", function(_, elapsed)
            miniElapsed = miniElapsed + (elapsed or 0)
            if miniElapsed < 0.1 then return end
            miniElapsed = 0
            local ok, err = pcall(QuestObjectivePins.updateMinimap)
            if not ok then
                hideMinimap()
                miniDriver:Hide()
                local handler = geterrorhandler and geterrorhandler()
                if handler then handler(err) end
            end
        end)
    end
    miniDriver:Show()
    QuestObjectivePins.updateMinimap()
end

-----------------------------------------------------------------------------
-- Refresh
-----------------------------------------------------------------------------
function QuestObjectivePins.refreshAll()
    QuestObjectivePins.rebuildQuests()
    QuestObjectivePins.refreshWorld()
    QuestObjectivePins.rebuildMinimapPoints()
end

local queued = false
local function queueRefresh()
    if queued or not (C_Timer and C_Timer.After) then return end
    queued = true
    C_Timer.After(0.3, function()
        queued = false
        QuestObjectivePins.refreshAll()
    end)
end

local mapHooked = false
-- Clicking a quest in the game's own quest list on the World Map guides to it
-- as well (after the game has handled the click).
local questLogHooked = false
local function guideFromQuestLog(questID)
    if not enabled() then return end
    questID = tonumber(questID)
    if not questID or isSecret(questID) or not QuestObjectivePins.guideTo then return end
    local now = GetTime and GetTime() or 0
    if QuestObjectivePins.lastGuideID == questID and now - (QuestObjectivePins.lastGuideAt or 0) < 0.5 then return end
    -- one click reaches more than one hook in the same moment: only the first counts
    QuestObjectivePins.lastGuideID, QuestObjectivePins.lastGuideAt = questID, now
    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function() pcall(QuestObjectivePins.guideTo, questID) end)
    else
        pcall(QuestObjectivePins.guideTo, questID)
    end
end

QuestObjectivePins.requestGuide = guideFromQuestLog

local function installQuestLogHooks()
    if questLogHooked then return end
    if type(QuestMapFrame_ShowQuestDetails) == "function" then
        -- only a click in the list itself (the game also opens details on its own)
        hooksecurefunc("QuestMapFrame_ShowQuestDetails", function(questID)
            -- only while the World Map is open (the game also opens quest
            -- details on its own); repeated calls are merged in guideFromQuestLog
            if WorldMapFrame and WorldMapFrame:IsShown() then guideFromQuestLog(questID) end
        end)
        questLogHooked = true
    end
    if type(QuestMapLogTitleButton_OnClick) == "function" then
        hooksecurefunc("QuestMapLogTitleButton_OnClick", function(self, button)
            if button == "LeftButton" and self and not (IsModifiedClick and IsModifiedClick()) then
                guideFromQuestLog(self.questID)
            end
        end)
        questLogHooked = true
    end
end

local function installMapHooks()
    installQuestLogHooks()
    if mapHooked or not WorldMapFrame then return end
    mapHooked = true
    local function onMapChanged()
        QuestObjectivePins.refreshWorld()
        if ns.RefreshQuestLogPins then ns.RefreshQuestLogPins() end
    end
    local function onScale()
        QuestObjectivePins.rescaleWorld()
        if ns.RescaleQuestLogPins then ns.RescaleQuestLogPins() end
    end
    do
        if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", onMapChanged) end
        if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", onScale) end
    end
    WorldMapFrame:HookScript("OnShow", onMapChanged)
    WorldMapFrame:HookScript("OnSizeChanged", onMapChanged)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE",
    "QUEST_ACCEPTED", "QUEST_REMOVED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "LOOT_OPENED",
    "BAG_UPDATE_DELAYED" }) do
    pcall(events.RegisterEvent, events, event)
end
-- Looting a quest item: remember which creatures it came from.
-- where the player stands: { continent, x, y } like the spots in the data
local function lootPosition()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then return nil end
    local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or type(mapID) ~= "number" or isSecret(mapID) then return nil end
    local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not okPos or not pos then return nil end
    local okWorld, continent, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
    if not okWorld or type(continent) ~= "number" or type(world) ~= "table" then return nil end
    local x, y = world.x, world.y
    if type(x) ~= "number" or type(y) ~= "number" or isSecret(x) or isSecret(y) then return nil end
    return { continent, math.floor(x * 10 + 0.5) / 10, math.floor(y * 10 + 0.5) / 10 }
end

local function learnFromLoot()
    if not (GetNumLootItems and GetLootSlotLink and GetLootSourceInfo) then return end
    local wanted = {}
    for _, quest in ipairs(quests) do
        for _, obj in ipairs(quest.objectives) do
            if obj.type == "item" and obj.itemKey then wanted[obj.itemKey] = true end
        end
    end
    local store = dropStore()
    if not store then return end
    local byItem = itemDropStore()
    local learnedAny = false
    -- one record: by the item's name (shown on the map) and by its ID (kept
    -- for the built-in data, the same in every client language).
    -- npcs: true = learned here ("s": confirmed by other players);
    -- objects: the spot where it was looted
    local function remember(key, itemID, id, value)
        for _, set in ipairs({ { store, key }, { byItem, itemID } }) do
            local tbl, k = set[1], set[2]
            if tbl and k then
                tbl[k] = tbl[k] or {}
                local current = tbl[k][id]
                if value == true and current ~= true then
                    tbl[k][id] = true
                    learnedAny = true
                elseif type(value) == "table" and (type(current) ~= "table" or current.shared) then
                    -- other places players reported for this object are kept
                    tbl[k][id] = { value[1], value[2], value[3], more = type(current) == "table" and current.more or nil }
                    learnedAny = true
                end
            end
        end
    end
    local okCount, count = pcall(GetNumLootItems)
    count = okCount and tonumber(count) or 0
    for slot = 1, count do
        local okLink, link = pcall(GetLootSlotLink, slot)
        link = okLink and type(link) == "string" and not isSecret(link) and link or nil
        local name = link and link:match("%[(.-)%]")
        local key = name and normalize(name)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        local okInfo, _, _, _, _, _, _, isQuestItem = pcall(GetLootSlotInfo, slot)
        local questItem = okInfo and isQuestItem == true
        if key and (wanted[key] or questItem) then
            local sources = { pcall(GetLootSourceInfo, slot) }
            if sources[1] then
                for i = 2, #sources, 2 do
                    local guid = sources[i]
                    if type(guid) == "string" and not isSecret(guid) then
                        local unitType, _, _, _, _, npcId = strsplit("-", guid)
                        npcId = tonumber(npcId)
                        if (unitType == "Creature" or unitType == "Vehicle") and npcId then
                            remember(key, itemID, npcId, true)
                        elseif unitType == "GameObject" and npcId then
                            local spot = lootPosition()
                            if spot then remember(key, itemID, "o:" .. npcId, spot) end
                        end
                    end
                end
            end
        end
    end
    if learnedAny then queueRefresh() end
end

-- Hovering a creature: the game adds the quest items it can drop to its
-- tooltip ("Intact Raptor Horn 0/5"). Such a line marks that creature as a
-- source of the item. Only read, never changed; only the main tooltip.
local function npcIdFromGuid(guid)
    if type(guid) ~= "string" or isSecret(guid) then return nil end
    local unitType, _, _, _, _, npcId = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return nil end
    return tonumber(npcId)
end

local function learnFromUnitTooltip(tooltip, data)
    if tooltip ~= GameTooltip or type(data) ~= "table" or type(data.lines) ~= "table" then return end
    local npcId = npcIdFromGuid(data.guid)
    if not npcId then return end
    local wanted
    for _, quest in ipairs(quests) do
        for _, obj in ipairs(quest.objectives) do
            if obj.type == "item" and obj.itemKey and not obj.finished then
                wanted = wanted or {}
                -- the item's ID when the quest data knows it, else true
                wanted[obj.itemKey] = obj.itemID or wanted[obj.itemKey] or true
            end
        end
    end
    if not wanted then return end
    local store = dropStore()
    if not store then return end
    local byItem = itemDropStore()
    for i = 2, #data.lines do
        local text = data.lines[i] and data.lines[i].leftText
        if type(text) == "string" and not isSecret(text) then
            local key = normalize(stripCounts(text:gsub("^%s*%-%s*", "")))
            if key and wanted[key] then
                store[key] = store[key] or {}
                local learned = false
                if store[key][npcId] ~= true then
                    store[key][npcId] = true
                    learned = true
                end
                -- also by item ID (built-in data and players of other languages)
                local itemID = wanted[key]
                if byItem and type(itemID) == "number" then
                    byItem[itemID] = byItem[itemID] or {}
                    if byItem[itemID][npcId] ~= true then
                        byItem[itemID][npcId] = true
                        learned = true
                    end
                end
                if learned then queueRefresh() end
            end
        end
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Unit then
    pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tooltip, data)
        pcall(learnFromUnitTooltip, tooltip, data)
    end)
end

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "LOOT_OPENED" then
        pcall(learnFromLoot)
        return
    end
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_WorldMap" then installMapHooks() end
        return
    end
    if event == "PLAYER_LOGIN" then installMapHooks() end
    queueRefresh()
end)

-- options window toggle
function QuestObjectivePins.setEnabled()
    QuestObjectivePins.refreshAll()
end

-----------------------------------------------------------------------------
-- Guide to a quest: a waypoint (with the game's arrow) on the nearest place to
-- go - an objective spot while the quest is in progress, the turn-in spot
-- once it is complete. Returns true when a spot was found.
-----------------------------------------------------------------------------
local function playerWorldPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then
        return nil
    end
    local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or type(mapID) ~= "number" or isSecret(mapID) then return nil end
    local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not okPos or not pos then return nil end
    local okWorld, continent, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
    if not okWorld or type(continent) ~= "number" or type(world) ~= "table" then return nil end
    local x, y = world.x, world.y
    if type(x) ~= "number" or type(y) ~= "number" or isSecret(x) or isSecret(y) then return nil end
    return continent, x, y
end

local function nearestSpot(spots, continent, px, py)
    local best, bestD
    for _, cand in ipairs(spots) do
        local sp = cand[1]
        local d = math.huge   -- another continent: only when nothing nearer
        if continent and sp[1] == continent then
            local dx, dy = sp[2] - px, sp[3] - py
            d = dx * dx + dy * dy
        end
        if not best or d < bestD then best, bestD = cand, d end
    end
    return best
end

-- The game's own point for a quest: its next waypoint, or the quest's spot on
-- the quest's own map. Returns uiMapID, x, y (0..1) or nil.
local function engineQuestPoint(questID)
    if not C_QuestLog then return nil end
    if C_QuestLog.GetNextWaypoint then
        local ok, mapID, x, y = pcall(C_QuestLog.GetNextWaypoint, questID)
        if ok and type(mapID) == "number" and type(x) == "number" and type(y) == "number"
            and not isSecret(mapID) and not isSecret(x) and not isSecret(y) and mapID > 0 then
            return mapID, x, y
        end
    end
    local mapID
    if type(GetQuestUiMapID) == "function" then
        local ok, m = pcall(GetQuestUiMapID, questID)
        if ok and type(m) == "number" and not isSecret(m) and m > 0 then mapID = m end
    end
    if mapID and C_QuestLog.GetQuestsOnMap then
        local ok, onMap = pcall(C_QuestLog.GetQuestsOnMap, mapID)
        if ok and type(onMap) == "table" then
            for _, info in ipairs(onMap) do
                if type(info) == "table" and info.questID == questID and type(info.x) == "number" and type(info.y) == "number"
                    and not isSecret(info.x) and not isSecret(info.y) then
                    return mapID, info.x, info.y
                end
            end
        end
    end
    return nil
end

local function guideText(key)
    if type(ns.L) == "function" then return ns:L(key) end
    return type(ns.L) == "table" and ns.L[key] or nil
end

local function guideSay(text)
    if DEFAULT_CHAT_FRAME and text then
        DEFAULT_CHAT_FRAME:AddMessage("|cff4bc8e8EzWoW - Quest|r: " .. text)
    end
end

function QuestObjectivePins.guideTo(questID)
    questID = tonumber(questID)
    if not questID then return false end
    QuestObjectivePins.lastGuideID = questID
    QuestObjectivePins.lastGuideAt = GetTime and GetTime() or 0
    local qlp = ns.QuestLogPins
    local spots = {}   -- { spawn, entry, index }
    local onlyMentions = false
    if qlp and qlp.isQuestComplete and qlp.isQuestComplete(questID) then
        local turnIn = qlp.turnInSpotsForQuest and qlp.turnInSpotsForQuest(questID)
        if turnIn and #turnIn > 0 then
            local qe = qlp.questEntry and qlp.questEntry(questID)
            local shown = { id = questID, kind = "quest", names = qe and qe.names, spawns = turnIn }
            for i, sp in ipairs(turnIn) do spots[#spots + 1] = { sp, shown, i } end
        end
    else
        if not questByID[questID] then QuestObjectivePins.rebuildQuests() end
        local quest = questByID[questID]
        -- real objective targets first, then places to search, and the places
        -- only named in the quest text last
        local tiers = { {}, {}, {} }
        for _, obj in ipairs(quest and quest.objectives or {}) do
            if obj.entries and not obj.finished then
                local tier = 1
                if obj.mention then tier = (obj.learned or obj.noteKey) and 2 or 3 end
                local list = tiers[tier]
                local project = obj.zoneOnly
                    and ((type(ns.MapProjector) == "function" and ns.MapProjector()) or ns.ProjectSpawnToWorldMapCoords)
                for _, e in ipairs(obj.entries) do
                    local n = math.min(#e.spawns, MAX_SPAWNS_PER_ENTRY)
                    for i = 1, n do
                        -- guesses only inside the quest's own zone, as on the map
                        local ok = true
                        if obj.zoneOnly then
                            local mapID = project and project(e.spawns[i], nil)
                            ok = mapID and mapName(mapID) == obj.zoneOnly or false
                        end
                        if ok then list[#list + 1] = { e.spawns[i], e, i } end
                    end
                end
            end
        end
        for tier, list in ipairs(tiers) do
            if #list > 0 then
                spots = list
                onlyMentions = tier == 3
                break
            end
        end
    end
    -- only places named in the text, or nothing: the game's own position for
    -- the quest comes first
    if #spots == 0 or onlyMentions then
        local mapID, x, y = engineQuestPoint(questID)
        if mapID then
            local sp = { -1, mapID, x, y }
            local qe = qlp and qlp.questEntry and qlp.questEntry(questID)
            spots = { { sp, { id = questID, kind = "quest", names = qe and qe.names, spawns = { sp } }, 1 } }
        end
    end
    local continent, px, py = playerWorldPos()
    local best = nearestSpot(spots, continent, px, py)
    local api = _G.EzWoWMapFinderAPI
    local project = ns.MapProjector and ns.MapProjector() or ns.ProjectSpawnToWorldMapCoords
    local title = (questByID[questID] and questByID[questID].title)
        or (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)) or ("#" .. questID)
    if not best then
        guideSay(string.format(guideText("questGuideNone") or "%s: ?", title))
        return false
    end
    -- the chat line says where the guide points, also when that is another map
    local mapID, mx, my = nil, nil, nil
    if project then mapID, mx, my = project(best[1], nil) end
    local targetName = (api and type(api.LocalizedName) == "function" and api.LocalizedName(best[2]))
        or (best[2].names and best[2].names.enUS) or "?"
    local mapInfo = mapID and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    if mx and my then
        guideSay(string.format(guideText("questGuideTo") or "%s > %s - %s (%.1f, %.1f)", title, targetName,
            (mapInfo and mapInfo.name) or "?", mx * 100, my * 100))
    end
    -- Map Finder's moving arrow pins when it is there: every spot of this step
    -- gets a pin, the nearest one the big pin and the waypoint
    if api and type(api.PointAtSpawn) == "function" then
        local shownSpawns, primary, seenSpot = {}, 1, {}
        local bestKey = spotKeyOf(best[1])
        for _, cand in ipairs(spots) do
            if #shownSpawns >= 60 then break end
            -- the same place reached two ways (looted there and listed) gets one pin
            local key = spotKeyOf(cand[1])
            if not seenSpot[key] then
                seenSpot[key] = true
                shownSpawns[#shownSpawns + 1] = cand[1]
                if key == bestKey then primary = #shownSpawns end
            end
        end
        if shownSpawns[primary] ~= best[1] then
            table.insert(shownSpawns, 1, best[1])
            primary = 1
        end
        local label = title .. " - " .. targetName
        local shown = {
            kind = best[2].kind,
            names = setmetatable({}, { __index = function() return label end }),
            spawns = shownSpawns,
        }
        local okPoint, pointed = pcall(api.PointAtSpawn, shown, primary)
        if okPoint and pointed then return true end
    end
    if not (mapID and mx and my and C_Map and C_Map.SetUserWaypoint and UiMapPoint) then return false end
    -- quest details open on the World Map go back to the list when the game's
    -- arrow leaves that quest: no waypoint while they are open
    local details = _G.QuestMapFrame and _G.QuestMapFrame.DetailsFrame
    if details and details.IsShown and details:IsShown() and WorldMapFrame and WorldMapFrame:IsShown() then return true end
    local ok = pcall(function()
        if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then error("map") end
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, mx, my))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
    end)
    return ok
end

ns.RefreshQuestObjectivePins = QuestObjectivePins.refreshAll
