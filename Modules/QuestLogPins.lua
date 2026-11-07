--===========================================================================
-- EzWoW - Quest
-- Modules/QuestLogPins.lua : World Map marks for quests in the player's quest log
--===========================================================================
-- Quests whose objectives are done get a yellow "?" at their turn-in spots
-- (from Map Finder's quest locations). Quests still in progress
-- can be shown too (grey "?", option). Clicking a mark sets a map waypoint.
local _, ns = ...

-- The "EzWoW - ..." name line at the end of tooltip additions is drawn small.
-- Shared by the EzWoW addons: the first one loaded sets it up.
if not (_G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.version == 3) then
    local sizer = {}
    sizer.version = 3
    _G.EzWoWTooltipTagSizer = sizer
    local smallFont
    local original = setmetatable({}, { __mode = "k" })   -- font string -> its own font object
    local function tagFont()
        if not smallFont and CreateFont then
            smallFont = _G.EzWoWTooltipTagFont or CreateFont("EzWoWTooltipTagFont")
            smallFont:CopyFontObject(GameTooltipTextSmall or GameTooltipText)
            local path, _, flags = smallFont:GetFont()
            if path then smallFont:SetFont(path, 8, flags) end
        end
        return smallFont
    end
    local function isTag(text)
        if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return false end
        return text:find("^EzWoW %- ") ~= nil
    end
    local function fit(fs, tag)
        if not fs then return end
        if tag then
            if not original[fs] then original[fs] = fs:GetFontObject() or GameTooltipText end
            if tagFont() then fs:SetFontObject(smallFont) end
            fs:SetTextColor(0.5, 0.5, 0.5)
        elseif original[fs] then
            fs:SetFontObject(original[fs])
            original[fs] = nil
        end
    end
    function sizer.Refit(tip)
        local name = tip and tip.GetName and tip:GetName()
        if type(name) ~= "string" then return end
        local ok, count = pcall(tip.NumLines, tip)
        if not ok or type(count) ~= "number" or (issecretvalue and issecretvalue(count)) then return end
        for i = 1, count do
            local right = _G[name .. "TextRight" .. i]
            if right then fit(right, isTag(right:GetText())) end
            -- line 1 is the tooltip's title: a left "EzWoW - ..." there stays big
            local left = _G[name .. "TextLeft" .. i]
            if left then fit(left, i > 1 and isTag(left:GetText())) end
        end
    end
    local function restore(tip)
        local name = tip and tip.GetName and tip:GetName()
        if type(name) ~= "string" then return end
        local rightPrefix, leftPrefix = name .. "TextRight", name .. "TextLeft"
        for fs, font in pairs(original) do
            local fsName = fs.GetName and fs:GetName()
            if type(fsName) == "string" and (fsName:find(rightPrefix, 1, true) == 1 or fsName:find(leftPrefix, 1, true) == 1) then
                fs:SetFontObject(font)
                original[fs] = nil
            end
        end
    end
    for _, tip in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
        if tip then
            pcall(hooksecurefunc, tip, "Show", function(self) pcall(sizer.Refit, self) end)
            pcall(tip.HookScript, tip, "OnTooltipCleared", function(self) pcall(restore, self) end)
        end
    end
end

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
    -- the same short tag as the quest tracker: D dungeon, R raid, P PvP, + elite/group
    local suffix = ""
    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local okTag, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)
        if okTag and type(tag) == "table" then
            local tagID, tagName = tag.tagID, tag.tagName
            if isSecret(tagID) then tagID = nil end
            if isSecret(tagName) then tagName = nil end
            if tagID == 81 or (tagName and tagName == _G.LFG_TYPE_DUNGEON) then
                suffix = "D"
            elseif tagID == 62 or (tagName and tagName == _G.LFG_TYPE_RAID) then
                suffix = "R"
            elseif tagID == 41 or (tagName and tagName == _G.PVP) then
                suffix = "P"
            elseif tagID or tagName then
                suffix = "+"
            end
        end
    end
    return "[" .. level .. suffix .. "] "
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

-- where a quest is turned in (nil when the data doesn't know the quest)
function QuestLogPins.turnInSpotsForQuest(questID)
    QuestLogPins.buildIndexes()
    local entry = questIndex and questIndex[questID]
    if not (entry and entry.spawns) then return nil end
    return QuestLogPins.spotsFor(entry, questID)
end

function QuestLogPins.questEntry(questID)
    QuestLogPins.buildIndexes()
    return questIndex and questIndex[questID] or nil
end

-- every place the quest is taken or turned in at
function QuestLogPins.questSpots(questID)
    QuestLogPins.buildIndexes()
    local entry = questIndex and questIndex[questID]
    return entry and entry.spawns or nil
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
    setPropagateClicks(pin, false)
    pin:SetSize(15, 15)
    pin:SetFrameStrata("HIGH")
    -- dark round backing with a light rim, so the yellow "?" stands out on
    -- yellow and brown map art alike
    local disc = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
    pin.rim = pin:CreateTexture(nil, "BACKGROUND", nil, 0)
    pin.rim:SetTexture(disc)
    pin.rim:SetPoint("CENTER")
    pin.rim:SetSize(16, 16)
    pin.rim:SetVertexColor(0.95, 0.85, 0.45, 0.95)
    pin.back = pin:CreateTexture(nil, "BACKGROUND", nil, 1)
    pin.back:SetTexture(disc)
    pin.back:SetPoint("CENTER")
    pin.back:SetSize(14, 14)
    pin.back:SetVertexColor(0.08, 0.06, 0.04, 0.92)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetPoint("CENTER")
    pin.icon:SetSize(12, 12)
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
        GameTooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
        GameTooltip:Show()
        if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:HookScript("OnEnter", raisePin)
    pin:HookScript("OnLeave", lowerPin)
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
    local pinScale = zoomGrow(cScale) / cScale
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

-----------------------------------------------------------------------------
-- Quests at an NPC: the ones it gives that this character can take now, and
-- finished quests to hand in there. Shown on the NPC's tooltip and on the
-- minimap tooltip of quest givers ("!").
-----------------------------------------------------------------------------
local CLASS_SORTS = {
    [-61] = "WARLOCK", [-81] = "WARRIOR", [-82] = "SHAMAN", [-141] = "PALADIN", [-161] = "MAGE",
    [-162] = "ROGUE", [-261] = "HUNTER", [-262] = "PRIEST", [-263] = "DRUID",
}
local MAX_NPC_LINES = 6
local LEVEL_AHEAD = 3          -- quests a few levels away are shown greyed
local npcGives, npcTakes, prevQuest

local function setAdd(map, key, value)
    local set = map[key]
    if not set then set = {}; map[key] = set end
    set[value] = true
end

local function clientLoc()
    local loc = (GetLocale and GetLocale()) or "enUS"
    if loc == "esMX" then loc = "esES" elseif loc == "enGB" then loc = "enUS" end
    return loc
end

local function lowerName(s)
    if type(s) ~= "string" or s == "" or isSecret(s) then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
    s = s:gsub("%s+", "")
    if s == "" then return nil end
    return string.lower(s)
end

local function buildNpcQuests()
    if npcGives then return end
    QuestLogPins.buildIndexes()
    npcGives, npcTakes, prevQuest = {}, {}, {}
    if not questIndex then return end
    for questID, entry in pairs(questIndex) do
        local spawns = entry.spawns
        if type(spawns) == "table" and #spawns > 0 then
            local info = QuestLogPins.turnInSpawns(entry)
            local givers, takers = spawns, spawns
            local n, t = #spawns, #info.spawns
            if info.sure and t < n then
                givers = {}
                for i = 1, n - t do givers[i] = spawns[i] end
                takers = info.spawns
            end
            for _, sp in ipairs(givers) do
                local npc = npcBySpot[spotKey(sp) or ""]
                if npc and npc.id then setAdd(npcGives, npc.id, questID) end
            end
            for _, sp in ipairs(takers) do
                local npc = npcBySpot[spotKey(sp) or ""]
                if npc and npc.id then setAdd(npcTakes, npc.id, questID) end
            end
        end
    end
    local qd = ns.QuestData and ns.QuestData()
    if qd and type(qd.quests) == "table" then
        for questID, q in pairs(qd.quests) do
            if type(q) == "table" and q.next then prevQuest[q.next] = questID end
        end
    end
end

-- Quest NPCs near the player, by name. The minimap tooltip only has names, and
-- the names in the data can differ a little from the game's, so the game's own
-- name of each nearby quest NPC is used (plus the data's names).
local NEARBY_YARDS = 300
local nearby = { at = 0 }
local function playerWorld()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then return nil end
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

local function gameNpcName(npcId)
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, "unit:Creature-0-0-0-0-" .. npcId .. "-0")
    local line = ok and type(data) == "table" and data.lines and data.lines[1]
    local text = line and line.leftText
    if type(text) == "string" and not isSecret(text) then return text end
    return nil
end

local function nearbyByName()
    local now = GetTime and GetTime() or 0
    local continent, px, py = playerWorld()
    if not continent then return nearby.names or {} end
    if nearby.names and now - nearby.at < 3 and nearby.continent == continent
        and (px - nearby.x) ^ 2 + (py - nearby.y) ^ 2 < 40 * 40 then
        return nearby.names
    end
    local translations = ns.MapTranslations and ns.MapTranslations()
    local locNames = translations and translations[clientLoc()] and translations[clientLoc()].npc
    local names, checked = {}, {}
    local limit = NEARBY_YARDS * NEARBY_YARDS
    for _, map in ipairs({ npcGives, npcTakes }) do
        for npcId in pairs(map) do
            if not checked[npcId] then
                checked[npcId] = true
                local entry = entryByKey["npc:" .. npcId]
                local close = false
                for _, sp in ipairs(entry and entry.spawns or {}) do
                    if sp[1] == continent and (sp[2] - px) ^ 2 + (sp[3] - py) ^ 2 < limit then close = true; break end
                end
                if close then
                    for _, name in ipairs({ gameNpcName(npcId), locNames and locNames[npcId], entry.names and entry.names.enUS }) do
                        local key = lowerName(name)
                        if key then setAdd(names, key, npcId) end
                    end
                end
            end
        end
    end
    nearby.names, nearby.at, nearby.continent, nearby.x, nearby.y = names, now, continent, px, py
    return names
end

local function questDone(questID)
    if not (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) then return false end
    local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, questID)
    return ok and done == true
end

local function questInLog(questID)
    if not (C_QuestLog and C_QuestLog.GetLogIndexForQuestID) then return false end
    local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
    return ok and type(index) == "number" and not isSecret(index) and index > 0
end

local function questName(questID)
    local translations = ns.MapTranslations and ns.MapTranslations()
    local t = translations and translations[clientLoc()]
    local name = t and t.quest and t.quest[questID]
    if type(name) == "string" and name ~= "" then return name end
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if ok and type(title) == "string" and title ~= "" and not isSecret(title) then return title end
    end
    local entry = questIndex and questIndex[questID]
    return entry and entry.names and entry.names.enUS or ("#" .. questID)
end

-- nil when this character can't take the quest (done, in the log, other side,
-- other class, quest before it not done, far above the character's level)
local function takeable(questID, me)
    if questDone(questID) or questInLog(questID) then return nil end
    local qd = ns.QuestData and ns.QuestData()
    local q = qd and type(qd.quests) == "table" and qd.quests[questID] or nil
    if q then
        if q.races and me.raceBit and bit and bit.band and bit.band(q.races, me.raceBit) == 0 then return nil end
        local class = CLASS_SORTS[q.sort or 0]
        if class and class ~= me.class then return nil end
        if (q.min or 0) > me.level + LEVEL_AHEAD then return nil end
    end
    local prev = prevQuest[questID]
    if prev and not questDone(prev) then return nil end
    return q or {}
end

local function playerInfo()
    local level = (UnitLevel and UnitLevel("player")) or 1
    local _, class = UnitClass("player")
    local raceID = select(3, UnitRace("player"))
    return { level = tonumber(level) or 1, class = class,
        raceBit = (type(raceID) == "number" and raceID >= 1 and raceID <= 31) and 2 ^ (raceID - 1) or nil }
end

-- { { text, r, g, b }, ... } for one NPC ID
function QuestLogPins.npcQuestLines(npcId, me)
    buildNpcQuests()
    me = me or playerInfo()
    local found = {}
    for questID in pairs(npcTakes[npcId] or {}) do
        if questInLog(questID) and QuestLogPins.isQuestComplete(questID) then
            found[#found + 1] = { order = 0, level = 0, text = "? " .. questName(questID) .. " |cff8fd19e(" .. ns:L("NPC_TT_TURNIN") .. ")|r",
                r = 0.25, g = 1, b = 0.35 }
        end
    end
    for questID in pairs(npcGives[npcId] or {}) do
        local q = takeable(questID, me)
        if q then
            local level = tonumber(q.lvl) or 0
            local tooHigh = (q.min or 0) > me.level
            local prefix = level > 0 and ("[" .. level .. "] ") or ""
            local text = "! " .. prefix .. questName(questID)
            if tooHigh then text = text .. " (" .. string.format(ns:L("NPC_TT_FROM_LEVEL"), q.min) .. ")" end
            found[#found + 1] = { order = tooHigh and 2 or 1, level = level, text = text,
                r = tooHigh and 0.6 or 1, g = tooHigh and 0.6 or 0.82, b = tooHigh and 0.6 or 0 }
        end
    end
    table.sort(found, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if a.level ~= b.level then return a.level < b.level end
        return a.text < b.text
    end)
    if #found > MAX_NPC_LINES then
        local more = #found - (MAX_NPC_LINES - 1)
        for i = #found, MAX_NPC_LINES, -1 do found[i] = nil end
        found[#found + 1] = { text = string.format(ns:L("NPC_TT_MORE"), more), r = 0.6, g = 0.6, b = 0.6 }
    end
    return found
end

local function npcTooltipOn()
    return ns.DB and ns.DB.npcQuestTooltip ~= false and ns.HasMapFinder()
end

local function npcIdOf(guid)
    if type(guid) ~= "string" or isSecret(guid) then return nil end
    local unitType, _, _, _, _, id = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return nil end
    return tonumber(id)
end

-- NPC tooltip
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Unit then
    pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tooltip, data)
        if tooltip ~= GameTooltip or not npcTooltipOn() or type(data) ~= "table" then return end
        pcall(function()
            local id = npcIdOf(data.guid)
            if not id then return end
            local lines = QuestLogPins.npcQuestLines(id)
            if #lines == 0 then return end
            for _, l in ipairs(lines) do tooltip:AddLine(l.text, l.r, l.g, l.b) end
            tooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
        end)
    end)
end

-- Minimap tooltip: only NPC names, one per line; quests go under each name
local addingToMinimap = false
local function minimapQuests(tooltip)
    local me = playerInfo()
    local byName = nearbyByName()
    local blocks = {}
    local seen = {}
    for i = 1, tooltip:NumLines() do
        local fs = _G[tooltip:GetName() .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if type(text) == "string" and not isSecret(text) then
            for part in text:gmatch("[^\n]+") do
                local key = lowerName(part)
                local ids = key and byName[key]
                if ids and not seen[key] then
                    seen[key] = true
                    local lines, done = {}, {}
                    for id in pairs(ids) do
                        for _, l in ipairs(QuestLogPins.npcQuestLines(id, me)) do
                            if not done[l.text] then done[l.text] = true; lines[#lines + 1] = l end
                        end
                    end
                    if #lines > 0 then blocks[#blocks + 1] = { name = part, lines = lines } end
                end
            end
        end
    end
    if #blocks == 0 then return end
    for _, block in ipairs(blocks) do
        tooltip:AddLine(" ")
        tooltip:AddLine(block.name, Theme.muted[1], Theme.muted[2], Theme.muted[3])
        for _, l in ipairs(block.lines) do tooltip:AddLine("  " .. l.text, l.r, l.g, l.b) end
    end
    tooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
    addingToMinimap = true
    tooltip:Show()
    addingToMinimap = false
end

if GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnShow", function(tooltip)
        if addingToMinimap or not npcTooltipOn() or not Minimap then return end
        local ok, owner = pcall(tooltip.GetOwner, tooltip)
        if not ok or owner ~= Minimap then return end
        buildNpcQuests()
        pcall(minimapQuests, tooltip)
    end)
end

-----------------------------------------------------------------------------
-- Buttons on the World Map's quest list: expand / collapse every heading,
-- check (watch) every quest, clear every check.
-----------------------------------------------------------------------------
local function logEntries()
    local list = {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return list end
    local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
    for index = 1, (ok and tonumber(count)) or 0 do
        local okInfo, info = pcall(C_QuestLog.GetInfo, index)
        if okInfo and type(info) == "table" then list[#list + 1] = { index = index, info = info } end
    end
    return list
end

local function headerCall(expand, index)
    local fn = expand and ((C_QuestLog and C_QuestLog.ExpandQuestHeader) or _G.ExpandQuestHeader)
        or ((C_QuestLog and C_QuestLog.CollapseQuestHeader) or _G.CollapseQuestHeader)
    if type(fn) ~= "function" then return false end
    return pcall(fn, index)
end

local function anyCollapsed()
    for _, e in ipairs(logEntries()) do
        if e.info.isHeader and e.info.isCollapsed then return true end
    end
    return false
end

local function setAllHeaders(expand)
    -- the list changes after every header, so it is read again each time
    for _ = 1, 60 do
        local target
        for _, e in ipairs(logEntries()) do
            if e.info.isHeader and (e.info.isCollapsed and true or false) == expand then target = e.index; break end
        end
        if not target or not headerCall(expand, target) then break end
    end
end

local function setAllWatched(watch)
    for _, e in ipairs(logEntries()) do
        local info = e.info
        local questID = info.questID
        if not info.isHeader and not info.isHidden and type(questID) == "number" and questID > 0 and not isSecret(questID) then
            if watch then
                if C_QuestLog.AddQuestWatch then pcall(C_QuestLog.AddQuestWatch, questID) end
            elseif C_QuestLog.RemoveQuestWatch then
                pcall(C_QuestLog.RemoveQuestWatch, questID)
            end
        end
    end
end

-- true when some quest in the list is not checked (watched)
local function anyUnwatched()
    for _, e in ipairs(logEntries()) do
        local info = e.info
        local questID = info.questID
        if not info.isHeader and not info.isHidden and type(questID) == "number" and questID > 0 and not isSecret(questID) then
            local watched
            if C_QuestLog.GetQuestWatchType then
                local ok, kind = pcall(C_QuestLog.GetQuestWatchType, questID)
                watched = ok and kind ~= nil
            elseif type(IsQuestWatched) == "function" then
                local ok, v = pcall(IsQuestWatched, e.index)
                watched = ok and v and true or false
            end
            if not watched then return true end
        end
    end
    return false
end

local questLogBar
local function barButton(parent, width, onClick)
    local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    b:SetSize(width, 18)
    if b.SetBackdrop then
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        b:SetBackdropColor(0.07, 0.09, 0.12, 0.92)
        b:SetBackdropBorderColor(0.20, 0.30, 0.36, 1)
    end
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self) if self.SetBackdropBorderColor then self:SetBackdropBorderColor(0.94, 0.72, 0.42, 1) end end)
    b:SetScript("OnLeave", function(self) if self.SetBackdropBorderColor then self:SetBackdropBorderColor(0.20, 0.30, 0.36, 1) end end)
    return b
end

local function refreshBar()
    if not questLogBar then return end
    questLogBar.fold.text:SetText(ns:L(anyCollapsed() and "QUESTLOG_EXPAND_ALL" or "QUESTLOG_COLLAPSE_ALL"))
    questLogBar.check.text:SetText(ns:L(anyUnwatched() and "QUESTLOG_TRACK_ALL" or "QUESTLOG_UNTRACK_ALL"))
end

local function createQuestLogBar()
    local list = _G.QuestMapFrame
    if questLogBar or not (list and WorldMapFrame) then return end
    -- outside the map window's right edge, next to the quest list: nothing covers it there
    local bar = CreateFrame("Frame", nil, WorldMapFrame)
    bar:SetSize(78, 40)
    bar:SetPoint("TOPLEFT", WorldMapFrame, "TOPRIGHT", 3, -34)
    bar:SetFrameStrata(WorldMapFrame:GetFrameStrata())
    bar:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 50)
    bar.fold = barButton(bar, 78, function()
        setAllHeaders(anyCollapsed())
        refreshBar()
    end)
    bar.fold:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    -- one button: checks every quest, or clears every check when all are checked
    bar.check = barButton(bar, 78, function()
        setAllWatched(anyUnwatched())
        if C_Timer then C_Timer.After(0.2, refreshBar) else refreshBar() end
    end)
    bar.check:SetPoint("TOPLEFT", bar.fold, "BOTTOMLEFT", 0, -4)
    questLogBar = bar
    local function sync() bar:SetShown(list:IsShown()); refreshBar() end
    list:HookScript("OnShow", sync)
    list:HookScript("OnHide", sync)
    sync()
end

local barEvents = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "ADDON_LOADED", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED" }) do
    pcall(barEvents.RegisterEvent, barEvents, event)
end
barEvents:SetScript("OnEvent", function(_, event)
    if event == "QUEST_LOG_UPDATE" or event == "QUEST_WATCH_LIST_CHANGED" then
        if questLogBar and questLogBar:IsShown() then refreshBar() end
        return
    end
    pcall(createQuestLogBar)
end)

ns.RefreshQuestLogPins = QuestLogPins.refresh
ns.RescaleQuestLogPins = QuestLogPins.rescale
