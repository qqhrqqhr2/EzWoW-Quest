--===========================================================================
-- EzWoW - Quest
-- Modules/QuestShare.lua : Sharing quests with the group & party quest status
--===========================================================================
-- Share:   Alt + left click on a quest line in the tracker, or (option, off by
--          default) once right after accepting a quest while in a group.
--          The game prints its own results; a quest that can't be shared gets
--          a short note here, printed only out of combat.
-- Status:  which party members (party1..4) are on a quest, for the tracker.
--          Values the client hides (secret values) are left out.
local ADDON_NAME, ns = ...
local type, ipairs, pcall, tonumber, tostring = type, ipairs, pcall, tonumber, tostring

local QuestShare = {}
ns.QuestShare = QuestShare

local function isSecret(value)
    if type(_G.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(_G.issecretvalue, value)
    return ok and secret and true or false
end

local function plain(value)
    if value == nil or isSecret(value) then return nil end
    return value
end

local function num(value)
    if value == nil or isSecret(value) then return nil end
    return tonumber(value)
end

local function db()
    return ns:InitializeDatabase()
end

local function inCombat()
    return InCombatLockdown and InCombatLockdown() and true or false
end

local function inGroup()
    return IsInGroup and IsInGroup() and true or false
end

-- party only (not in a raid)
local function inParty()
    if not inGroup() then return false end
    if IsInRaid and IsInRaid() then return false end
    return true
end

-----------------------------------------------------------------------------
-- Notes in the chat frame: a line added in combat would taint the chat
-- history, so notes wait until combat (and the chat lockdown) is over.
-----------------------------------------------------------------------------
local notes = {}
local noteRetry = false

local function chatLocked()
    if C_ChatInfo and type(C_ChatInfo.InChatMessagingLockdown) == "function" then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and not isSecret(locked) and locked then return true end
    end
    return false
end

local function flushNotes()
    if #notes == 0 then return end
    if inCombat() or chatLocked() then
        if not noteRetry and C_Timer and type(C_Timer.After) == "function" then
            noteRetry = true
            C_Timer.After(2, function()
                noteRetry = false
                flushNotes()
            end)
        end
        return
    end
    local pending = notes
    notes = {}
    for _, text in ipairs(pending) do ns:PrintMsg(text) end
end

local function note(text)
    if not text or text == "" then return end
    for _, queued in ipairs(notes) do
        if queued == text then return end
    end
    notes[#notes + 1] = text
    flushNotes()
end

-----------------------------------------------------------------------------
-- Quest log helpers
-----------------------------------------------------------------------------
local function logIndexFor(questID, logIndex)
    if C_QuestLog and type(C_QuestLog.GetLogIndexForQuestID) == "function" then
        local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
        index = ok and plain(index) or nil
        if type(index) == "number" and index > 0 then return index end
    end
    logIndex = plain(logIndex)
    if type(logIndex) == "number" and logIndex > 0 then return logIndex end
    return nil
end

local function questTitle(questID)
    if C_QuestLog and type(C_QuestLog.GetTitleForQuestID) == "function" then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        title = ok and plain(title) or nil
        if type(title) == "string" and title ~= "" then return title end
    end
    return "#" .. tostring(questID)
end

local function selectedQuest()
    if C_QuestLog and type(C_QuestLog.GetSelectedQuest) == "function" then
        local ok, id = pcall(C_QuestLog.GetSelectedQuest)
        id = ok and plain(id) or nil
        if type(id) == "number" and id > 0 then return id end
    end
    return nil
end

local function selectQuest(questID, logIndex)
    if C_QuestLog and type(C_QuestLog.SetSelectedQuest) == "function" then
        pcall(C_QuestLog.SetSelectedQuest, questID)
    end
    if logIndex and type(_G.SelectQuestLogEntry) == "function" then
        pcall(_G.SelectQuestLogEntry, logIndex)
    end
end

-- true / false, or nil when the client can't tell
function QuestShare.IsPushable(questID, logIndex)
    if C_QuestLog and type(C_QuestLog.IsPushableQuest) == "function" then
        local ok, pushable = pcall(C_QuestLog.IsPushableQuest, questID)
        if ok and pushable ~= nil and not isSecret(pushable) then
            return pushable and true or false
        end
    end
    -- older clients ask about the selected quest log entry
    if type(_G.GetQuestLogPushable) == "function" then
        selectQuest(questID, logIndex)
        local ok, pushable = pcall(_G.GetQuestLogPushable)
        if ok and not isSecret(pushable) then
            return (pushable == true or pushable == 1) and true or false
        end
    end
    return nil
end

-- Shares a quest with the group. silent: no notes (automatic sharing).
function QuestShare.Share(questID, logIndex, silent)
    questID = num(questID)
    if not questID or questID <= 0 then return false end
    if not inGroup() then
        if not silent then note(ns:L("MSG_SHARE_NO_GROUP")) end
        return false
    end
    logIndex = logIndexFor(questID, logIndex)
    if not logIndex then return false end
    if QuestShare.IsPushable(questID, logIndex) == false then
        if not silent then note(ns:L("MSG_SHARE_NOT_PUSHABLE"):format(questTitle(questID))) end
        return false
    end
    if type(_G.QuestLogPushQuest) ~= "function" then return false end
    local before = selectedQuest()
    selectQuest(questID, logIndex)
    local ok = pcall(_G.QuestLogPushQuest, logIndex)
    -- give the quest log its own selection back
    if before and before ~= questID and C_QuestLog and type(C_QuestLog.SetSelectedQuest) == "function" then
        pcall(C_QuestLog.SetSelectedQuest, before)
    end
    return ok and true or false
end

-----------------------------------------------------------------------------
-- Party quest status
-----------------------------------------------------------------------------
local function surnameSeparator()
    local consts = Constants and Constants.CharacterNameSeparatorConsts
    local sep = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR
    if type(sep) == "string" and sep ~= "" and not isSecret(sep) then return sep end
    return " "
end

-- "Name Surname": the second UnitName value is the surname unless it is a realm.
function QuestShare.UnitDisplayName(unit)
    if NameUtil and type(NameUtil.FormatUnitNameForDisplay) == "function" then
        local ok, full = pcall(NameUtil.FormatUnitNameForDisplay, unit)
        full = ok and plain(full) or nil
        if type(full) == "string" and full ~= "" then return full end
    end
    local ok, first, second = pcall(UnitName, unit)
    if not ok then return nil end
    first, second = plain(first), plain(second)
    if type(first) ~= "string" or first == "" then return nil end
    if type(second) == "string" and second ~= "" then
        local okRealm, realm = pcall(GetRealmName)
        realm = okRealm and plain(realm) or nil
        if realm ~= second then return first .. surnameSeparator() .. second end
    end
    return first
end

-- true / false, or nil when unknown (no data or a secret value)
function QuestShare.IsUnitOnQuest(unit, questID, logIndex)
    if C_QuestLog and type(C_QuestLog.IsUnitOnQuest) == "function" then
        local ok, onQuest = pcall(C_QuestLog.IsUnitOnQuest, unit, questID)
        if ok then
            if isSecret(onQuest) then return nil end
            if onQuest ~= nil then return onQuest and true or false end
        end
    end
    -- older clients: IsUnitOnQuest(questLogIndex, unit)
    if type(_G.IsUnitOnQuest) == "function" then
        logIndex = logIndexFor(questID, logIndex)
        if logIndex then
            local ok, onQuest = pcall(_G.IsUnitOnQuest, logIndex, unit)
            if ok and not isSecret(onQuest) then
                return (onQuest == true or onQuest == 1) and true or false
            end
        end
    end
    return nil
end

local function unitExists(unit)
    if not UnitExists then return false end
    local ok, exists = pcall(UnitExists, unit)
    return ok and not isSecret(exists) and exists and true or false
end

-- In a party: have, known, members = { { name, has } } for party1..4.
-- Members whose answer is unknown are left out. nil when not in a party.
function QuestShare.GetPartyStatus(questID, logIndex)
    if not inParty() then return nil end
    questID = num(questID)
    if not questID or questID <= 0 then return nil end
    local have, known, members = 0, 0, {}
    for i = 1, 4 do
        local unit = "party" .. i
        if unitExists(unit) then
            local onQuest = QuestShare.IsUnitOnQuest(unit, questID, logIndex)
            if onQuest ~= nil then
                known = known + 1
                if onQuest then have = have + 1 end
                members[#members + 1] = { name = QuestShare.UnitDisplayName(unit) or unit, has = onQuest }
            end
        end
    end
    if known == 0 then return nil end
    return have, known, members
end

function QuestShare.PartyStatusEnabled()
    return db().trackerPartyStatus ~= false
end

-----------------------------------------------------------------------------
-- Automatic sharing after accepting a quest
-----------------------------------------------------------------------------
local autoShared = {}   -- questIDs already shared this session
local waiting = {}      -- questIDs with a share on the way

local function autoShare(questID)
    waiting[questID] = nil
    if db().questAutoShare ~= true or autoShared[questID] or not inGroup() then return end
    if inCombat() then
        waiting[questID] = true
        ns:EnqueuePostCombatCallback(autoShare, questID)
        return
    end
    local logIndex = logIndexFor(questID)
    if not logIndex then return end
    if QuestShare.IsPushable(questID, logIndex) ~= true then return end
    autoShared[questID] = true
    -- everyone in the party already has it: nothing to share
    local have, known = QuestShare.GetPartyStatus(questID, logIndex)
    local members = (GetNumSubgroupMembers and num(GetNumSubgroupMembers())) or known
    if have and known and members and have >= known and known >= members then return end
    QuestShare.Share(questID, logIndex, true)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "QUEST_ACCEPTED" then
        -- (older clients pass the log index first and the quest ID second)
        local questID = num(arg2) or num(arg1)
        if not questID or questID <= 0 then return end
        if db().questAutoShare ~= true or autoShared[questID] or waiting[questID] or not inGroup() then return end
        waiting[questID] = true
        -- the quest log fills in on the next updates
        C_Timer.After(1, function() autoShare(questID) end)
    elseif event == "QUEST_REMOVED" then
        local questID = num(arg1)
        if questID then
            autoShared[questID] = nil
            waiting[questID] = nil
        end
    end
end)
