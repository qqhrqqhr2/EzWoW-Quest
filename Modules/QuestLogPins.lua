--===========================================================================
-- EzWoW - Quest
-- Modules/QuestLogPins.lua : World Map marks for quests in the player's quest log
--===========================================================================
-- Quests whose objectives are done get a yellow "?" at their turn-in spots
-- (from Map Finder's quest locations). Quests still in progress
-- can be shown too (grey "?", option). Clicking a mark sets a map waypoint.
local _, ns = ...
-- every EzWoW mark on the maps can be turned off at once, and the marks only
-- the shared records make apart (Libs/EzWoWShare MapMarksOn / SharedMarksOn)
local function ezMapOn(sharedOnly)
    local share = _G.EzWoW_Share
    local fn = type(share) == "table" and share[sharedOnly and "SharedMarksOn" or "MapMarksOn"]
    if type(fn) ~= "function" then return true end
    local ok, on = pcall(fn)
    return not ok or on ~= false
end
-- every EzWoW line on the game's tooltips can be turned off at once (Game Menu >
-- Options > AddOns > EzWoW - Data Sharing; Libs/EzWoWShare TooltipLinesOn)
local function ezTipsOn()
    local share = _G.EzWoW_Share
    if type(share) ~= "table" or type(share.TooltipLinesOn) ~= "function" then return true end
    local ok, on = pcall(share.TooltipLinesOn)
    return not ok or on ~= false
end
-- frames made on the World Map are made without a parent and put in after
-- (Libs/EzWoWGamePad MakeFrame: keeps the game's gamepad cursor untainted)
local CreateFrame = (ns.GamePad and ns.GamePad.MakeFrame) or CreateFrame

-- The "EzWoW - ..." name line at the end of tooltip additions is drawn small.
-- Shared by the EzWoW addons: the first one loaded sets it up.
if not (_G.EzWoWTooltipTagSizer and (tonumber(_G.EzWoWTooltipTagSizer.version) or 0) >= 4) then
    local sizer = {}
    sizer.version = 4
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
    -- the size goes on the line itself too: a size another addon put on the
    -- line (a font addon) would stay over the font object otherwise
    local function setSize(fs, font)
        if not (font and font.GetFont and fs.SetFont) then return end
        local path, size, flags = font:GetFont()
        if path and size then fs:SetFont(path, size, flags or "") end
    end
    local function fit(fs, tag)
        if not fs then return end
        if tag then
            if not original[fs] then original[fs] = fs:GetFontObject() or GameTooltipText end
            if tagFont() then
                fs:SetFontObject(smallFont)
                setSize(fs, smallFont)
            end
            fs:SetTextColor(0.5, 0.5, 0.5)
        elseif original[fs] then
            fs:SetFontObject(original[fs])
            setSize(fs, original[fs])
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
                setSize(fs, font)
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

-- One mark of all EzWoW map marks is in front: the last one the mouse was on
-- (above every other mark, its label too). It stays in front after the mouse
-- leaves, until another mark is hovered; the one before goes back to its place.
-- Kept in a table all EzWoW addons share (EzWoWMapPinFront).
local function mapPinFront()
    local f = _G.EzWoWMapPinFront
    if type(f) == "table" and (tonumber(f.v) or 0) >= 2 then return f end
    f = { v = 2 }
    local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
        FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
    function f.Restore(pin)
        if not pin then return end
        if pin.ezBaseLevel ~= nil then
            if pin.ezBaseStrata then pcall(pin.SetFrameStrata, pin, pin.ezBaseStrata) end
            -- a level its addon gave it since (the marks were drawn again) stays
            if pin:GetFrameLevel() == pin.ezFrontLevel then pcall(pin.SetFrameLevel, pin, pin.ezBaseLevel) end
        end
        pin.ezBaseLevel, pin.ezBaseStrata, pin.ezFrontLevel = nil, nil, nil
        if f.pin == pin then f.pin = nil end
    end
    function f.Raise(pin)
        if not pin then return end
        if f.pin == pin then
            if pin:GetFrameLevel() == pin.ezFrontLevel then return end
            -- drawn again at its own level since it came to the front: raised from there
            pin.ezBaseLevel = pin:GetFrameLevel()
        else
            if f.pin then f.Restore(f.pin) end
            pin.ezBaseLevel, pin.ezBaseStrata = pin:GetFrameLevel(), pin:GetFrameStrata()
            f.pin = pin
        end
        -- the marks of the quest addons sit in HIGH: at least that layer
        if (STRATA[pin.ezBaseStrata] or 0) < STRATA.HIGH then pcall(pin.SetFrameStrata, pin, "HIGH") end
        local parent = pin:GetParent()
        pcall(pin.SetFrameLevel, pin, ((parent and parent:GetFrameLevel()) or 0) + 1200)
        pin.ezFrontLevel = pin:GetFrameLevel()
    end
    _G.EzWoWMapPinFront = f
    return f
end
local function raisePin(self) mapPinFront().Raise(self) end
-- (the mark stays in front when the mouse leaves)
local function lowerPin() end

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

-- NPCs and objects Map Finder adds during the session (ones checked in the game
-- that its data lacks) are taken in at the next lookup, kept apart from the
-- data's own entries (entryByKey stays "the data has it").
local lateByKey, indexedData, indexedCount = {}, nil, 0

local function catchUpIndexes()
    local data = indexedData
    if type(data) ~= "table" or not entryByKey then return end
    local n = #data
    if n <= indexedCount then return end
    for i = indexedCount + 1, n do
        local e = data[i]
        if type(e) == "table" and (e.kind == "npc" or e.kind == "object") and e.id and type(e.spawns) == "table" then
            local key = e.kind .. ":" .. e.id
            if not entryByKey[key] and not lateByKey[key] then lateByKey[key] = e end
        end
    end
    indexedCount = n
end

-- the entry of an NPC / object: the data's, else one Map Finder added this session
local function entryOf(kind, id)
    if not (entryByKey and id) then return nil end
    local key = kind .. ":" .. id
    local e = entryByKey[key] or lateByKey[key]
    if e then return e end
    catchUpIndexes()
    return lateByKey[key]
end

-- One walk over every spawn of the data: not in combat, where the client stops a
-- script that runs too long (the index is built after login, out of combat). It is
-- built in locals first, so a walk stopped half way leaves no partial index behind.
function QuestLogPins.buildIndexes()
    if questIndex then
        catchUpIndexes()
        return
    end
    if not ns.HasMapFinder() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local data = ns.MapData()
    local quests, bySpot, byKey = {}, {}, {}
    for _, e in ipairs(data) do
        if (e.kind == "npc" or e.kind == "object") and e.id and e.spawns then
            byKey[e.kind .. ":" .. e.id] = byKey[e.kind .. ":" .. e.id] or e
        end
        if e.kind == "quest" and e.id then
            quests[e.id] = e
        elseif e.kind == "npc" and e.spawns then
            for _, sp in ipairs(e.spawns) do
                local key = spotKey(sp)
                if key and not bySpot[key] then bySpot[key] = e end
            end
        end
    end
    questIndex, npcBySpot, entryByKey = quests, bySpot, byKey
    lateByKey, indexedData, indexedCount = {}, data, #data
end

-- ready before the first fight: built a few seconds after each loading screen and
-- after combat, whenever it is still missing
do
    local warm = CreateFrame("Frame")
    pcall(warm.RegisterEvent, warm, "PLAYER_ENTERING_WORLD")
    pcall(warm.RegisterEvent, warm, "PLAYER_REGEN_ENABLED")
    warm:SetScript("OnEvent", function()
        if questIndex or not (C_Timer and C_Timer.After) then return end
        C_Timer.After(3, function()
            if not questIndex and not (InCombatLockdown and InCombatLockdown()) then
                pcall(QuestLogPins.buildIndexes)
            end
        end)
    end)
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

-- Notes of quests an NPC did not offer are no longer kept (an NPC may give a
-- quest only through its talk options, which the first list doesn't show).
-- What older copies noted is cleared once: the per-character list and this
-- character's own "not offered" notes in the shared records. Own "through a
-- talk option" notes go too: older copies could credit a quest from an
-- object, an item or a player to the NPC talked to before (real ones come
-- back at the next talk). The spot noted with such a note is where the
-- player stood, not the NPC: it goes too.
-- false, not nil: the shared data joins every addon's saved copy and would
-- bring a nil value back from an older copy.
-- Runs once per session after login (every addon's copy is joined by then):
-- an older copy joined first can bring such notes back in any session.
-- Notes made by this copy carry a mark (own[5] == 1) and are kept.
local notesCleared = false
local function clearNotOfferedNotes()
    if notesCleared or not ns.DB then return end
    if type(IsLoggedIn) == "function" and not IsLoggedIn() then return end
    local okStore, store = false, nil
    if ns.Share and type(ns.Share.Store) == "function" then
        okStore, store = pcall(ns.Share.Store, "Q")
    end
    if not okStore or type(store) ~= "table" then return end
    notesCleared = true
    ns.DB.questNotOffered = nil
    ns.DB.questNotOfferedVersion = nil
    ns.DB.questOwnOfferVersion = nil
    local dropped = false
    for _, row in pairs(store) do
        local own = type(row) == "table" and row.own
        if type(own) == "table" and (own[1] == 0 or own[1] == 2) and own[5] ~= 1 then
            row.own = false
            if row.ownSpot == true then row.spot = false end
            row.ownSpot = false
            dropped = true
        end
    end
    return dropped
end

-- What NPCs offered when players talked to them, shared between EzWoW users
-- (shared record kind "Q", registered below): store["npcID:questID"] =
--   { own = { state, level, raceID, classID, 1 }, peers = { [sender] = { state, raceID, classID } },
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

-- offer states: 1 offered, 2 offered through a talk option
-- ("Anything else?"), not in the NPC's first list
local OFFER_STATES = { [1] = true, [2] = true }   -- (0 from older copies is left out)
-- the talk bubble of the NPC dialog, in front of such a quest in the tooltip
local TALK_ICON = "|TInterface\\GossipFrame\\GossipGossipIcon:0|t "

-- every vote on one NPC and quest: { state, raceID, classID } (this player's own included)
-- The records shipped with the addons count as well, each player once.
local function offerVoteList(npcId, questID)
    local key = npcId .. ":" .. questID
    local store = offerStore()
    local row = store and store[key]
    if type(row) ~= "table" then row = {} end
    local share = ns.Share
    local function isOwn(h)
        return share and type(share.IsOwnHash) == "function" and share.IsOwnHash(h)
    end
    local out = {}
    if type(row.own) == "table" and OFFER_STATES[row.own[1]] then
        out[#out + 1] = { row.own[1], row.own[3], row.own[4] }
    end
    local peers = type(row.peers) == "table" and row.peers or {}
    for h, v in pairs(peers) do
        -- (older copies kept this character's own messages coming back)
        if not isOwn(h) then
            if type(v) == "table" and OFFER_STATES[v[1]] then out[#out + 1] = v
            elseif OFFER_STATES[v] then out[#out + 1] = { v } end
        end
    end
    local seed = share and type(share.Seed) == "function" and share.Seed("offers")
    local shipped = seed and seed[key]
    if type(shipped) == "table" then
        for _, v in ipairs(shipped) do
            local h = type(v) == "table" and v[4]
            if OFFER_STATES[v[1]] and h and peers[h] == nil and not isOwn(h)
                -- (a cleared own note, false, also hides the shipped copy of that note)
                and not (h == "own" and row.own ~= nil) then
                out[#out + 1] = { v[1], v[2], v[3] }
            end
        end
    end
    return out
end

-- true when players got this quest from the NPC through a talk option
local function offeredByTalk(npcId, questID)
    for _, v in ipairs(offerVoteList(npcId, questID)) do
        if v[1] == 2 then return true end
    end
    return false
end

-- offered, notOffered: how many players saw each
local function offerVotes(npcId, questID)
    local yes, no = 0, 0
    for _, v in ipairs(offerVoteList(npcId, questID)) do
        if v[1] ~= 0 then yes = yes + 1 else no = no + 1 end
    end
    return yes, no
end

-- true when only other players saw the NPC offer the quest (not this
-- character, and not only the records shipped with the addons)
local function offerFromOthers(row)
    if type(row) ~= "table" then return false end
    if type(row.own) == "table" and OFFER_STATES[row.own[1]] then return false end
    local share = ns.Share
    local isOwn = share and type(share.IsOwnHash) == "function" and share.IsOwnHash or nil
    for h, v in pairs(type(row.peers) == "table" and row.peers or {}) do
        local state = type(v) == "table" and v[1] or v
        if OFFER_STATES[state] and not (isOwn and isOwn(h)) then return true end
    end
    return false
end

-- true when the votes say this character probably can't take it there
local function offerSaysNo(npcId, questID, me)
    local mine = { yes = 0, no = 0 }
    local race, class = { yes = 0, no = 0 }, { yes = 0, no = 0 }
    local all = { yes = 0, no = 0 }
    for _, v in ipairs(offerVoteList(npcId, questID)) do
        local k = v[1] ~= 0 and "yes" or "no"
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
    -- (own, spot, ownSpot may be false: cleared, see clearNotOfferedNotes)
    if spot and type(row.spot) ~= "table" then row.spot = spot; row.ownSpot = true end
    local old = row.own
    if type(old) == "table" and old[1] == state and old[2] == me.level and old[5] == 1 then return false end
    -- 5th value 1: noted by this copy (see clearNotOfferedNotes)
    row.own = { state, me.level, me.raceID or 0, me.classID or 0, 1 }
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
-- "npc:ID" / "object:ID" -> the spot a giver record came with (learned here,
-- received or built in), for givers the data has no spot for
local giverRecordSpots = {}
-- Q records of other players in use: NPCs shown as givers only because of them
local offerUsed = 0

local function validSpot(sp)
    return type(sp) == "table" and type(sp[1]) == "number" and type(sp[2]) == "number" and type(sp[3]) == "number"
end

-- an object found in many places (a chest, a herb noted by mistake) is not
-- where a quest is handed out: such an object giver gets no map mark
local MAX_OBJECT_GIVER_SPOTS = 10

-- where a quest NPC / object stands: the data's spots (or those Map Finder
-- added this session), else the spot a record came with; nil when unknown
local function partnerSpawns(kind, id)
    local entry = entryOf(kind, id)
    if entry and type(entry.spawns) == "table" and #entry.spawns > 0 then return entry.spawns end
    local sp = (kind == "npc" and offerNpcSpots[id]) or giverRecordSpots[kind .. ":" .. id]
    return validSpot(sp) and { sp } or nil
end

-- the name of a quest NPC / object, "#ID" when it is not known
local function partnerName(kind, id)
    local name
    if ns.GetLocalizedEntityName then
        local ok, n = pcall(ns.GetLocalizedEntityName, entryOf(kind, id) or { kind = kind, id = id })
        if ok and type(n) == "string" and not isSecret(n) then name = n end
    end
    if not name or name == "" or name == tostring(id) then return "#" .. tostring(id) end
    return name
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

-- name of the NPC (or object) at a turn-in spot: the data's NPC there, else the
-- name the learned records give (spotNames: second value of turnInSpotsForQuest)
function QuestLogPins.turnInNameAt(sp, spotNames)
    QuestLogPins.buildIndexes()
    local key = spotKey(sp)
    if not key then return nil end
    local npc = npcBySpot and npcBySpot[key]
    local name = npc and ns.GetLocalizedEntityName and ns.GetLocalizedEntityName(npc)
    if type(name) == "string" and name ~= "" then return name end
    name = spotNames and spotNames[key]
    return type(name) == "string" and name ~= "" and name or nil
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

-- A second click on the same mark takes its waypoint away again, with the
-- arrow pins the quest's details started (a quest list click guides there)
local lastPinSpawn
local function hasUserWaypoint()
    if not (C_Map and C_Map.HasUserWaypoint) then return false end
    local ok, has = pcall(C_Map.HasUserWaypoint)
    return ok and has == true
end

-- true when this click removed what the same mark had set
-- (sp: the spawn, or any key that stands for the spot)
local function clearPinWaypoint(sp)
    if not (sp and lastPinSpawn == sp) then return false end
    lastPinSpawn = nil
    local api = _G.EzWoWMapFinderAPI
    local guided = api and type(api.HasPoint) == "function" and api.HasPoint() == true
    if not (guided or hasUserWaypoint()) then return false end
    if api and type(api.ClearPoint) == "function" then pcall(api.ClearPoint) end
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
    return true
end

local function rememberPinWaypoint(sp)
    lastPinSpawn = sp
end

-- Every arrow points at the clicked mark: what pointed elsewhere goes, the
-- moving arrow pin and the waypoint go to this spot
local function pointAtPin(sp, label)
    local api = _G.EzWoWMapFinderAPI
    if api and type(api.ClearPoint) == "function" then pcall(api.ClearPoint) end
    -- not in combat: that opens or moves the World Map from addon code
    if api and type(api.PointAtSpawn) == "function" and not (InCombatLockdown and InCombatLockdown()) then
        local text = label or ""
        local shown = {
            kind = "npc",
            names = setmetatable({}, { __index = function() return text end }),
            spawns = { sp },
        }
        pcall(api.PointAtSpawn, shown, 1)
    end
    if ns.ApplyWaypointForSpawn then ns.ApplyWaypointForSpawn(sp, label or "") end
end

-- A click on a mark sets the waypoint and the arrows only. The quest's
-- details are not opened from here: the quest log keeps a quest opened by
-- addon code and draws it again on every quest update, moving the map from
-- tainted code, and the map's own pins are then blocked in combat
-- (SetPassThroughButtons).

-- the same click on the quest objective marks
ns.MarkClick = {
    point = pointAtPin,
    clear = clearPinWaypoint,
    remember = rememberPinWaypoint,
}

function QuestLogPins.obtainPin(index)
    local pin = pins[index]
    if pin then return pin end
    local canvasFrame = QuestLogPins.canvas()
    pin = CreateFrame("Button", nil, canvasFrame)
    if ns.GamePad and ns.GamePad.MapMark then ns.GamePad.MapMark(pin) end
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
            local xpSuffix = ns.XP and ns.XP.questSuffix and ns.XP.questSuffix(quest.id) or ""
            GameTooltip:AddLine(ns.QuestLevelPrefix(quest.id) .. (quest.title or ("#" .. quest.id)) .. "  " .. state .. xpSuffix, 0.929, 0.957, 0.969, true)
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
        local group = self.group
        if not group then return end
        local sp = group.spawn
        if clearPinWaypoint(sp) then return end
        if sp then
            local quest = group.quests and group.quests[1]
            pointAtPin(sp, group.npcName or (quest and quest.title) or "")
            rememberPinWaypoint(sp)
        end
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
    if not ezMapOn() then return end
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
local objGives                 -- object ID -> quests it gives (a wanted poster, a book...)
local npcBuiltWithoutIndex = false   -- built while the index was missing (combat)

local function setAdd(map, key, value)
    local set = map[key]
    if not set then set = {}; map[key] = set end
    set[value] = true
end

-- a quest giver from the records: kind "npc" / "object", its ID, the quest,
-- and the spot the record came with (used when the data has no spot for it)
local function addGiver(kind, id, questID, spot)
    id, questID = tonumber(id), tonumber(questID)
    if not (id and questID) or id <= 0 or questID <= 0 then return end
    local map = (kind == "npc" and npcGives) or (kind == "object" and objGives) or nil
    if not map then return end
    setAdd(map, id, questID)
    local key = kind .. ":" .. id
    if not giverRecordSpots[key] and validSpot(spot) then giverRecordSpots[key] = spot end
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
    -- old wrong own notes must not show before the next talk
    if clearNotOfferedNotes() and npcGives and QuestLogPins.resetNpcQuests then QuestLogPins.resetNpcQuests() end
    -- an empty build made without the index is redone once the index exists
    if npcGives and not (npcBuiltWithoutIndex and questIndex) then return end
    QuestLogPins.buildIndexes()
    npcGives, npcTakes, prevQuest, objGives = {}, {}, {}, {}
    giverRecordSpots, offerUsed = {}, 0
    npcBuiltWithoutIndex = not questIndex
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
    -- quest givers (NPCs and objects) checked in the game: built-in data
    -- (givers[questID] = { "npc" | "object", ID, continent, x, y }), the ones
    -- learned here or shared by other players, and the further givers players
    -- confirmed for the same quest
    if qd and type(qd.givers) == "table" then
        for questID, row in pairs(qd.givers) do
            if type(row) == "table" then
                local spot = type(row[3]) == "number" and { row[3], row[4], row[5] } or nil
                addGiver(row[1], row[2], questID, spot)
            end
        end
    end
    local learned = ns.DB and type(ns.DB.questGivers) == "table" and ns.DB.questGivers
    for questID, rec in pairs(learned or {}) do
        if type(questID) == "number" and type(rec) == "table" and type(rec.key) == "string" then
            local kind, id = rec.key:match("^(%a+):(%d+)$")
            addGiver(kind, id, questID, rec.spot)
        end
    end
    local sources = ns.QuestSources
    local alt = sources and sources.altStore and sources.altStore("questGiversAlt")
    for questID, row in pairs(alt or {}) do
        if type(questID) == "number" and type(row) == "table" then
            for key, rec in pairs(row) do
                local kind, id
                if type(key) == "string" then kind, id = key:match("^(%a+):(%d+)$") end
                addGiver(kind, id, questID, type(rec) == "table" and rec.spot or nil)
            end
        end
    end
    -- quests an NPC was seen offering (this player or others)
    offerNpcSpots = {}
    for key, row in pairs(offerStore() or {}) do
        local npcId, questID = tostring(key):match("^(%d+):(%d+)$")
        npcId, questID = tonumber(npcId), tonumber(questID)
        if npcId and questID and (offerVotes(npcId, questID)) > 0 then
            local known = npcGives[npcId] and npcGives[npcId][questID]
            setAdd(npcGives, npcId, questID)
            if not known and offerFromOthers(row) then offerUsed = offerUsed + 1 end
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
    -- spots: the data's, else the spot a record came with
    local function consider(npcId, spawns)
        if checked[npcId] or type(spawns) ~= "table" or #spawns == 0 then return end
        checked[npcId] = true
        local close = false
        for _, sp in ipairs(spawns) do
            if type(sp) == "table" and sp[1] == continent and type(sp[2]) == "number" and type(sp[3]) == "number"
                and (sp[2] - px) ^ 2 + (sp[3] - py) ^ 2 < limit then close = true; break end
        end
        if close then
            local entry = entryOf("npc", npcId)
            local candidates = { gameNpcName(npcId), locNames and locNames[npcId], entry and entry.names and entry.names.enUS }
            for i = 1, 3 do
                local key = lowerName(candidates[i])
                if key then setAdd(names, key, npcId) end
            end
        end
    end
    for _, map in ipairs({ npcGives, npcTakes }) do
        for npcId in pairs(map) do consider(npcId, partnerSpawns("npc", npcId)) end
    end
    -- turn-in NPCs of finished quests from the learned / shared records
    local sources = ns.QuestSources
    if sources and sources.turnInEntries then
        for _, quest in ipairs(QuestLogPins.collectQuests()) do
            if quest.complete then
                local ok, entries = pcall(sources.turnInEntries, quest.id)
                for _, e in ipairs(ok and type(entries) == "table" and entries or {}) do
                    if e.kind == "npc" and type(e.id) == "number" then consider(e.id, e.spawns) end
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
    -- (false, not nil, for a missing list: ipairs stops at a nil first entry,
    -- and then the requirements' list was never looked at)
    for _, list in ipairs({ (q and q.blockedBy) or false, (req and req[8]) or false }) do
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

local function takeable(questID, me)
    if questDone(questID) or questInLog(questID) then return nil end
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
            -- (rank not known: not shown as one to take now)
            if (type(have) == "number" and need > have) or (have == true and need > 1) then
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

-- Professions this character has: skill line ID -> rank (true: rank not
-- known). Read on login and skill changes too, because inside a tooltip the
-- game can hand the ranks over as secret values; a secret rank then keeps the
-- rank read before. nil when the professions can't be read at all.
local knownSkills
local function readProfessions()
    if not (type(GetProfessions) == "function" and type(GetProfessionInfo) == "function") then return knownSkills end
    local results = { pcall(GetProfessions) }
    if not results[1] then return knownSkills end
    local fresh = {}
    for i = 2, 7 do   -- primary 1, primary 2, archaeology, fishing, cooking, first aid (any may be nil)
        local index = results[i]
        if type(index) == "number" and not isSecret(index) then
            local okInfo, _, _, rank, _, _, _, skillLine = pcall(GetProfessionInfo, index)
            if okInfo and type(skillLine) == "number" and not isSecret(skillLine) then
                if type(rank) == "number" and not isSecret(rank) then
                    fresh[skillLine] = rank
                else
                    local before = knownSkills and knownSkills[skillLine]
                    fresh[skillLine] = type(before) == "number" and before or true
                end
            end
        end
    end
    knownSkills = fresh
    return knownSkills
end

do
    local skillWatcher = CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "TRADE_SKILL_LIST_UPDATE" }) do
        pcall(skillWatcher.RegisterEvent, skillWatcher, event)
    end
    skillWatcher:SetScript("OnEvent", function() pcall(readProfessions) end)
end

local function playerInfo()
    local level = (UnitLevel and UnitLevel("player")) or 1
    local _, class, classID = UnitClass("player")
    local raceID = select(3, UnitRace("player"))
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    local okSkills, skills = pcall(readProfessions)
    if not okSkills then skills = knownSkills end
    return { level = tonumber(level) or 1, class = class, faction = faction, skills = skills,
        raceID = (type(raceID) == "number" and not isSecret(raceID)) and raceID or nil,
        classID = (type(classID) == "number" and not isSecret(classID)) and classID or nil,
        classBit = (type(classID) == "number" and classID >= 1 and classID <= 31) and 2 ^ (classID - 1) or nil,
        raceBit = (type(raceID) == "number" and raceID >= 1 and raceID <= 31) and 2 ^ (raceID - 1) or nil }
end

-- { { text, r, g, b }, ... } for one NPC ID
-- nowOnly: only quests that can surely be taken now (map marks)
-- kind: "object" for a quest object (the ID is then an object ID), else an NPC
function QuestLogPins.npcQuestLines(npcId, me, nowOnly, kind)
    buildNpcQuests()
    me = me or playerInfo()
    local isNpc = kind ~= "object"
    kind = isNpc and "npc" or "object"
    local found = {}
    -- finished quests turned in here: the built-in data, plus the turn-in NPC
    -- known from the learned / installed sources
    local takes = {}
    if isNpc then
        for questID in pairs(npcTakes[npcId] or {}) do takes[questID] = true end
    end
    local sources = ns.QuestSources
    if sources and sources.turnInEntries then
        for _, quest in ipairs(QuestLogPins.collectQuests()) do
            if quest.complete and not takes[quest.id] then
                local ok, entries = pcall(sources.turnInEntries, quest.id)
                for _, e in ipairs(ok and type(entries) == "table" and entries or {}) do
                    if e.kind == kind and e.id == npcId then takes[quest.id] = true break end
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
    local gives = ((isNpc and npcGives or objGives) or {})[npcId]
    for questID in pairs(gives or {}) do
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
            if questConditional(questID, isNpc and npcId or nil, me) then
                name = ns:L("NPC_TT_CONDITION") .. " " .. name
            end
            if q.needPrev then name = ns:L("NPC_TT_PREREQ") .. " " .. name end
            -- given through a talk option, not in the NPC's first list
            if isNpc and offeredByTalk(npcId, questID) then name = TALK_ICON .. name end
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
                    r = r, g = g, b = b, qid = questID, next = tonumber(q.next), prev = prevQuest and prevQuest[questID] }
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

-- One tooltip may list several NPCs (a map mark over neighbours, the
-- minimap): each quest is listed once, and a later step of a chain is left
-- out while an earlier step is listed (the parts of a chain often share one
-- name, so they looked like the same line twice). blocks: { lines, ... } as
-- npcQuestLines returns them; changed in place and returned.
function QuestLogPins.pruneQuestLines(blocks)
    local listed = {}
    for _, lines in ipairs(blocks) do
        for _, l in ipairs(lines) do
            if l.qid then listed[l.qid] = true end
        end
    end
    local later = {}
    for _, lines in ipairs(blocks) do
        for _, l in ipairs(lines) do
            if l.qid then
                if l.next and listed[l.next] then later[l.next] = true end
                if l.prev and listed[l.prev] then later[l.qid] = true end
            end
        end
    end
    local seen = {}
    for i, lines in ipairs(blocks) do
        local kept = {}
        for _, l in ipairs(lines) do
            if not l.qid then
                kept[#kept + 1] = l
            elseif not seen[l.qid] and not later[l.qid] then
                seen[l.qid] = true
                kept[#kept + 1] = l
            end
        end
        blocks[i] = kept
    end
    return blocks
end

-- For the developer's check in EzWoW-DataDumper (that addon is on this PC
-- only): the quests an NPC's tooltip lists as ones to take now (a yellow
-- "!"). The check tests them again with its own code (done, in the log,
-- requirements), so a mistake here shows up there.
function QuestLogPins.availableNowAt(npcId)
    buildNpcQuests()
    local me = playerInfo()
    local floorLevel = QuestLogPins.trivialFloor and QuestLogPins.trivialFloor(me.level) or (me.level - 5)
    local out = {}
    for questID in pairs((npcGives or {})[npcId] or {}) do
        local q = takeable(questID, me)
        local level = q and tonumber(q.lvl) or 0
        if q and (level <= 0 or level > floorLevel)
            and not ((q.min or 0) > me.level or q.needPrev or q.needRank) then
            out[#out + 1] = questID
        end
    end
    return out
end
do
    local devHook = CreateFrame("Frame")
    pcall(devHook.RegisterEvent, devHook, "PLAYER_LOGIN")
    devHook:SetScript("OnEvent", function()
        local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
        local ok, on = false, false
        if type(loaded) == "function" then ok, on = pcall(loaded, "EzWoW-DataDumper") end
        if ok and on then
            _G.EzWoW_QuestDev = {
                AvailableAt = function(npcId) return QuestLogPins.availableNowAt(npcId) end,
                -- every NPC that gives a quest (the check goes through them all)
                AllGivers = function()
                    buildNpcQuests()
                    local out = {}
                    for npcId in pairs(npcGives or {}) do out[#out + 1] = npcId end
                    return out
                end,
            }
        end
    end)
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
    npcGives, npcTakes, prevQuest, objGives = nil, nil, nil, nil
    giverSpotsByMap = {}
    nearby.names = nil
end

-- NPC spots checked by other players arrived: the giver marks look again
function QuestLogPins.resetGiverSpots()
    giverSpotsByMap = {}
    nearby.names = nil
end

-- When the player talks to an NPC, the game lists the quests it offers now:
-- those are noted (and shared). A quest missing from the list is not noted.
local function plainValue(v)
    if v == nil or isSecret(v) then return nil end
    return v
end

-- partial: the list may not be all the NPC offers (more talk options open
-- further quests): only offered quests are noted then
-- talkIDs: quests reached through a talk option (not in the first list)
function QuestLogPins.noteOffered(npcId, offeredIDs, offeredTitles, partial, talkIDs)
    if not npcId then return end
    clearNotOfferedNotes()
    buildNpcQuests()
    local me = playerInfo()
    local changed = false
    -- every quest the NPC offered is shared (also ones the data doesn't know,
    -- from NPCs it has no quests for); an NPC the data has no spot for is
    -- shared with where it stands
    local known = entryByKey and entryByKey["npc:" .. npcId]
    local spot = not known and playerSpot() or nil
    local function offeredState(questID)
        return (talkIDs and talkIDs[questID]) and 2 or 1
    end
    for questID in pairs(offeredIDs) do
        if type(questID) == "number" and noteOwnOffer(npcId, questID, offeredState(questID), me, spot) then changed = true end
    end
    -- quests of this NPC in the data that came only by title (older lists)
    for questID in pairs(npcGives and npcGives[npcId] or {}) do
        if not offeredIDs[questID] and offeredTitles[questName(questID)] then
            if noteOwnOffer(npcId, questID, offeredState(questID), me, spot) then changed = true end
        end
    end
    if changed then QuestLogPins.resetNpcQuests() end
    if changed and ns.RefreshQuestLogPins then pcall(ns.RefreshQuestLogPins) end
end

-- NPC id of a unit; nil, true: some other unit (object, player, hidden value);
-- nil, nil: no unit
local function unitNpcId(unit)
    local okGuid, guid = pcall(UnitGUID, unit)
    if not okGuid or isSecret(guid) then return nil, true end
    if guid == nil then return nil, nil end
    local key = guidToStarter(guid)
    local id = key and tonumber(key:match("^npc:(%d+)$"))
    if id then return id, false end
    return nil, true
end

-- the NPC the window is from; second value: some other unit is there (a game
-- object, a player sharing a quest, a hidden value), so it is not from an NPC.
-- The unit the window belongs to decides; "npc" may still be an earlier talk
-- when a quest window comes from a player or an item
local function talkingNpcId(event)
    local first, second = "questnpc", "npc"
    if event == "GOSSIP_SHOW" or event == "QUEST_GREETING" then first, second = "npc", "questnpc" end
    local id, other = unitNpcId(first)
    if other == nil then id, other = unitNpcId(second) end
    return id, other or false
end

-- shared record kind "Q": "npcID,questID,state,level,raceID,classID[,continent,x,y]"
-- (state 1 offered, 0 not; the spot only for an NPC the data has no spot for)
if ns.Share and type(ns.Share.RegisterKind) == "function" then
    ns.Share.RegisterKind(OFFER_KIND, {
        own = function()
            clearNotOfferedNotes()   -- old wrong own notes are not sent
            local out = {}
            for key, row in pairs(offerStore() or {}) do
                local own = type(row) == "table" and row.own
                local npcId, questID = tostring(key):match("^(%d+):(%d+)$")
                if npcId and type(own) == "table" and OFFER_STATES[own[1]] then
                    local body = string.format("%d,%d,%d,%d,%d,%d", tonumber(npcId), tonumber(questID), own[1],
                        tonumber(own[2]) or 0, tonumber(own[3]) or 0, tonumber(own[4]) or 0)
                    local sp = row.ownSpot == true and row.spot
                    if type(sp) == "table" and tonumber(sp[1]) and tonumber(sp[2]) and tonumber(sp[3]) then
                        body = body .. string.format(",%d,%.1f,%.1f", sp[1], sp[2], sp[3])
                    end
                    out[#out + 1] = body
                end
            end
            return out
        end,
        receive = function(body, hash)
            local npcId, questID, state, level, rest = body:match("^(%d+),(%d+),([012]),(%d+),?(.*)$")
            if state == "0" then return false end   -- "not offered" from older copies
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
            if spot and type(row.spot) ~= "table" then row.spot = spot end
            return true
        end,
        -- how many of these records from other players are in use now: NPCs
        -- shown as quest givers only because other players saw the offer
        used = function()
            buildNpcQuests()
            return offerUsed
        end,
    })
end

-- Talk options ("Anything else?") may lead to quests that the first list
-- doesn't show; the shop, trainer, flight and similar options don't.
local GOSSIP_TALK_ICON = 132053   -- Interface\GossipFrame\GossipGossipIcon
local function hasTalkOption(gossip)
    if type(gossip.GetOptions) ~= "function" then return true end
    local okOpts, options = pcall(gossip.GetOptions)
    if not okOpts or type(options) ~= "table" then return true end
    for _, option in ipairs(options) do
        if type(option) == "table" then
            local icon = plainValue(option.icon)
            if icon == nil or icon == GOSSIP_TALK_ICON
                or (type(icon) == "string" and icon:lower():find("gossipgossipicon", 1, true)) then
                return true
            end
        end
    end
    return false
end

local offerEvents = CreateFrame("Frame")
local listSeenAt, listNpc = -100, nil
-- the quests on the first page of the talk with that NPC: a talk option can
-- open another page that lists more quests
local listIDs, listTitles = {}, {}
local closedAt = -100   -- the dialog was closed then (a new talk starts after)
local endedAt = -100    -- the talk ended then (not just gossip -> quest window)
-- the dialog went on to another window then (a quest window, but also a shop,
-- trainer, flight map or bank, whose closing ends the talk unseen): the talk
-- goes on only if a quest window opens right after
local handOffAt = nil
local TALK_WINDOWS = { GOSSIP_SHOW = true, QUEST_GREETING = true, QUEST_DETAIL = true,
    QUEST_PROGRESS = true, QUEST_COMPLETE = true }

local function newTalk(npcId)
    if listNpc ~= npcId or GetTime() - listSeenAt > 60 then return true end
    -- closed in between (not just the next page of the same talk)
    return closedAt > listSeenAt and GetTime() - closedAt > 1
end

offerEvents:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "GOSSIP_CLOSED" then
        closedAt = GetTime()
        -- true: going on to another window (quest, shop, trainer, ...)
        if arg1 ~= true then endedAt = closedAt; handOffAt = nil else handOffAt = closedAt end
        return
    elseif event == "QUEST_FINISHED" then
        endedAt = GetTime()
        handOffAt = nil
        return
    end
    if handOffAt then
        local since = GetTime() - handOffAt
        if since > 1 then
            -- no quest window came: the talk ended as the dialog closed
            if handOffAt > endedAt then endedAt = handOffAt end
            handOffAt = nil
        elseif TALK_WINDOWS[event] then
            handOffAt = nil   -- went on to this window (ended by its QUEST_FINISHED)
        end
    end
    local ok = pcall(function()
        local npcId, other = talkingNpcId(event)
        -- a quest window opened from an NPC's dialog may not name the NPC:
        -- the one talked to, while that talk is open or just ended (accepted
        -- as the window closed). An object, a player, an item long after: not it
        if not npcId then
            local now = GetTime()
            if other or event == "GOSSIP_SHOW" or not listNpc or now - listSeenAt >= 60
                or (endedAt > listSeenAt and now - endedAt > 1) then
                listNpc = nil
                return
            end
            npcId = listNpc
        elseif npcId ~= listNpc then
            -- a window from another NPC: a later accept is not the old talk's
            listNpc = nil
        end
        local ids, titles = {}, {}
        local partial, talk = false, nil
        if event == "GOSSIP_SHOW" then
            local gossip = C_GossipInfo
            if type(gossip) ~= "table" or type(gossip.GetAvailableQuests) ~= "function" then return end
            local first = newTalk(npcId)
            listSeenAt, listNpc = GetTime(), npcId
            partial = hasTalkOption(gossip)
            for _, info in ipairs(gossip.GetAvailableQuests() or {}) do
                local id = type(info) == "table" and plainValue(info.questID)
                if type(id) == "number" then ids[id] = true end
                local title = type(info) == "table" and plainValue(info.title)
                if type(title) == "string" then titles[title] = true end
            end
            if first then
                listIDs, listTitles = ids, titles
            else
                -- a later page of the same talk: its quests came by talking
                partial = true
                for id in pairs(ids) do
                    if not listIDs[id] then
                        talk = talk or {}
                        talk[id] = true
                    end
                end
            end
        elseif event == "QUEST_GREETING" then
            if type(GetNumAvailableQuests) ~= "function" or type(GetAvailableTitle) ~= "function" then return end
            if newTalk(npcId) then listIDs, listTitles = ids, titles end
            listSeenAt, listNpc = GetTime(), npcId
            for i = 1, (plainValue(GetNumAvailableQuests()) or 0) do
                local title = plainValue(GetAvailableTitle(i))
                if type(title) == "string" then titles[title] = true end
            end
        elseif event == "QUEST_ACCEPTED" then
            -- taken from the NPC talked to a moment ago (auto accept may take
            -- it before the quest window can be read): offered by that NPC
            if not (listNpc == npcId and GetTime() - listSeenAt < 60) then return end
            local id = plainValue(arg2) or plainValue(arg1)
            if type(arg2) ~= "number" then id = plainValue(arg1) end
            if type(id) ~= "number" or id <= 0 then return end
            partial = true
            ids[id] = true
            local title = questName(id)
            if not listIDs[id] and not (type(title) == "string" and listTitles[title]) then
                talk = { [id] = true }
            end
        elseif event == "QUEST_DETAIL" then
            -- straight to one quest (no list first): that NPC offers only it;
            -- picked from this NPC's list (or reached by talking) a moment ago:
            -- offered, but not the whole offer
            partial = listNpc == npcId and GetTime() - listSeenAt < 60
            local id = type(GetQuestID) == "function" and plainValue(GetQuestID())
            if type(id) ~= "number" or id <= 0 then return end
            ids[id] = true
            -- opened from this NPC's talk, not from its first list
            local title = type(GetTitleText) == "function" and plainValue(GetTitleText())
            if partial and not listIDs[id] and not (type(title) == "string" and listTitles[title]) then
                talk = { [id] = true }
            end
        elseif event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
            -- straight to a quest being handed in (no list first): the NPC
            -- has no quest to offer now, or the game would list them first
            if listNpc == npcId and GetTime() - listSeenAt < 60 then return end
        end
        QuestLogPins.noteOffered(npcId, ids, titles, partial, talk)
    end)
    if not ok then return end
end)
for _, event in ipairs({ "GOSSIP_SHOW", "GOSSIP_CLOSED", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_ACCEPTED",
    "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_FINISHED" }) do
    pcall(offerEvents.RegisterEvent, offerEvents, event)
end

local function giverSpotsFor(mapID, project)
    local cached = giverSpotsByMap[mapID]
    if cached then return cached end
    cached = {}
    for _, kind in ipairs({ "npc", "object" }) do
        for id in pairs((kind == "npc" and npcGives or objGives) or {}) do
            local spawns = partnerSpawns(kind, id) or {}
            if kind == "object" and #spawns > MAX_OBJECT_GIVER_SPOTS then spawns = {} end
            for _, sp in ipairs(spawns) do
                local mapID2, mx, my = project(sp, mapID)
                if mx and my and mapID2 == mapID then
                    cached[#cached + 1] = { kind = kind, id = id, sp = sp, mx = mx, my = my }
                end
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

-- kind "npc" / "object" and its ID
local function giverState(kind, id, me)
    local floorLevel = trivialBelow(me.level)
    local state
    local npcId = kind == "npc" and id or nil
    for questID in pairs(((npcId and npcGives or objGives) or {})[id] or {}) do
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
    if ns.GamePad and ns.GamePad.MapMark then ns.GamePad.MapMark(pin) end
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
        local blocks = {}
        for i, giver in ipairs(group.givers) do blocks[i] = QuestLogPins.npcQuestLines(giver.id, me, true, giver.kind) end
        QuestLogPins.pruneQuestLines(blocks)
        for i, giver in ipairs(group.givers) do
            local lines = blocks[i]
            if #lines > 0 then
                local name = partnerName(giver.kind, giver.id)
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
        if clearPinWaypoint(sp) then return end
        if sp then
            local giver = self.group.givers and self.group.givers[1]
            local name = giver and partnerName(giver.kind, giver.id) or ""
            pointAtPin(sp, name)
            rememberPinWaypoint(sp)
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
        local key = spot.kind .. ":" .. spot.id
        local state = states[key]
        if state == nil then
            state = giverState(spot.kind, spot.id, me) or false
            states[key] = state
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
                group = { px = px, py = py, cw = cw, ch = ch, spawn = spot.sp, givers = {}, seen = {} }
                groups[#groups + 1] = group
            end
            if not group.seen[key] then
                group.seen[key] = true
                group.givers[#group.givers + 1] = { kind = spot.kind, id = spot.id }
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
        if tooltip ~= GameTooltip or not npcTooltipOn() or not ezTipsOn() or type(data) ~= "table" then return end
        pcall(function()
            local id = npcIdOf(data.guid)
            if not id then return end
            local lines = QuestLogPins.pruneQuestLines({ QuestLogPins.npcQuestLines(id) })[1]
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
    local lists = {}
    for i, block in ipairs(blocks) do lists[i] = block.lines end
    QuestLogPins.pruneQuestLines(lists)
    local any = false
    for i, block in ipairs(blocks) do
        block.lines = lists[i]
        if #block.lines > 0 then any = true end
    end
    if not any then return end
    for _, block in ipairs(blocks) do
        if #block.lines > 0 then
        tooltip:AddLine(" ")
        tooltip:AddLine(block.name, Theme.muted[1], Theme.muted[2], Theme.muted[3])
        for _, l in ipairs(block.lines) do tooltip:AddLine("  " .. l.text, l.r, l.g, l.b) end
        end
    end
    tooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
    addingToMinimap = true
    tooltip:Show()
    addingToMinimap = false
end

if GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnShow", function(tooltip)
        if addingToMinimap or not npcTooltipOn() or not ezTipsOn() or not Minimap then return end
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

-- how many quests of the list are checked (watched) and how many are not
local function watchCounts()
    local watchedCount, unwatchedCount = 0, 0
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
            if watched then watchedCount = watchedCount + 1 else unwatchedCount = unwatchedCount + 1 end
        end
    end
    return watchedCount, unwatchedCount
end

-- The game watches only so many quests at once. When "check all" leaves some
-- unchecked, the number it did check is taken as that limit for this session
-- (the largest seen; not saved: a quest left unchecked for another reason would
-- otherwise keep a limit too low); with the limit reached the button clears the
-- checks instead.
local sessionWatchLimit
local function watchLimit()
    if sessionWatchLimit and sessionWatchLimit > 0 then return sessionWatchLimit end
    local c = Constants and Constants.QuestWatchConsts
    local max = c and tonumber(c.MAX_QUEST_WATCHES)
    return max and max > 0 and max or nil
end

-- true when "check all" can still check more quests
local function canWatchMore()
    local watchedCount, unwatchedCount = watchCounts()
    if unwatchedCount == 0 then return false end
    local limit = watchLimit()
    return not (limit and watchedCount >= limit)
end

-- after "check all": the quests left unchecked show the game's limit
local function noteWatchLimit()
    local watchedCount, unwatchedCount = watchCounts()
    if unwatchedCount > 0 and watchedCount > (sessionWatchLimit or 0) then sessionWatchLimit = watchedCount end
    -- (a limit an older version saved is let go)
    if ns.db then ns.db.questWatchLimit = nil end
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
    -- the tooltip: the button's label, what it does (tipKey() gives the text's
    -- key for the button's current state) and the addon's name
    b:SetScript("OnEnter", function(self)
        if self.SetBackdropBorderColor then self:SetBackdropBorderColor(0.94, 0.72, 0.42, 1) end
        if not (GameTooltip and self.tipKey) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.text:GetText() or "", unpack(Theme.accent))
        GameTooltip:AddLine(ns:L(self.tipKey()), 1, 1, 1, true)
        GameTooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
        GameTooltip:Show()
        if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
    end)
    b:SetScript("OnLeave", function(self)
        if self.SetBackdropBorderColor then self:SetBackdropBorderColor(0.20, 0.30, 0.36, 1) end
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    return b
end

local function refreshBar()
    if not questLogBar then return end
    questLogBar.fold.text:SetText(ns:L(anyCollapsed() and "QUESTLOG_EXPAND_ALL" or "QUESTLOG_COLLAPSE_ALL"))
    questLogBar.check.text:SetText(ns:L(canWatchMore() and "QUESTLOG_TRACK_ALL" or "QUESTLOG_UNTRACK_ALL"))
    -- a tooltip open on a button follows its new label
    for _, b in ipairs({ questLogBar.fold, questLogBar.check }) do
        if GameTooltip and GameTooltip:IsOwned(b) then b:GetScript("OnEnter")(b) end
    end
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
    bar.fold.tipKey = function() return anyCollapsed() and "QUESTLOG_EXPAND_TIP" or "QUESTLOG_COLLAPSE_TIP" end
    -- one button: checks every quest, or clears every check when all are checked
    -- (or as many as the game watches at once)
    bar.check = barButton(bar, 78, function()
        local more = canWatchMore()
        setAllWatched(more)
        local function after()
            if more then noteWatchLimit() end
            refreshBar()
        end
        if C_Timer then C_Timer.After(0.2, after) else after() end
    end)
    bar.check:SetPoint("TOPLEFT", bar.fold, "BOTTOMLEFT", 0, -4)
    bar.check.tipKey = function() return canWatchMore() and "QUESTLOG_TRACK_TIP" or "QUESTLOG_UNTRACK_TIP" end
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
