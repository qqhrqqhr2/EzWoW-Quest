--===========================================================================
-- EzWoW - Quest
-- Modules/QuestAnnounce.lua : Quest progress messages to the party
--===========================================================================
-- Lines sent to the group:
--   accepted          "Quest accepted: <title>"
--   objective goes up "<title> - Ragefire Trogg slain: 4/8"
--   all objectives    "<title> - objectives done"
--   turned in         "Quest complete: <title>"
-- Only with the option on and only in a group (party, or the instance group);
-- never in a raid.
-- Lines that can't be sent right now (chat locked in combat) wait and go out
-- once chat is allowed again; repeats of the same line are dropped.
local ADDON_NAME, ns = ...
local type, ipairs, pairs, pcall, tonumber, tostring = type, ipairs, pairs, pcall, tonumber, tostring

local QuestAnnounce = {}
ns.QuestAnnounce = QuestAnnounce

local function isSecret(value)
    if type(_G.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(_G.issecretvalue, value)
    return ok and secret and true or false
end

local function enabled()
    local db = ns.InitializeDatabase and ns:InitializeDatabase()
    return db and db.questPartyAnnounce == true
end

-----------------------------------------------------------------------------
-- Reading the quest log
-----------------------------------------------------------------------------
-- questID -> { title, done, objectives = { [index] = { have, need, text } } }
local known = {}
local primed = false
local acceptedNow = {}   -- questIDs accepted since the last comparison

local function questTitle(questID)
    local title
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, t = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if ok and type(t) == "string" and not isSecret(t) then title = t end
    end
    return title
end

local function questDone(questID)
    if C_QuestLog then
        if C_QuestLog.ReadyForTurnIn then
            local ok, ready = pcall(C_QuestLog.ReadyForTurnIn, questID)
            if ok and not isSecret(ready) and ready then return true end
        end
        if C_QuestLog.IsComplete then
            local ok, done = pcall(C_QuestLog.IsComplete, questID)
            if ok and not isSecret(done) and done then return true end
        end
    end
    return false
end

local function readObjectives(questID)
    local list = {}
    if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return list end
    local ok, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)
    if not ok or type(objectives) ~= "table" then return list end
    for index, o in ipairs(objectives) do
        local have, need, text = o.numFulfilled, o.numRequired, o.text
        if not isSecret(have) and not isSecret(need) and not isSecret(text) then
            list[index] = { have = tonumber(have) or 0, need = tonumber(need) or 0, text = type(text) == "string" and text or "" }
        end
    end
    return list
end

-- questIDs of the quests in the log (headers and hidden tasks left out)
local function logQuests()
    local ids = {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return ids end
    local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
    count = ok and tonumber(count) or 0
    for i = 1, count do
        local okInfo, info = pcall(C_QuestLog.GetInfo, i)
        if okInfo and type(info) == "table" and not info.isHeader and not info.isHidden then
            local id = info.questID
            if id and not isSecret(id) and id > 0 then ids[#ids + 1] = id end
        end
    end
    return ids
end

-----------------------------------------------------------------------------
-- Sending
-----------------------------------------------------------------------------
local queue, lastSent = {}, {}
local REPEAT_WINDOW = 10 -- seconds; the same line again within this is dropped

local function groupChannel()
    if IsInRaid and IsInRaid() then return nil end
    local instanceCat = LE_PARTY_CATEGORY_INSTANCE
    if instanceCat and IsInGroup and IsInGroup(instanceCat) then return "INSTANCE_CHAT" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
end

local function chatLocked()
    if C_ChatInfo and type(C_ChatInfo.InChatMessagingLockdown) == "function" then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and not isSecret(locked) and locked then return true end
    end
    return false
end

local function send(text, channel)
    local fn = (C_ChatInfo and C_ChatInfo.SendChatMessage) or _G.SendChatMessage
    if type(fn) ~= "function" then return true end
    return pcall(fn, text, channel)
end

local function flush()
    if #queue == 0 then return end
    local channel = groupChannel()
    if not channel or not enabled() then
        queue = {}
        return
    end
    if chatLocked() then return end
    local pending = queue
    queue = {}
    for _, text in ipairs(pending) do send(text, channel) end
end

local function announce(text)
    if not text or text == "" then return end
    local now = GetTime()
    if lastSent[text] and now - lastSent[text] < REPEAT_WINDOW then return end
    lastSent[text] = now
    queue[#queue + 1] = text
    flush()
end

-----------------------------------------------------------------------------
-- Comparing the log with what was seen before
-----------------------------------------------------------------------------
local function snapshot(questID)
    return { title = questTitle(questID), done = questDone(questID), objectives = readObjectives(questID) }
end

local function compare()
    local ids = logQuests()
    local present = {}
    local announceNow = primed and enabled() and groupChannel() ~= nil
    for _, questID in ipairs(ids) do
        present[questID] = true
        local now = snapshot(questID)
        local before = known[questID]
        if before and announceNow then
            local title = now.title or before.title or ("#" .. questID)
            for index, o in pairs(now.objectives) do
                local old = before.objectives[index]
                if old and o.have > old.have and o.text ~= "" then
                    announce(ns:L("QUEST_ANNOUNCE_PROGRESS"):format(title, o.text))
                end
            end
            if now.done and not before.done then
                announce(ns:L("QUEST_ANNOUNCE_DONE"):format(title))
            end
        elseif not before and announceNow and acceptedNow[questID] then
            local title = now.title or ("#" .. questID)
            announce(ns:L("QUEST_ANNOUNCE_ACCEPTED"):format(title))
        end
        known[questID] = now
    end
    for questID in pairs(known) do
        if not present[questID] then known[questID] = nil end
    end
    acceptedNow = {}
    primed = true
end

-- QUEST_LOG_UPDATE comes in bursts: one comparison on the next frame covers them
local compareQueued = false
local function queueCompare()
    if compareQueued then return end
    compareQueued = true
    C_Timer.After(0.2, function()
        compareQueued = false
        pcall(compare)
    end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
    "QUEST_REMOVED", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_REGEN_ENABLED" or event == "GROUP_ROSTER_UPDATE" then
        flush()
        return
    end
    if event == "QUEST_ACCEPTED" then
        -- (older clients pass the log index first and the quest ID second)
        local id = tonumber(arg2) or tonumber(arg1)
        if id and id > 0 and not isSecret(id) then acceptedNow[id] = true end
    elseif event == "QUEST_TURNED_IN" then
        local id = tonumber(arg1)
        if id and not isSecret(id) and primed and enabled() and groupChannel() then
            local title = (known[id] and known[id].title) or questTitle(id) or ("#" .. id)
            announce(ns:L("QUEST_ANNOUNCE_TURNED_IN"):format(title))
        end
    end
    queueCompare()
end)

-- lines held while chat was locked go out as soon as it opens again
C_Timer.NewTicker(2, function()
    if #queue > 0 then flush() end
end)
