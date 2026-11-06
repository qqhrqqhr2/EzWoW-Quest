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
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local floor, abs, sqrt, sin, cos = math.floor, math.abs, math.sqrt, math.sin, math.cos

local QuestObjectivePins = ns.QuestObjectivePins or {}
ns.QuestObjectivePins = QuestObjectivePins

local Theme = ns.Theme

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DOT_SIZE = 6
local AREA_SIZE = 11

-- One colour per kind of objective (not per quest), so the map reads at a glance:
-- red = creatures to kill, gold = things to collect or use; the game's quest
-- position is a hollow gold ring.
local COLOR_KILL = { 1.00, 0.30, 0.25 }
local COLOR_COLLECT = { 1.00, 0.82, 0.20 }
local COLOR_TITLE = { 1.00, 0.82, 0.00 }
local function objectiveColor(obj)
    return (obj and obj.type == "monster") and COLOR_KILL or COLOR_COLLECT
end
local MERGE_PIXELS = 7
local MAX_WORLD_DOTS = 700
local MAX_MINIMAP_DOTS = 80
local MAX_SPAWNS_PER_ENTRY = 400
local MINIMAP_DOT_SIZE = 5
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
local npcByWord      -- lower-case word of an NPC name -> { entry, ... }
local MAX_GUESS_ENTRIES = 30

local function buildDropIndexes()
    if npcById then return end
    QuestObjectivePins.buildNameIndex()
    npcById, npcByWord = {}, {}
    for _, e in ipairs(ns.MapData()) do
        if e.kind == "npc" and e.id and type(e.spawns) == "table" and #e.spawns > 0 then
            npcById[e.id] = npcById[e.id] or e
        end
    end
    for name, list in pairs(nameIndex.npc) do
        for word in name:gmatch("%S+") do
            local bucket = npcByWord[word]
            if not bucket then
                bucket = {}
                npcByWord[word] = bucket
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

local function learnedDropEntries(itemKey)
    local store = dropStore()
    local ids = store and store[itemKey]
    if type(ids) ~= "table" then return nil end
    buildDropIndexes()
    local list = {}
    for id in pairs(ids) do
        local e = npcById[tonumber(id)]
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
        if usefulWord(word) and npcByWord[word] then
            for _, e in ipairs(npcByWord[word]) do
                if not seen[e] then
                    seen[e] = true
                    list[#list + 1] = e
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

function QuestObjectivePins.rebuildQuests()
    quests, questByID = {}, {}
    if not enabled() then return end
    local collect = ns.QuestLogPins and ns.QuestLogPins.collectQuests
    if not collect then return end
    local okList, list = pcall(collect)
    if not okList or type(list) ~= "table" then return end
    local zones
    for _, q in ipairs(list) do
        if not q.complete then
            local quest = {
                id = q.id,
                title = questTitle(q),
                color = COLOR_TITLE,
                objectives = readObjectives(q.id),
            }
            for _, obj in ipairs(quest.objectives) do
                if not obj.finished and (obj.type == "monster" or obj.type == "object" or obj.type == "item") then
                    obj.entries = QuestObjectivePins.matchObjective(obj.type, obj.text)
                    if obj.type == "item" then
                        obj.itemKey = normalize(stripCounts(obj.text))
                        local learned = obj.itemKey and learnedDropEntries(obj.itemKey)
                        if learned then
                            obj.entries = learned
                        elseif not obj.entries and obj.itemKey then
                            zones = zones or questZones()
                            local zone = zones[q.id]
                            local guessed = zone and guessedDropEntries(obj.itemKey)
                            if guessed then
                                obj.entries, obj.zoneOnly, obj.guess = guessed, zone, true
                            end
                        end
                    end
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
        local r, g, b = quest.color[1], quest.color[2], quest.color[3]
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
                if obj.guess and item.objectives and ns:L("questObjGuess") then
                    GameTooltip:AddLine("    " .. ns:L("questObjGuess"), unpack(Theme.muted))
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
    GameTooltip:AddLine("EzWoW - Quest", unpack(Theme.muted))
    GameTooltip:Show()
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
    if pin.SetPropagateMouseClicks then pin:SetPropagateMouseClicks(false) end
    pin:SetSize(DOT_SIZE, DOT_SIZE)
    pin:SetFrameStrata("HIGH")
    pin.border = newDisc(pin, "ARTWORK", 1, DOT_SIZE)
    pin.border:SetVertexColor(0, 0, 0, 0.85)
    pin.fill = newDisc(pin, "ARTWORK", 2, DOT_SIZE - 3)
    pin:SetScript("OnEnter", function(self) if self.group then showGroupTooltip(self, self.group) end end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
    if pin.SetPropagateMouseClicks then pin:SetPropagateMouseClicks(false) end
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
    local pinScale = 1 / cScale
    local px = group.px * (cw / (group.cw or cw))
    local py = group.py * (ch / (group.ch or ch))
    pin:SetScale(pinScale)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", canvasFrame, "TOPLEFT", px / pinScale, -py / pinScale)
end

-- Spots of one objective entry on the given map (normalized coordinates).
local function eachSpot(entries, mapID, project, fn)
    for _, entry in ipairs(entries) do
        local spawns = entry.spawns
        local n = #spawns
        if n > MAX_SPAWNS_PER_ENTRY then n = MAX_SPAWNS_PER_ENTRY end
        for i = 1, n do
            local sp = spawns[i]
            local mapID2, mx, my = project(sp, mapID)
            if mx and my and mapID2 == mapID then fn(mx, my, sp, entry) end
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
                            group = { px = px, py = py, cw = cw, ch = ch, spawn = sp, color = objectiveColor(obj),
                                items = { { quest = quest, objectives = {} } }, seen = {} }
                            cells[key] = group
                            groups[#groups + 1] = group
                        end
                        if not group.seen[obj] then
                            group.seen[obj] = true
                            local objs = group.items[1].objectives
                            objs[#objs + 1] = obj
                        end
                    end)
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
    pin.border:SetVertexColor(0, 0, 0, 0.85)
    pin.fill = newDisc(pin, "ARTWORK", 2, MINIMAP_DOT_SIZE - 2)
    pin:EnableMouse(true)
    if pin.SetPropagateMouseClicks then pin:SetPropagateMouseClicks(true) end
    pin:SetScript("OnEnter", function(self) if self.group then showGroupTooltip(self, self.group, "ANCHOR_LEFT") end end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
                    local color = objectiveColor(obj)
                    local group = { color = color, items = { { quest = quest, objectives = { obj } } } }
                    eachSpot(obj.entries, mapID, project, function(mx, my)
                        miniPoints[#miniPoints + 1] = { x = mx, y = my, color = color, group = group }
                        miniWithDots[quest.id] = true
                    end)
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
local function installMapHooks()
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
    if WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin and CreateFromMixins then
        local provider = CreateFromMixins(MapCanvasDataProviderMixin)
        provider.RemoveAllData = function() end
        provider.RefreshAllData = function() end
        provider.OnMapChanged = onMapChanged
        provider.OnCanvasScaleChanged = onScale
        WorldMapFrame:AddDataProvider(provider)
    else
        if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", onMapChanged) end
        if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", onScale) end
    end
    WorldMapFrame:HookScript("OnShow", onMapChanged)
    WorldMapFrame:HookScript("OnSizeChanged", onMapChanged)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE",
    "QUEST_ACCEPTED", "QUEST_REMOVED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "LOOT_OPENED" }) do
    pcall(events.RegisterEvent, events, event)
end
-- Looting a quest item: remember which creatures it came from.
local function learnFromLoot()
    if not (GetNumLootItems and GetLootSlotLink and GetLootSourceInfo) then return end
    local wanted = {}
    for _, quest in ipairs(quests) do
        for _, obj in ipairs(quest.objectives) do
            if obj.type == "item" and obj.itemKey then wanted[obj.itemKey] = true end
        end
    end
    if not next(wanted) then return end
    local store = dropStore()
    if not store then return end
    local learnedAny = false
    local okCount, count = pcall(GetNumLootItems)
    count = okCount and tonumber(count) or 0
    for slot = 1, count do
        local okLink, link = pcall(GetLootSlotLink, slot)
        local name = okLink and type(link) == "string" and not isSecret(link) and link:match("%[(.-)%]")
        local key = name and normalize(name)
        if key and wanted[key] then
            local sources = { pcall(GetLootSourceInfo, slot) }
            if sources[1] then
                for i = 2, #sources, 2 do
                    local guid = sources[i]
                    if type(guid) == "string" and not isSecret(guid) then
                        local unitType, _, _, _, _, npcId = strsplit("-", guid)
                        npcId = tonumber(npcId)
                        if (unitType == "Creature" or unitType == "Vehicle") and npcId then
                            store[key] = store[key] or {}
                            if not store[key][npcId] then
                                store[key][npcId] = true
                                learnedAny = true
                            end
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
                wanted[obj.itemKey] = true
            end
        end
    end
    if not wanted then return end
    local store = dropStore()
    if not store then return end
    for i = 2, #data.lines do
        local text = data.lines[i] and data.lines[i].leftText
        if type(text) == "string" and not isSecret(text) then
            local key = normalize(stripCounts(text:gsub("^%s*%-%s*", "")))
            if key and wanted[key] then
                store[key] = store[key] or {}
                if not store[key][npcId] then
                    store[key][npcId] = true
                    queueRefresh()
                end
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

ns.RefreshQuestObjectivePins = QuestObjectivePins.refreshAll
