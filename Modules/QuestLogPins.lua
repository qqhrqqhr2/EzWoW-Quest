--===========================================================================
-- EzWoW - Quest
-- Modules/QuestLogPins.lua : World Map marks for quests in the player's quest log
--===========================================================================
-- Quests whose objectives are done get a yellow "?" at their turn-in spots
-- (from Map Finder's quest locations). Quests still in progress
-- can be shown too (grey "?", option). Clicking a mark sets a map waypoint.
local _, ns = ...
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall

local QuestLogPins = ns.QuestLogPins or {}
ns.QuestLogPins = QuestLogPins

local Theme = ns.Theme

local ICON_READY = "Interface\\GossipFrame\\ActiveQuestIcon"
local ICON_ACTIVE = "Interface\\GossipFrame\\IncompleteQuestIcon"
local MERGE_PIXELS = 12

local pins = {}
local questIndex      -- questID -> quest entry of the built-in data
local npcBySpot       -- "continent:x:y" -> npc entry (name for the tooltip)
local entryByKey      -- "npc:id" / "object:id" -> entry

local function isSecret(v) return issecretvalue and issecretvalue(v) end

local function spotKey(sp)
    if type(sp) ~= "table" or type(sp[2]) ~= "number" or type(sp[3]) ~= "number" then return nil end
    return tostring(sp[1]) .. ":" .. math.floor(sp[2] + 0.5) .. ":" .. math.floor(sp[3] + 0.5)
end

-- "[16] " for a quest in the log (its level), "" when the level isn't known.
function ns.QuestLevelPrefix(questID)
    local level
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetInfo then
        local okIndex, index = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
        if okIndex and type(index) == "number" and not isSecret(index) then
            local okInfo, info = pcall(C_QuestLog.GetInfo, index)
            if okInfo and type(info) == "table" then level = info.level end
        end
    end
    if (type(level) ~= "number" or level <= 0) and C_QuestLog and C_QuestLog.GetQuestDifficultyLevel then
        local ok, l = pcall(C_QuestLog.GetQuestDifficultyLevel, questID)
        if ok then level = l end
    end
    if type(level) ~= "number" or isSecret(level) or level <= 0 then return "" end
    return "[" .. level .. "] "
end

function QuestLogPins.buildIndexes()
    if questIndex or not ns.HasMapFinder() then return end
    questIndex, npcBySpot, entryByKey = {}, {}, {}
    for _, e in ipairs(ns.MapData()) do
        if (e.kind == "npc" or e.kind == "object") and e.id and e.spawns then
            entryByKey[e.kind .. ":" .. e.id] = entryByKey[e.kind .. ":" .. e.id] or e
        end
        if e.kind == "quest" and e.id then
            questIndex[e.id] = e
        elseif e.kind == "npc" and e.spawns then
            for _, sp in ipairs(e.spawns) do
                local key = spotKey(sp)
                if key and not npcBySpot[key] then npcBySpot[key] = e end
            end
        end
    end
end

-- Quest spots are stored as NPC spots first, then object spots; within each
-- group the quest givers come before the turn-in spots. When every spot is an
-- NPC (or every spot is an object) and the count is even, the second half is
-- the turn-in side. Mixed or odd lists can't be split here (see spotsFor).
local turnInCache = {}

function QuestLogPins.turnInSpawns(entry)
    local cached = turnInCache[entry]
    if cached then return cached end
    local spawns = entry.spawns
    local n = #spawns
    local result = spawns
    if n >= 2 and n % 2 == 0 then
        local npcCount = 0
        for _, sp in ipairs(spawns) do
            local key = spotKey(sp)
            if key and npcBySpot[key] then npcCount = npcCount + 1 end
        end
        local allNpc = npcCount == n
        local noNpc = npcCount == 0
        if allNpc or noNpc then
            result = {}
            for i = n / 2 + 1, n do result[#result + 1] = spawns[i] end
        end
    end
    -- a single spot (or one spot listed twice) is never ambiguous
    local unique = {}
    for _, sp in ipairs(result) do unique[spotKey(sp) or tostring(sp)] = true end
    local uniqueCount = 0
    for _ in pairs(unique) do uniqueCount = uniqueCount + 1 end
    cached = { spawns = result, sure = (result ~= spawns) or uniqueCount <= 1 }
    turnInCache[entry] = cached
    return cached
end

-- The NPC / object the player took a quest from is remembered, so that spot
-- can be left out when the built-in data can't tell giver and turn-in apart.
local function starterStore()
    if not ns.DB then return nil end
    if type(ns.DB.questStarters) ~= "table" then ns.DB.questStarters = {} end
    return ns.DB.questStarters
end

local function guidToStarter(guid)
    if type(guid) ~= "string" or isSecret(guid) then return nil end
    local unitType, _, _, _, _, id = strsplit("-", guid)
    id = tonumber(id)
    if not id then return nil end
    if unitType == "Creature" or unitType == "Vehicle" then return "npc:" .. id end
    if unitType == "GameObject" then return "object:" .. id end
    return nil
end

local function currentStarter()
    for _, unit in ipairs({ "questnpc", "npc" }) do
        local ok, guid = pcall(UnitGUID, unit)
        if ok then
            local starter = guidToStarter(guid)
            if starter then return starter end
        end
    end
    return nil
end

-- Spots of the remembered giver are removed; if nothing would be left
-- (the same NPC gives and takes the quest) every spot is kept.
-- Without a remembered giver an unclear quest gets no mark at all, so a
-- mark never points back at where the quest was taken.
local NO_SPOTS = {}

function QuestLogPins.spotsFor(entry, questID)
    local info = QuestLogPins.turnInSpawns(entry)
    if info.sure then return info.spawns end
    local store = starterStore()
    local starter = store and store[questID]
    local giver = type(starter) == "string" and entryByKey[starter]
    if not (giver and giver.spawns) then return NO_SPOTS end
    local giverSpots = {}
    for _, sp in ipairs(giver.spawns) do
        local key = spotKey(sp)
        if key then giverSpots[key] = true end
    end
    local kept = {}
    for _, sp in ipairs(info.spawns) do
        if not giverSpots[spotKey(sp) or ""] then kept[#kept + 1] = sp end
    end
    if #kept == 0 then return info.spawns end
    return kept
end

-----------------------------------------------------------------------------
-- Quest log (C_QuestLog first, older globals as fallback)
-----------------------------------------------------------------------------
function QuestLogPins.isQuestComplete(questID, legacyComplete)
    if C_QuestLog then
        if C_QuestLog.ReadyForTurnIn then
            local ok, ready = pcall(C_QuestLog.ReadyForTurnIn, questID)
            if ok and ready == true then return true end
        end
        if C_QuestLog.IsComplete then
            local ok, done = pcall(C_QuestLog.IsComplete, questID)
            if ok and type(done) == "boolean" then return done end
        end
    end
    return legacyComplete == 1 or legacyComplete == true
end

function QuestLogPins.collectQuests()
    local list = {}
    local seen = {}
    local function add(questID, title, legacyComplete)
        questID = tonumber(questID)
        if not questID or questID <= 0 or seen[questID] or isSecret(questID) then return end
        seen[questID] = true
        list[#list + 1] = { id = questID, title = title, complete = QuestLogPins.isQuestComplete(questID, legacyComplete) }
    end
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
        if ok and type(count) == "number" then
            for index = 1, count do
                local okInfo, info = pcall(C_QuestLog.GetInfo, index)
                if okInfo and type(info) == "table" and not info.isHeader and not info.isHidden then
                    add(info.questID, info.title)
                end
            end
            return list
        end
    end
    if type(GetNumQuestLogEntries) == "function" and type(GetQuestLogTitle) == "function" then
        local count = GetNumQuestLogEntries()
        for index = 1, tonumber(count) or 0 do
            local title, _, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(index)
            if not isHeader then add(questID, title, isComplete) end
        end
    end
    return list
end

-----------------------------------------------------------------------------
-- Marks
-----------------------------------------------------------------------------
function QuestLogPins.canvas()
    return (WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas())
        or (_G.EzWoWWorldMapDock and _G.EzWoWWorldMapDock:GetCanvas())
        or WorldMapFrame
end

function QuestLogPins.obtainPin(index)
    local pin = pins[index]
    if pin then return pin end
    local canvasFrame = QuestLogPins.canvas()
    pin = CreateFrame("Button", nil, canvasFrame)
    pin:EnableMouse(true)
    pin:RegisterForClicks("LeftButtonUp")
    if pin.SetPropagateMouseClicks then pin:SetPropagateMouseClicks(false) end
    pin:SetSize(18, 18)
    pin:SetFrameStrata("HIGH")
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints()
    pin:SetScript("OnEnter", function(self)
        local group = self.group
        if not group then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(group.npcName or "EzWoW - Quest", unpack(Theme.accent))
        for _, quest in ipairs(group.quests) do
            local state = quest.complete and ("|cff40ff59" .. ns:L("questPinReady") .. "|r") or ("|cffa7b9c5" .. ns:L("questPinActive") .. "|r")
            GameTooltip:AddLine(ns.QuestLevelPrefix(quest.id) .. (quest.title or ("#" .. quest.id)) .. "  " .. state, 0.929, 0.957, 0.969, true)
        end
        GameTooltip:AddLine(ns:L("questPinHint"), unpack(Theme.muted))
        GameTooltip:AddLine("EzWoW - Quest", unpack(Theme.muted))
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:SetScript("OnClick", function(self)
        local sp = self.group and self.group.spawn
        if not sp then return end
        ns.ApplyWaypointForSpawn(sp)
    end)
    ns.PassMapRightClicks(pin)
    pins[index] = pin
    return pin
end

function QuestLogPins.hideAll()
    for _, pin in ipairs(pins) do pin:Hide() end
end

function QuestLogPins.refresh()
    QuestLogPins.hideAll()
    if not (ns.DB and ns.DB.questLogPins ~= false) then return end
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    local project = ns.MapProjector()
    if not project then return end
    local mapID = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    if not mapID or isSecret(mapID) then return end
    local canvasFrame = QuestLogPins.canvas()
    local cw, ch = canvasFrame:GetWidth(), canvasFrame:GetHeight()
    if not cw or not ch or cw <= 0 or ch <= 0 then return end
    local cScale = (WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale()) or 1
    if not cScale or cScale <= 0 then cScale = 1 end

    QuestLogPins.buildIndexes()
    if not questIndex then return end
    local showAll = ns.DB.questLogPinsAll == true
    local groups = {}
    for _, quest in ipairs(QuestLogPins.collectQuests()) do
        local entry = (quest.complete or showAll) and questIndex[quest.id]
        if entry and entry.spawns then
            if not quest.title or quest.title == "" or isSecret(quest.title) then
                quest.title = ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(entry) or nil
            end
            local seenSpot = {}
            for _, sp in ipairs(QuestLogPins.spotsFor(entry, quest.id)) do
                local key = spotKey(sp) or tostring(sp)
                if not seenSpot[key] then
                    seenSpot[key] = true
                    local mapID2, mx, my = project(sp, mapID)
                    if mx and my and mapID2 == mapID then
                        local px, py = mx * cw, my * ch
                        local group
                        for _, g in ipairs(groups) do
                            if math.abs(g.px - px) * cScale < MERGE_PIXELS and math.abs(g.py - py) * cScale < MERGE_PIXELS then
                                group = g
                                break
                            end
                        end
                        if not group then
                            local npc = npcBySpot[key]
                            group = { px = px, py = py, cw = cw, ch = ch, spawn = sp, quests = {}, ids = {},
                                npcName = npc and ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(npc) or nil }
                            groups[#groups + 1] = group
                        end
                        if not group.ids[quest.id] then
                            group.ids[quest.id] = true
                            group.quests[#group.quests + 1] = quest
                            if quest.complete then group.complete = true end
                        end
                    end
                end
            end
        end
    end

    for index, group in ipairs(groups) do
        local pin = QuestLogPins.obtainPin(index)
        pin:SetParent(canvasFrame)
        pin:SetFrameLevel((canvasFrame:GetFrameLevel() or 10) + (group.complete and 200 or 190))
        pin.group = group
        pin.icon:SetTexture(group.complete and ICON_READY or ICON_ACTIVE)
        QuestLogPins.anchorPin(pin, canvasFrame, cw, ch, cScale)
        pin:Show()
    end
end

-- Pins keep one size on screen; group.px / py were taken at canvas size cw x ch.
function QuestLogPins.anchorPin(pin, canvasFrame, cw, ch, cScale)
    local group = pin.group
    local pinScale = 1 / cScale
    local px = group.px * (cw / (group.cw or cw))
    local py = group.py * (ch / (group.ch or ch))
    pin:SetScale(pinScale)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", canvasFrame, "TOPLEFT", px / pinScale, -py / pinScale)
end

-- Zoom changes move and resize the marks at once; the marks are grouped
-- again (marks close together on screen share one) once zooming has stopped.
local regroupPending = false
local lastRescaleAt = 0
local REGROUP_DELAY = 0.3

local function regroupWhenSettled()
    local waited = GetTime() - lastRescaleAt
    if waited < REGROUP_DELAY then
        C_Timer.After(REGROUP_DELAY - waited, regroupWhenSettled)
        return
    end
    regroupPending = false
    QuestLogPins.refresh()
end

function QuestLogPins.rescale()
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    local canvasFrame = QuestLogPins.canvas()
    local cw, ch = canvasFrame:GetWidth(), canvasFrame:GetHeight()
    if not cw or not ch or cw <= 0 or ch <= 0 then return end
    local cScale = (WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale()) or 1
    if not cScale or cScale <= 0 then cScale = 1 end
    local any = false
    for _, pin in ipairs(pins) do
        if pin:IsShown() and pin.group then
            QuestLogPins.anchorPin(pin, canvasFrame, cw, ch, cScale)
            any = true
        end
    end
    if not any then return end
    lastRescaleAt = GetTime()
    if not regroupPending and C_Timer and C_Timer.After then
        regroupPending = true
        C_Timer.After(REGROUP_DELAY, regroupWhenSettled)
    end
end

-- quest log changes: redraw only while the map is open
local events = CreateFrame("Frame")
for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN" }) do
    pcall(events.RegisterEvent, events, event)
end
pcall(events.RegisterEvent, events, "QUEST_DETAIL")
local queued = false
local detailQuest, detailStarter   -- quest window currently open and who offers it

local function rememberStarter(questID, starter)
    questID = tonumber(questID)
    if not questID or not starter or isSecret(questID) then return end
    local store = starterStore()
    if store then store[questID] = starter end
end

local function onQuestEvent(event, ...)
    if event == "QUEST_DETAIL" then
        local questID = type(GetQuestID) == "function" and GetQuestID() or nil
        detailQuest, detailStarter = tonumber(questID), currentStarter()
        return true
    elseif event == "QUEST_ACCEPTED" then
        -- newer clients pass (questID); older ones (logIndex, questID)
        local a, b = ...
        local questID = tonumber(b) or tonumber(a)
        local starter = currentStarter()
        if not starter and questID == detailQuest then starter = detailStarter end
        rememberStarter(questID, starter)
    elseif event == "QUEST_TURNED_IN" then
        local questID = tonumber((...))
        local store = starterStore()
        if store and questID and not isSecret(questID) then store[questID] = nil end
    end
    return false
end

events:SetScript("OnEvent", function(_, event, ...)
    local ok, skip = pcall(onQuestEvent, event, ...)
    if ok and skip then return end
    if queued or not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    queued = true
    C_Timer.After(0.2, function()
        queued = false
        QuestLogPins.refresh()
    end)
end)

ns.RefreshQuestLogPins = QuestLogPins.refresh
ns.RescaleQuestLogPins = QuestLogPins.rescale
