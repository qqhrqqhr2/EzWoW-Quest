--===========================================================================
-- EzWoW - Quest
-- Modules/QuestLogPins.lua : World Map marks for quests in the player's quest log
--===========================================================================
-- Quests whose objectives are done get a yellow "?" at their turn-in spots
-- (from Map Finder's quest locations). Quests still in progress
-- can be shown too (grey "?", option). Clicking a mark sets a map waypoint.
local _, ns = ...
-- frames made on the World Map are made without a parent and put in after
-- (Libs/EzWoWGamePad MakeFrame: keeps the game's gamepad cursor untainted)
local CreateFrame = (ns.GamePad and ns.GamePad.MakeFrame) or CreateFrame

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
    -- flags 1 on a quest: nobody hands it out (it starts from an item), so
    -- every spot is where it is turned in
    if entry.kind == "quest" and type(entry.flags) == "number" and entry.flags % 2 == 1 then
        cached = { spawns = spawns, sure = true, noGiver = true }
        turnInCache[entry] = cached
        return cached
    end
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

-- Quests this character has handed in, kept per character (the saved data is
-- shared by all characters). One handed in that the game still does not flag
-- as completed is repeatable: it is shown with a blue "?" (see repeatDone).
local function turnedInSet(create)
    if not ns.DB then return nil end
    local guid = UnitGUID and UnitGUID("player")
    if type(guid) ~= "string" or isSecret(guid) then return nil end
    if type(ns.DB.questTurnedIn) ~= "table" then
        if not create then return nil end
        ns.DB.questTurnedIn = {}
    end
    local set = ns.DB.questTurnedIn[guid]
    if not set and create then
        set = {}
        ns.DB.questTurnedIn[guid] = set
    end
    return set
end

-- Quests the data says an NPC gives, but which that NPC did not offer this
-- character when it last talked to them (changed or hidden requirements on
-- this server). [questID] = character level then; shown again after a level up.
local function notOfferedSet(create)
    if not ns.DB then return nil end
    local guid = UnitGUID and UnitGUID("player")
    if type(guid) ~= "string" or isSecret(guid) then return nil end
    if type(ns.DB.questNotOffered) ~= "table" then
        if not create then return nil end
        ns.DB.questNotOffered = {}
    end
    local set = ns.DB.questNotOffered[guid]
    if not set and create then
        set = {}
        ns.DB.questNotOffered[guid] = set
    end
    return set
end

-- What NPCs offered when players talked to them, shared between EzWoW users
-- (shared record kind "Q", registered below): store["npcID:questID"] =
--   { own = { state, level, raceID, classID }, peers = { [sender] = { state, raceID, classID } },
--     spot = { continent, x, y, 0 } where the NPC stood (only for NPCs the data lacks) }
-- state 1: the NPC offered the quest; 0: it did not, though the player met
-- every requirement this addon knows of. Each addon decides what to show
-- (questConditional): an offer adds the NPC as a giver; "not offered" to
-- players of this race / class, or to two players with no offer at all,
-- marks the quest [condition].
local OFFER_KIND = "Q"
local MAX_OFFER_PEERS = 20
local OFFER_NEEDED = 2

local function offerStore()
    local s = ns.Share
    if not (s and type(s.Store) == "function") then return nil end
    local ok, store = pcall(s.Store, OFFER_KIND)
    return ok and type(store) == "table" and store or nil
end

-- every vote on one NPC and quest: { state, raceID, classID } (this player's own included)
local function offerVoteList(npcId, questID)
    local store = offerStore()
    local row = store and store[npcId .. ":" .. questID]
    local out = {}
    if type(row) ~= "table" then return out end
    if type(row.own) == "table" and (row.own[1] == 0 or row.own[1] == 1) then
        out[#out + 1] = { row.own[1], row.own[3], row.own[4] }
    end
    for _, v in pairs(type(row.peers) == "table" and row.peers or {}) do
        if type(v) == "table" and (v[1] == 0 or v[1] == 1) then out[#out + 1] = v
        elseif v == 0 or v == 1 then out[#out + 1] = { v } end
    end
    return out
end

-- offered, notOffered: how many players saw each
local function offerVotes(npcId, questID)
    local yes, no = 0, 0
    for _, v in ipairs(offerVoteList(npcId, questID)) do
        if v[1] == 1 then yes = yes + 1 else no = no + 1 end
    end
    return yes, no
end

-- true when the votes say this character probably can't take it there
local function offerSaysNo(npcId, questID, me)
    local mine = { yes = 0, no = 0 }
    local race, class = { yes = 0, no = 0 }, { yes = 0, no = 0 }
    local all = { yes = 0, no = 0 }
    for _, v in ipairs(offerVoteList(npcId, questID)) do
        local k = v[1] == 1 and "yes" or "no"
        all[k] = all[k] + 1
        local sameRace = me and me.raceID and v[2] == me.raceID
        local sameClass = me and me.classID and v[3] == me.classID
        if sameRace then race[k] = race[k] + 1 end
        if sameClass then class[k] = class[k] + 1 end
        if sameRace and sameClass then mine[k] = mine[k] + 1 end
    end
    if mine.yes > 0 then return false end
    if mine.no > 0 then return true end
    if all.yes == 0 and all.no >= OFFER_NEEDED then return true end
    -- offered to others, not to this race or class: a limit the data lacks
    if all.yes > 0 and race.yes == 0 and race.no >= OFFER_NEEDED then return true end
    if all.yes > 0 and class.yes == 0 and class.no >= OFFER_NEEDED then return true end
    return false
end

local function noteOwnOffer(npcId, questID, state, me, spot)
    local store = offerStore()
    if not store then return false end
    local key = npcId .. ":" .. questID
    local row = type(store[key]) == "table" and store[key] or {}
    store[key] = row
    if spot and not row.spot then row.spot = spot; row.ownSpot = true end
    local old = row.own
    if type(old) == "table" and old[1] == state and old[2] == me.level then return false end
    row.own = { state, me.level, me.raceID or 0, me.classID or 0 }
    return true
end

-- where the player stands, as a data spot { continent, x, y, 0 } (nil inside instances)
local function playerSpot()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then
        return nil
    end
    local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or type(mapID) ~= "number" or isSecret(mapID) then return nil end
    local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not okPos or not pos then return nil end
    local okWorld, continent, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
    if not okWorld or type(continent) ~= "number" or isSecret(continent) or type(world) ~= "table" then return nil end
    local x, y = world.x, world.y
    if type(x) ~= "number" or type(y) ~= "number" or isSecret(x) or isSecret(y) then return nil end
    return { continent, math.floor(x * 10 + 0.5) / 10, math.floor(y * 10 + 0.5) / 10, 0 }
end

-- NPC ID -> spot, for quest givers seen in the game that the data has no spot for
local offerNpcSpots = {}

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

-- Turn-in places from the learned / installed sources (Modules/QuestSources.lua):
-- the spots, and spot key -> NPC or object name.
local function sourceTurnIn(questID)
    local sources = ns.QuestSources
    if not (sources and sources.turnInEntries) then return nil end
    local ok, entries = pcall(sources.turnInEntries, questID)
    if not ok or type(entries) ~= "table" then return nil end
    local spots, names = {}, {}
    for _, e in ipairs(entries) do
        local name = sources.nameOf and sources.nameOf(e)
        for _, sp in ipairs(e.spawns or {}) do
            spots[#spots + 1] = sp
            local key = spotKey(sp)
            if key and name then names[key] = name end
        end
    end
    if #spots == 0 then return nil end
    return spots, names
end

-- where a quest is turned in (nil when the data doesn't know the quest);
-- second value: spot key -> name, for spots the built-in data has no NPC for
function QuestLogPins.turnInSpotsForQuest(questID)
    QuestLogPins.buildIndexes()
    local spots, names = sourceTurnIn(questID)
    if spots then return spots, names end
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
        local quest = self.group.quests and self.group.quests[1]
        ns.ApplyWaypointForSpawn(sp, self.group.npcName or (quest and quest.title) or "")
    end)
    ns.PassMapRightClicks(pin)
    pins[index] = pin
    return pin
end

function QuestLogPins.hideAll()
    for _, pin in ipairs(pins) do pin:Hide() end
    if QuestLogPins.hideGivers then QuestLogPins.hideGivers() end
end

function QuestLogPins.refresh()
    QuestLogPins.hideAll()
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
    if QuestLogPins.refreshGivers then
        pcall(QuestLogPins.refreshGivers, mapID, project, canvasFrame, cw, ch, cScale)
    end
    if not (ns.DB and ns.DB.questLogPins ~= false) then return end
    local showAll = ns.DB.questLogPinsAll == true
    local groups = {}
    for _, quest in ipairs(QuestLogPins.collectQuests()) do
        local spots, spotNames
        if quest.complete or showAll then
            spots, spotNames = QuestLogPins.turnInSpotsForQuest(quest.id)
        end
        if spots then
            local entry = questIndex[quest.id]
            if (not quest.title or quest.title == "" or isSecret(quest.title)) and entry then
                quest.title = ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(entry) or nil
            end
            local seenSpot = {}
            for _, sp in ipairs(spots) do
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
                                npcName = (npc and ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(npc))
                                    or (spotNames and spotNames[key]) or nil }
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
    if QuestLogPins.rescaleGivers and QuestLogPins.rescaleGivers(canvasFrame, cw, ch, cScale) then any = true end
    if not any then return end
    lastRescaleAt = GetTime()
    if not regroupPending and C_Timer and C_Timer.After then
        regroupPending = true
        C_Timer.After(REGROUP_DELAY, regroupWhenSettled)
    end
end

-- quest log changes: redraw only while the map is open
local events = CreateFrame("Frame")
for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "PLAYER_LEVEL_UP" }) do
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
    -- kept for good (the entry above goes once the quest is turned in): who
    -- gives the quest, for the quest giver marks; shared with other players
    if ns.DB then
        if type(ns.DB.questGivers) ~= "table" then ns.DB.questGivers = {} end
        local sources = ns.QuestSources
        local spot = sources and sources.playerSpot and sources.playerSpot()
        ns.DB.questGivers[questID] = { key = starter, spot = spot }
        if QuestLogPins.resetNpcQuests then QuestLogPins.resetNpcQuests() end
    end
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
        local turned = questID and not isSecret(questID) and turnedInSet(true)
        if turned then turned[questID] = true end
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
            if info.noGiver then
                givers = {}
            elseif info.sure and t < n then
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
    -- quest givers checked in the game: built-in data (givers[questID] =
    -- { "npc", ID, ... }) and the ones learned here or shared by other players
    if qd and type(qd.givers) == "table" then
        for questID, row in pairs(qd.givers) do
            if type(row) == "table" and row[1] == "npc" and type(row[2]) == "number" then
                setAdd(npcGives, row[2], questID)
            end
        end
    end
    local learned = ns.DB and type(ns.DB.questGivers) == "table" and ns.DB.questGivers
    for questID, rec in pairs(learned or {}) do
        local npcId = type(rec) == "table" and type(rec.key) == "string" and tonumber(rec.key:match("^npc:(%d+)$"))
        if type(questID) == "number" and npcId then setAdd(npcGives, npcId, questID) end
    end
    -- quests an NPC was seen offering (this player or others)
    offerNpcSpots = {}
    for key, row in pairs(offerStore() or {}) do
        local npcId, questID = tostring(key):match("^(%d+):(%d+)$")
        npcId, questID = tonumber(npcId), tonumber(questID)
        if npcId and questID and (offerVotes(npcId, questID)) > 0 then
            setAdd(npcGives, npcId, questID)
            if type(row) == "table" and type(row.spot) == "table" and not entryByKey["npc:" .. npcId] then
                offerNpcSpots[npcId] = row.spot
            end
        end
    end
end

-- a quest with a condition the addon can't check: marked in the data, or not
-- offered to players who met everything known (and never seen offered)
local function questConditional(questID, npcId, me)
    local entry = questIndex and questIndex[questID]
    if entry and type(entry.flags) == "number" and math.floor(entry.flags / 2) % 2 == 1 then return true end
    if npcId and offerSaysNo(npcId, questID, me) then return true end
    return false
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
    buildNpcQuests()
    if not (npcGives and npcTakes) then return {} end
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

-- a repeatable quest this character has done before
local function repeatDone(questID)
    local set = turnedInSet(false)
    return set ~= nil and set[questID] == true and not questDone(questID)
end
QuestLogPins.repeatDone = repeatDone

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

-- Holiday and event quests, donations and hand-ins are not regular quests to
-- go and take: left out by their quest category, or by their English name
-- when the data has no category for them.
local SPECIAL_SORTS = {
    [-22] = true,   -- seasonal (winter festival, harvest festival, ...)
    [-41] = true,   -- day of the dead
    [-284] = true,  -- special (children's week, ...)
    [-364] = true,  -- darkmoon faire
    [-365] = true,  -- war effort supplies
    [-366] = true,  -- lunar festival
    [-367] = true,  -- reputation hand-ins (commendation signets)
    [-368] = true,  -- invasion
    [-369] = true,  -- midsummer
    [-370] = true,  -- brewfest
    [-374] = true,  -- noblegarden
    [-375] = true,  -- pilgrim's bounty
    [-376] = true,  -- love is in the air
    [-666] = true,  -- other events
    [-344] = true,  -- legendary item quests
    [-641] = true, [-644] = true,   -- seasonal content not on this server
    -- holiday numbering used by the level table
    [-1001] = true, [-1002] = true, [-1003] = true, [-1004] = true, [-1005] = true, [-1006] = true,
    -- battleground quests (PvP, not quests to go and take while levelling)
    [-25] = true, [2597] = true, [3277] = true, [3358] = true,
}

-- profession quests: only for characters with that profession
local PROFESSION_SORTS = {
    [-181] = 171, [-121] = 164, [-304] = 185, [-201] = 202, [-324] = 129, [-101] = 356,
    [-24] = 182, [-182] = 165, [-264] = 197,
}
local SPECIAL_NAMES = {
    "donation of", "additional runecloth", "commendation signet", "^the horde needs", "^the alliance needs",
    "great%-?father winter", "winter veil", "hallow's end", "lunar", " the elder$", "darkmoon",
    "midsummer", "fire festival", "brewfest", "noblegarden", "love is in the air", "children's week",
    "wrapped present", "treats for",
    -- war effort rewards and scourge invasion hand-ins
    "saving the best for last", "^argent dawn ", "light's hope chapel", "blessed wizard oil",
    "major healing potion", "major mana potion", "the keeper's call", "investigate the scourge",
    "necrotic",
}
local specialCache = {}

local function specialQuest(questID, q)
    local cached = specialCache[questID]
    if cached ~= nil then return cached end
    local special = (q and ((q.sort and SPECIAL_SORTS[q.sort]) or (q.cat and SPECIAL_SORTS[q.cat]))) and true or false
    if not special then
        local entry = questIndex and questIndex[questID]
        local name = entry and entry.names and entry.names.enUS
        if type(name) == "string" then
            name = string.lower(name)
            for _, pattern in ipairs(SPECIAL_NAMES) do
                if name:find(pattern) then special = true; break end
            end
        end
    end
    specialCache[questID] = special
    return special
end

-- nil when this character can't take the quest (done, in the log, other side,
-- other class, quest before it not done, far above the character's level,
-- holiday / donation quest)
-- quest info from the game's own data, filled in from the addon's level
-- table (Data/QuestLevels.lua) when the game data has no entry
local mergedQuests = {}
local function questInfo(questID)
    local merged = mergedQuests[questID]
    if merged ~= nil then return merged or nil end
    local qd = ns.QuestData and ns.QuestData()
    local q = qd and type(qd.quests) == "table" and qd.quests[questID] or nil
    local extra = ns.QuestLevels and ns.QuestLevels[questID]
    if extra then
        local copy = {}
        if q then for k, v in pairs(q) do copy[k] = v end end
        if not (tonumber(copy.lvl) and copy.lvl > 0) then copy.lvl, copy.min = extra[1], extra[2] end
        copy.side, copy.classMask = extra[3], extra[4]
        if not copy.sort or copy.sort == 0 then copy.sort = extra[5] end
        copy.cat = extra[5]
        copy.needDone, copy.needLog, copy.blockedBy = extra[6], extra[7], extra[8]
        q = copy
    end
    mergedQuests[questID] = q or false
    return q
end

-- false when the quest is for the other side or another class / race
local function requirementsOf(questID)
    local all = ns.QuestRequirements and ns.QuestRequirements()
    local r = all and all[questID]
    return type(r) == "table" and r or nil
end

local function maskHas(mask, b)
    if not (mask and mask > 0 and b and bit and bit.band) then return true end
    return bit.band(mask, b) ~= 0
end

local function questForMe(questID, me)
    local req = requirementsOf(questID)
    if req then
        if not maskHas(tonumber(req[1]), me.raceBit) then return false end
        if not maskHas(tonumber(req[2]), me.classBit) then return false end
    end
    local q = questInfo(questID)
    if not q then return true end
    if not req then
        if q.side == 1 and me.faction == "Horde" then return false end
        if q.side == 2 and me.faction == "Alliance" then return false end
        if q.classMask and q.classMask > 0 and me.classBit and bit and bit.band
            and bit.band(q.classMask, me.classBit) == 0 then return false end
    end
    if q.races and me.raceBit and bit and bit.band and bit.band(q.races, me.raceBit) == 0 then return false end
    return true
end

-- a quest to complete first: one ID, or a list where any one will do. A quest
-- this character can never take (other side, class or race) doesn't hold it back.
local function requirementMet(need, me)
    if type(need) == "number" then
        return questDone(need) or not questForMe(need, me)
    end
    if type(need) ~= "table" then return true end
    local anyForMe = false
    for _, id in ipairs(need) do
        if questDone(id) then return true end
        if questForMe(id, me) then anyForMe = true end
    end
    return not anyForMe
end

-- false when another quest that rules this one out was taken (it can never
-- be taken then)
local function notBlocked(q, questID)
    local req = requirementsOf(questID)
    for _, list in ipairs({ q and q.blockedBy, req and req[8] }) do
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if questDone(id) or questInLog(id) then return false end
            end
        end
    end
    return true
end

-- false while an earlier quest still has to be done (or be in the log)
local function prerequisitesMet(q, me, questID)
    local req = requirementsOf(questID)
    if req then
        if type(req[5]) == "table" then
            for _, id in ipairs(req[5]) do
                if not requirementMet(id, me) then return false end
            end
        end
        if type(req[6]) == "table" and #req[6] > 0 and not requirementMet(req[6], me) then return false end
        if type(req[7]) == "table" and #req[7] > 0 then
            local any = false
            for _, id in ipairs(req[7]) do
                if questInLog(id) then any = true; break end
            end
            if not any then return false end
        end
    end
    if not q then return true end
    if type(q.needDone) == "table" then
        for _, need in ipairs(q.needDone) do
            if not requirementMet(need, me) then return false end
        end
    end
    if type(q.needLog) == "table" and #q.needLog > 0 then
        local any = false
        for _, id in ipairs(q.needLog) do
            if id > 0 and questInLog(id) then any = true; break end
            if id < 0 and (questInLog(-id) or questDone(-id)) then any = true; break end
        end
        if not any then return false end
    end
    return true
end

local function takeable(questID, me, ignoreNotOffered)
    if questDone(questID) or questInLog(questID) then return nil end
    if not ignoreNotOffered then
        local notOffered = notOfferedSet()
        local seenAt = notOffered and tonumber(notOffered[questID])
        if seenAt and seenAt >= (me.level or 0) then return nil end
    end
    local q = questInfo(questID)
    if specialQuest(questID, q) then return nil end
    if not questForMe(questID, me) then return nil end
    if not q and not notBlocked(nil, questID) then return nil end
    if q then
        local skill = PROFESSION_SORTS[q.sort or 0] or PROFESSION_SORTS[q.cat or 0]
        if skill and me.skills and not me.skills[skill] then return nil end
        local req = requirementsOf(questID)
        local reqSkill = req and tonumber(req[3]) or 0
        if reqSkill > 0 and me.skills then
            local have = me.skills[reqSkill]
            if not have then return nil end
            local need = tonumber(req[4]) or 0
            if type(have) == "number" and need > have then
                local copy = {}
                for k, v in pairs(q) do copy[k] = v end
                copy.needRank = need
                q = copy
            end
        end
        local class = CLASS_SORTS[q.sort or 0]
        if class and class ~= me.class then return nil end
        if (q.min or 0) > me.level + LEVEL_AHEAD then return nil end
        if not notBlocked(q, questID) then return nil end
    end
    -- an earlier quest still to do: listed as [prereq], not hidden
    local needPrev = not prerequisitesMet(q, me, questID)
    local prev = prevQuest[questID]
    if prev and not questDone(prev) then needPrev = true end
    if needPrev then
        local copy = {}
        for k, v in pairs(q or {}) do copy[k] = v end
        copy.needPrev = true
        return copy
    end
    return q or {}
end

local function playerInfo()
    local level = (UnitLevel and UnitLevel("player")) or 1
    local _, class, classID = UnitClass("player")
    local raceID = select(3, UnitRace("player"))
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    -- professions this character has (skill line IDs); nil when unknown
    local skills
    if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
        local results = { pcall(GetProfessions) }
        if results[1] then
            skills = {}
            for i = 2, 7 do   -- primary 1, primary 2, archaeology, fishing, cooking, first aid (any may be nil)
                local index = results[i]
                if type(index) == "number" then
                    local okInfo, _, _, rank, _, _, _, skillLine = pcall(GetProfessionInfo, index)
                    if okInfo and type(skillLine) == "number" then
                        skills[skillLine] = (type(rank) == "number" and not isSecret(rank) and rank) or true
                    end
                end
            end
        end
    end
    return { level = tonumber(level) or 1, class = class, faction = faction, skills = skills,
        raceID = (type(raceID) == "number" and not isSecret(raceID)) and raceID or nil,
        classID = (type(classID) == "number" and not isSecret(classID)) and classID or nil,
        classBit = (type(classID) == "number" and classID >= 1 and classID <= 31) and 2 ^ (classID - 1) or nil,
        raceBit = (type(raceID) == "number" and raceID >= 1 and raceID <= 31) and 2 ^ (raceID - 1) or nil }
end

-- { { text, r, g, b }, ... } for one NPC ID
-- nowOnly: only quests that can surely be taken now (map marks)
function QuestLogPins.npcQuestLines(npcId, me, nowOnly)
    buildNpcQuests()
    me = me or playerInfo()
    local found = {}
    -- finished quests turned in here: the built-in data, plus the turn-in NPC
    -- known from the learned / installed sources
    local takes = {}
    for questID in pairs(npcTakes[npcId] or {}) do takes[questID] = true end
    local sources = ns.QuestSources
    if sources and sources.turnInEntries then
        for _, quest in ipairs(QuestLogPins.collectQuests()) do
            if quest.complete and not takes[quest.id] then
                local ok, entries = pcall(sources.turnInEntries, quest.id)
                for _, e in ipairs(ok and type(entries) == "table" and entries or {}) do
                    if e.kind == "npc" and e.id == npcId then takes[quest.id] = true break end
                end
            end
        end
    end
    for questID in pairs(takes) do
        if questInLog(questID) and QuestLogPins.isQuestComplete(questID) then
            found[#found + 1] = { order = 0, level = 0, text = "? " .. questName(questID) .. " |cff8fd19e(" .. ns:L("NPC_TT_TURNIN") .. ")|r",
                r = 0.25, g = 1, b = 0.35 }
        end
    end
    -- grey quests (far below the character) are left out, and quests that
    -- share a name (one per race or side) are listed once
    local floorLevel = QuestLogPins.trivialFloor and QuestLogPins.trivialFloor(me.level) or (me.level - 5)
    local sameName = {}
    for questID in pairs(npcGives[npcId] or {}) do
        local q = takeable(questID, me)
        local level = q and tonumber(q.lvl) or 0
        if q and (level <= 0 or level > floorLevel)
            and not (nowOnly and not (q.needPrev or q.needRank or (QuestLogPins.takeNow and QuestLogPins.takeNow(q, me, floorLevel)))) then
            local name = questName(questID)
            -- an earlier quest still to do: greyed like a quest above your level
            local tooHigh = (q.min or 0) > me.level or q.needPrev == true or q.needRank ~= nil
            local known = level > 0
            local prefix = known and ("[" .. level .. "] ") or ""
            local again = repeatDone(questID)
            -- a condition the addon can't check (reputation, a script, an event
            -- NPC...): shown, but marked
            if questConditional(questID, npcId, me) then
                name = ns:L("NPC_TT_CONDITION") .. " " .. name
            end
            if q.needPrev then name = ns:L("NPC_TT_PREREQ") .. " " .. name end
            local text = (again and "? " or "! ") .. prefix .. name
            if (q.min or 0) > me.level then text = text .. " (" .. string.format(ns:L("NPC_TT_FROM_LEVEL"), q.min) .. ")" end
            if q.needRank then text = text .. " (" .. string.format(ns:L("NPC_TT_FROM_SKILL"), q.needRank) .. ")" end
            if not sameName[text] then
                sameName[text] = true
                -- yellow: can take now · pale yellow: level not known · grey: later
                -- · blue: a repeatable quest done before
                local r = tooHigh and 0.6 or known and 1 or 0.85
                local g = tooHigh and 0.6 or known and 0.82 or 0.78
                local b = tooHigh and 0.6 or known and 0 or 0.5
                if again and not tooHigh then r, g, b = 0.35, 0.7, 1 end
                found[#found + 1] = { order = tooHigh and 3 or known and 1 or 2, level = level, text = text,
                    r = r, g = g, b = b }
            end
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

-----------------------------------------------------------------------------
-- Quest givers on the World Map: a yellow "!" over each NPC with a quest this
-- character can take now, a grey one when its quests are a few levels away.
-- Same rules as the NPC tooltip. Spots are worked out once per map.
-----------------------------------------------------------------------------
local ICON_GIVER = "Interface\\GossipFrame\\AvailableQuestIcon"
local giverPins = {}
local giverSpotsByMap = {}     -- mapID -> { { npcId, sp, mx, my }, ... }

-- a quest giver learned or received: the NPC lists are made again
function QuestLogPins.resetNpcQuests()
    npcGives, npcTakes, prevQuest = nil, nil, nil
    giverSpotsByMap = {}
end

-- When the player talks to an NPC, the game lists the quests it offers now.
-- A quest the data gives to that NPC, which this character could take by the
-- data, but which is not in that list is remembered as not offered (see
-- notOfferedSet); one offered again is forgotten.
local function plainValue(v)
    if v == nil or isSecret(v) then return nil end
    return v
end

function QuestLogPins.noteOffered(npcId, offeredIDs, offeredTitles)
    if not npcId then return end
    buildNpcQuests()
    local me = playerInfo()
    local changed = false
    -- every quest the NPC offered is shared (also ones the data doesn't know,
    -- from NPCs it has no quests for); an NPC the data has no spot for is
    -- shared with where it stands
    local known = entryByKey and entryByKey["npc:" .. npcId]
    local spot = not known and playerSpot() or nil
    for questID in pairs(offeredIDs) do
        if type(questID) == "number" and noteOwnOffer(npcId, questID, 1, me, spot) then changed = true end
    end
    local gives = npcGives and npcGives[npcId]
    local set = notOfferedSet(true)
    for questID in pairs(gives and set and gives or {}) do
        local q = takeable(questID, me, true)
        local offered = offeredIDs[questID] or offeredTitles[questName(questID)]
        if offered then
            if set[questID] then set[questID] = nil; changed = true end
            if noteOwnOffer(npcId, questID, 1, me, spot) then changed = true end
        elseif q and not q.needPrev and not q.needRank and (tonumber(q.min) or 0) <= me.level then
            if set[questID] ~= me.level then set[questID] = me.level; changed = true end
            if noteOwnOffer(npcId, questID, 0, me, spot) then changed = true end
        end
    end
    if changed then QuestLogPins.resetNpcQuests() end
    if changed and ns.RefreshQuestLogPins then pcall(ns.RefreshQuestLogPins) end
end

local function talkingNpcId()
    local guid = plainValue(UnitGUID and UnitGUID("npc"))
    local key = guid and guidToStarter(guid)
    local id = key and key:match("^npc:(%d+)$")
    return tonumber(id)
end

-- shared record kind "Q": "npcID,questID,state,level,raceID,classID[,continent,x,y]"
-- (state 1 offered, 0 not; the spot only for an NPC the data has no spot for)
if ns.Share and type(ns.Share.RegisterKind) == "function" then
    ns.Share.RegisterKind(OFFER_KIND, {
        own = function()
            local out = {}
            for key, row in pairs(offerStore() or {}) do
                local own = type(row) == "table" and row.own
                local npcId, questID = tostring(key):match("^(%d+):(%d+)$")
                if npcId and type(own) == "table" and (own[1] == 0 or own[1] == 1) then
                    local body = string.format("%d,%d,%d,%d,%d,%d", tonumber(npcId), tonumber(questID), own[1],
                        tonumber(own[2]) or 0, tonumber(own[3]) or 0, tonumber(own[4]) or 0)
                    local sp = row.ownSpot and row.spot
                    if type(sp) == "table" and tonumber(sp[1]) and tonumber(sp[2]) and tonumber(sp[3]) then
                        body = body .. string.format(",%d,%.1f,%.1f", sp[1], sp[2], sp[3])
                    end
                    out[#out + 1] = body
                end
            end
            return out
        end,
        receive = function(body, hash)
            local npcId, questID, state, level, rest = body:match("^(%d+),(%d+),([01]),(%d+),?(.*)$")
            npcId, questID, state, level = tonumber(npcId), tonumber(questID), tonumber(state), tonumber(level)
            if not (npcId and questID and state and level) or npcId < 1 or npcId > 10000000
                or questID < 1 or questID > 1000000 or level > 200 then return false end
            local raceID, classID, cont, x, y = (rest or ""):match("^(%d+),(%d+),?(%-?%d*),?(%-?[%d%.]*),?(%-?[%d%.]*)$")
            raceID, classID = tonumber(raceID) or 0, tonumber(classID) or 0
            if raceID > 100 or classID > 100 then return false end
            cont, x, y = tonumber(cont), tonumber(x), tonumber(y)
            local spot = (cont and x and y and cont >= 0 and cont < 10000 and math.abs(x) < 100000 and math.abs(y) < 100000)
                and { cont, x, y, 0 } or nil
            local store = offerStore()
            if not store then return false end
            local key = npcId .. ":" .. questID
            local row = type(store[key]) == "table" and store[key] or {}
            store[key] = row
            row.peers = type(row.peers) == "table" and row.peers or {}
            local h = tostring(hash or "?")
            if row.peers[h] == nil then
                local n = 0
                for _ in pairs(row.peers) do n = n + 1 end
                if n >= MAX_OFFER_PEERS then return false end
            elseif type(row.peers[h]) == "table" and row.peers[h][1] == state then
                return false
            end
            row.peers[h] = { state, raceID, classID }
            if spot and not row.spot then row.spot = spot end
            return true
        end,
    })
end

local offerEvents = CreateFrame("Frame")
local listSeenAt, listNpc = -100, nil
offerEvents:SetScript("OnEvent", function(_, event)
    local ok = pcall(function()
        local npcId = talkingNpcId()
        if not npcId then return end
        local ids, titles = {}, {}
        if event == "GOSSIP_SHOW" then
            local gossip = C_GossipInfo
            if type(gossip) ~= "table" or type(gossip.GetAvailableQuests) ~= "function" then return end
            listSeenAt, listNpc = GetTime(), npcId
            for _, info in ipairs(gossip.GetAvailableQuests() or {}) do
                local id = type(info) == "table" and plainValue(info.questID)
                if type(id) == "number" then ids[id] = true end
                local title = type(info) == "table" and plainValue(info.title)
                if type(title) == "string" then titles[title] = true end
            end
        elseif event == "QUEST_GREETING" then
            if type(GetNumAvailableQuests) ~= "function" or type(GetAvailableTitle) ~= "function" then return end
            listSeenAt, listNpc = GetTime(), npcId
            for i = 1, (plainValue(GetNumAvailableQuests()) or 0) do
                local title = plainValue(GetAvailableTitle(i))
                if type(title) == "string" then titles[title] = true end
            end
        elseif event == "QUEST_DETAIL" then
            -- straight to one quest (no list first): that NPC offers only it;
            -- picked from this NPC's list a moment ago: not the whole offer
            if listNpc == npcId and GetTime() - listSeenAt < 60 then return end
            local id = type(GetQuestID) == "function" and plainValue(GetQuestID())
            if type(id) ~= "number" or id <= 0 then return end
            ids[id] = true
        elseif event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
            -- straight to a quest being handed in (no list first): the NPC
            -- has no quest to offer now, or the game would list them first
            if listNpc == npcId and GetTime() - listSeenAt < 60 then return end
        end
        QuestLogPins.noteOffered(npcId, ids, titles)
    end)
    if not ok then return end
end)
for _, event in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE" }) do
    pcall(offerEvents.RegisterEvent, offerEvents, event)
end

local function giverSpotsFor(mapID, project)
    local cached = giverSpotsByMap[mapID]
    if cached then return cached end
    cached = {}
    for npcId in pairs(npcGives) do
        local entry = entryByKey["npc:" .. npcId]
        local spawns = entry and entry.spawns or (offerNpcSpots[npcId] and { offerNpcSpots[npcId] }) or {}
        for _, sp in ipairs(spawns) do
            local mapID2, mx, my = project(sp, mapID)
            if mx and my and mapID2 == mapID then
                cached[#cached + 1] = { npcId = npcId, sp = sp, mx = mx, my = my }
            end
        end
    end
    giverSpotsByMap[mapID] = cached
    return cached
end

-- Quests far below the character's level (grey in the game) are left out,
-- like the game's own map does.
local function trivialBelow(level)
    if type(UnitQuestTrivialLevelRange) == "function" then
        local ok, range = pcall(UnitQuestTrivialLevelRange, "player")
        if ok and type(range) == "number" and not isSecret(range) and range > 0 then return level - range end
    end
    return level - 5
end
QuestLogPins.trivialFloor = trivialBelow

-- The map shows only quests the character can surely take now: level known,
-- reachable, and not grey. Quests without a level in the data stay off the
-- map (they are still listed on the NPC's own tooltip).
-- repeat: every quest it has now is a repeatable one done before (blue "?")
local STATE_RANK = { now = 3, ["repeat"] = 2.5, unknown = 2, soon = 1 }

local function takeNow(q, me, floorLevel)
    if q and (q.needPrev or q.needRank) then return false end
    local lvl = q and tonumber(q.lvl)
    return lvl and lvl > 0 and q.min and lvl > floorLevel and q.min <= me.level or false
end
QuestLogPins.takeNow = takeNow

local function giverState(npcId, me)
    local floorLevel = trivialBelow(me.level)
    local state
    for questID in pairs(npcGives[npcId] or {}) do
        local q = takeable(questID, me)
        if takeNow(q, me, floorLevel) and questConditional(questID, npcId, me) then
            -- [condition] quests (reputation, a script, an event NPC): grey "!"
            if not state then state = "soon" end
        elseif takeNow(q, me, floorLevel) then
            if not repeatDone(questID) then return "now" end
            state = "repeat"
        elseif q and (q.needPrev or q.needRank) and not state then
            -- only a quest that waits for an earlier one ([prereq]): grey "!"
            local lvl = tonumber(q.lvl)
            if lvl and lvl > floorLevel then state = "soon" end
        end
    end
    return state
end

local function obtainGiverPin(index)
    local pin = giverPins[index]
    if pin then return pin end
    pin = CreateFrame("Button", nil, QuestLogPins.canvas())
    pin:EnableMouse(true)
    pin:RegisterForClicks("LeftButtonUp")
    setPropagateClicks(pin, false)
    pin:SetSize(15, 15)
    pin:SetFrameStrata("HIGH")
    local disc = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
    pin.rim = pin:CreateTexture(nil, "BACKGROUND", nil, 0)
    pin.rim:SetTexture(disc)
    pin.rim:SetPoint("CENTER")
    pin.rim:SetSize(16, 16)
    pin.back = pin:CreateTexture(nil, "BACKGROUND", nil, 1)
    pin.back:SetTexture(disc)
    pin.back:SetPoint("CENTER")
    pin.back:SetSize(14, 14)
    pin.back:SetVertexColor(0.08, 0.06, 0.04, 0.92)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetPoint("CENTER")
    pin.icon:SetSize(12, 12)
    pin.icon:SetTexture(ICON_GIVER)
    pin:SetScript("OnEnter", function(self)
        local group = self.group
        if not group then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local me = playerInfo()
        local first = true
        for _, npcId in ipairs(group.npcIds) do
            local lines = QuestLogPins.npcQuestLines(npcId, me, true)
            if #lines > 0 then
                local entry = entryByKey["npc:" .. npcId]
                local name = entry and ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(entry) or ("#" .. npcId)
                if first then GameTooltip:SetText(name, unpack(Theme.accent)) else GameTooltip:AddLine(name, unpack(Theme.accent)) end
                first = false
                for _, l in ipairs(lines) do GameTooltip:AddLine(l.text, l.r, l.g, l.b) end
            end
        end
        if first then GameTooltip:SetText("EzWoW - Quest", unpack(Theme.accent)) end
        GameTooltip:AddLine(ns:L("questGiverHint"), unpack(Theme.muted))
        GameTooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
        GameTooltip:Show()
        if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:HookScript("OnEnter", raisePin)
    pin:HookScript("OnLeave", lowerPin)
    pin:SetScript("OnClick", function(self)
        local sp = self.group and self.group.spawn
        if sp then
            local npcId = self.group.npcIds and self.group.npcIds[1]
            local entry = npcId and entryByKey["npc:" .. npcId]
            local name = entry and ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(entry) or ""
            ns.ApplyWaypointForSpawn(sp, name)
        end
    end)
    ns.PassMapRightClicks(pin)
    giverPins[index] = pin
    return pin
end

function QuestLogPins.hideGivers()
    for _, pin in ipairs(giverPins) do pin:Hide() end
end

function QuestLogPins.refreshGivers(mapID, project, canvasFrame, cw, ch, cScale)
    QuestLogPins.hideGivers()
    if not (ns.DB and ns.DB.questGiverPins ~= false) then return end
    buildNpcQuests()
    local me = playerInfo()
    local states = {}
    local groups = {}
    for _, spot in ipairs(giverSpotsFor(mapID, project)) do
        local state = states[spot.npcId]
        if state == nil then
            state = giverState(spot.npcId, me) or false
            states[spot.npcId] = state
        end
        if state then
            local px, py = spot.mx * cw, spot.my * ch
            local group
            for _, g in ipairs(groups) do
                if math.abs(g.px - px) * cScale < MERGE_PIXELS and math.abs(g.py - py) * cScale < MERGE_PIXELS then
                    group = g
                    break
                end
            end
            if not group then
                group = { px = px, py = py, cw = cw, ch = ch, spawn = spot.sp, npcIds = {}, seen = {} }
                groups[#groups + 1] = group
            end
            if not group.seen[spot.npcId] then
                group.seen[spot.npcId] = true
                group.npcIds[#group.npcIds + 1] = spot.npcId
            end
            if not group.state or STATE_RANK[state] > STATE_RANK[group.state] then group.state = state end
        end
    end
    for index, group in ipairs(groups) do
        local pin = obtainGiverPin(index)
        local now, unknown = group.state == "now", group.state == "unknown"
        local again = group.state == "repeat"
        pin:SetParent(canvasFrame)
        pin:SetFrameLevel((canvasFrame:GetFrameLevel() or 10) + (now and 180 or again and 178 or unknown and 175 or 170))
        pin.group = group
        if again then
            -- blue "?": only repeatable quests done before
            pin.icon:SetTexture(ICON_READY)
            pin.icon:SetDesaturated(true)
            pin.icon:SetVertexColor(0.35, 0.7, 1)
            pin.icon:SetAlpha(1)
            pin.rim:SetVertexColor(0.35, 0.65, 1, 0.95)
        else
            -- yellow: can take now · faint yellow: level not known · grey: a few levels later
            pin.icon:SetTexture(ICON_GIVER)
            pin.icon:SetVertexColor(1, 1, 1)
            pin.icon:SetDesaturated(not (now or unknown))
            pin.icon:SetAlpha(now and 1 or unknown and 0.55 or 0.75)
            pin.rim:SetVertexColor(now and 0.95 or 0.6, now and 0.85 or 0.6, now and 0.45 or 0.6, now and 0.95 or 0.6)
        end
        QuestLogPins.anchorPin(pin, canvasFrame, cw, ch, cScale)
        pin:Show()
    end
end

function QuestLogPins.rescaleGivers(canvasFrame, cw, ch, cScale)
    local any = false
    for _, pin in ipairs(giverPins) do
        if pin:IsShown() and pin.group then
            QuestLogPins.anchorPin(pin, canvasFrame, cw, ch, cScale)
            any = true
        end
    end
    return any
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
