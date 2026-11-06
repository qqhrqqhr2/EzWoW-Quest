--===========================================================================
-- EzWoW - Quest
-- Modules/QuestAutomation.lua : Auto accept / auto turn-in (hold Shift to skip)
--===========================================================================
local ADDON_NAME, ns = ...
local type, ipairs, pcall, tonumber, tostring = type, ipairs, pcall, tonumber, tostring

local QuestAutomation = {}
ns.QuestAutomation = QuestAutomation

local function db()
    return ns:InitializeDatabase()
end

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

local function plain(value)
    if type(_G.issecretvalue) == "function" then
        local ok, secret = pcall(_G.issecretvalue, value)
        if ok and secret then return nil end
    end
    return value
end

-- Holding Shift while talking to the NPC turns everything off for that talk.
local function paused()
    return IsShiftKeyDown and IsShiftKeyDown() and true or false
end

local function acceptOn() return db().questAutoAccept == true and not paused() end
local function completeOn() return db().questAutoComplete == true and not paused() end
local function skipRisky() return db().questSkipRisky ~= false end
local function skipItems() return db().questSkipItems == true end

-- Single gossip options that are never picked automatically
-- (hearthstone binding, talent/skill resets, locked options).
local RISKY_WORDS = { "unlearn", "reset", "bind", "초기화", "귀환", "잊" }

-- Only options the NPC offers as available (not locked or already used).
local function optionAvailable(option)
    local status = plain(option.status)
    local statuses = Enum and Enum.GossipOptionStatus
    if type(statuses) == "table" and statuses.Available ~= nil then
        return status == nil or status == statuses.Available
    end
    return (tonumber(status) or 0) == 0
end

local function riskyOption(option)
    if not optionAvailable(option) then return true end
    local name = plain(option.name)
    if type(name) ~= "string" then return true end
    local lower = name:lower()
    for _, word in ipairs(RISKY_WORDS) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

-- Options picked a moment ago, by gossip text and option ID (stops a loop
-- when an NPC keeps showing the same single option; the same option ID can
-- belong to different NPC texts, so the text is part of the key).
local pickedOptions = {}
local PICK_MEMORY = 5   -- seconds

local function forgetOldPicks()
    local now = GetTime()
    for key, at in pairs(pickedOptions) do
        if now - at >= PICK_MEMORY then pickedOptions[key] = nil end
    end
end

local function pickKey(optionID)
    local text = plain(call(C_GossipInfo and C_GossipInfo.GetText))
    if type(text) ~= "string" then text = "" end
    return text .. "#" .. tostring(optionID)
end

-----------------------------------------------------------------------------
-- Gossip window (NPCs with several options)
-----------------------------------------------------------------------------
local function handleGossip()
    local gossip = C_GossipInfo
    if type(gossip) ~= "table" then return end
    if completeOn() then
        for _, info in ipairs(call(gossip.GetActiveQuests) or {}) do
            if type(info) == "table" and plain(info.isComplete) == true and plain(info.questID) then
                call(gossip.SelectActiveQuest, info.questID)
                return
            end
        end
    end
    if acceptOn() then
        for _, info in ipairs(call(gossip.GetAvailableQuests) or {}) do
            if type(info) == "table" and plain(info.questID) then
                local risky = plain(info.isTrivial) == true or plain(info.repeatable) == true
                    or ((tonumber(plain(info.frequency)) or 0) > 0)
                if not (skipRisky() and risky) then
                    call(gossip.SelectAvailableQuest, info.questID)
                    return
                end
            end
        end
        -- No quests here and only one thing to say: pick it (never inside
        -- dungeons and raids, where talking can start an event).
        if IsInInstance and IsInInstance() then return end
        local active = call(gossip.GetActiveQuests) or {}
        local available = call(gossip.GetAvailableQuests) or {}
        if #active > 0 or #available > 0 then return end
        local options = call(gossip.GetOptions) or {}
        if #options ~= 1 then return end
        local option = options[1]
        if type(option) ~= "table" or riskyOption(option) then return end
        -- the client already picks options flagged for that by itself
        if plain(option.selectOptionWhenOnlyOption) == true then return end
        local optionID = plain(option.gossipOptionID)
        if not optionID then return end
        local key = pickKey(optionID)
        local pickedAt = pickedOptions[key]
        if pickedAt and GetTime() - pickedAt < PICK_MEMORY then return end
        pickedOptions[key] = GetTime()
        call(gossip.SelectOption, optionID)
    end
end

-----------------------------------------------------------------------------
-- Quest greeting window (older style list)
-----------------------------------------------------------------------------
local function handleGreeting()
    if completeOn() then
        for i = 1, (call(GetNumActiveQuests) or 0) do
            local _, isComplete = call(GetActiveTitle, i)
            if isComplete then
                call(SelectActiveQuest, i)
                return
            end
        end
    end
    if acceptOn() then
        for i = 1, (call(GetNumAvailableQuests) or 0) do
            local isTrivial, frequency, isRepeatable
            if type(GetAvailableQuestInfo) == "function" then
                isTrivial, frequency, isRepeatable = call(GetAvailableQuestInfo, i)
            end
            local risky = isTrivial == true or isRepeatable == true or ((tonumber(frequency) or 0) > 0)
            if not (skipRisky() and risky) then
                call(SelectAvailableQuest, i)
                return
            end
        end
    end
end

-----------------------------------------------------------------------------
-- Quest detail / progress / reward
-----------------------------------------------------------------------------
local function handleDetail()
    if not acceptOn() then return end
    if skipRisky() and ((call(QuestIsDaily) == true) or (call(QuestIsWeekly) == true)) then return end
    call(AcceptQuest)
end

local function handleProgress()
    if not completeOn() then return end
    if not call(IsQuestCompletable) then return end
    -- quests that take items (optional) or gold from you are left to you
    if skipItems() and (tonumber(call(GetNumQuestItems)) or 0) > 0 then return end
    if (tonumber(call(GetQuestMoneyToGet)) or 0) > 0 then return end
    call(CompleteQuest)
end

-- Marks the reward that sells for the most (price x count) when there is a
-- choice: in the NPC's reward window, the quest log and the map's quest details.
-- The reward buttons are read where the game lays them out; each button's own
-- index picks its item, so the mark never lands on the wrong button.
local bestMark

local function hideBestMark()
    if bestMark then bestMark:Hide() end
end

local function placeBestMark(button)
    if not bestMark then
        bestMark = CreateFrame("Frame", nil, UIParent)
        bestMark:SetSize(18, 18)
        bestMark.icon = bestMark:CreateTexture(nil, "OVERLAY")
        bestMark.icon:SetAllPoints()
        bestMark.icon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    end
    bestMark:SetParent(button)
    bestMark:SetFrameLevel(button:GetFrameLevel() + 5)
    bestMark:ClearAllPoints()
    bestMark:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 4)
    bestMark:Show()
end

-- Vendor price (11th value of the item info).
-- Returns 0 when the item has no price, nil when the item is not loaded yet.
local function sellPrice(link)
    local getInfo = (C_Item and type(C_Item.GetItemInfo) == "function" and C_Item.GetItemInfo)
        or (type(GetItemInfo) == "function" and GetItemInfo)
    if not getInfo then return 0 end
    local ok, name, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, link)
    if not ok then return 0 end
    if name == nil then return nil end
    return tonumber(plain(price)) or 0
end

local function requestItem(link)
    if not (C_Item and type(C_Item.RequestLoadItemDataByID) == "function") then return end
    local itemID
    if type(C_Item.GetItemInfoInstant) == "function" then
        itemID = call(C_Item.GetItemInfoInstant, link)
    end
    itemID = tonumber(plain(itemID)) or tonumber(tostring(link):match("item:(%d+)"))
    if itemID then call(C_Item.RequestLoadItemDataByID, itemID) end
end

-- Link and stack count of choice reward <index>, from the quest log or the NPC.
local function choiceItem(fromLog, index)
    local link, count
    if fromLog then
        link = call(GetQuestLogItemLink, "choice", index)
        local _, _, numItems = call(GetQuestLogChoiceInfo, index)
        count = numItems
    else
        link = call(GetQuestItemLink, "choice", index)
        local _, _, numItems = call(GetQuestItemInfo, "choice", index)
        count = numItems
    end
    count = tonumber(plain(count)) or 1
    if count < 1 then count = 1 end
    return plain(link), count
end

-- While the rewards are shown and some choices were not loaded yet,
-- the mark is redone when item data arrives (a few times at most).
local rewardWaiting, rewardRetries = false, 0
local MAX_REWARD_RETRIES = 5

local function rewardsShown()
    local rewards = QuestInfoFrame and QuestInfoFrame.rewardsFrame
    return rewards and rewards.IsVisible and rewards:IsVisible() and rewards or nil
end

local function updateBestReward()
    hideBestMark()
    rewardWaiting = false
    if db().questMarkBest == false then return end
    local rewards = rewardsShown()
    local buttons = rewards and rewards.RewardButtons
    if type(buttons) ~= "table" then return end
    local fromLog = QuestInfoFrame.questLog and true or false
    local choices, bestButton, bestValue = 0, nil, 0
    for _, button in ipairs(buttons) do
        if button:IsShown() and button.type == "choice" and button.objectType == "item" then
            choices = choices + 1
            local index = button:GetID()
            local link, count = choiceItem(fromLog, index)
            if link then
                local price = sellPrice(link)
                if price == nil then
                    rewardWaiting = true
                    requestItem(link)
                elseif price * count > bestValue then
                    bestButton, bestValue = button, price * count
                end
            end
        end
    end
    if choices <= 1 then
        rewardWaiting = false
        return
    end
    -- wait for every choice before picking, so the mark does not jump around
    if rewardWaiting and rewardRetries < MAX_REWARD_RETRIES then return end
    rewardWaiting = false
    if bestButton then placeBestMark(bestButton) end
end

local function refreshBestReward()
    local ok, err = pcall(updateBestReward)
    if not ok and type(geterrorhandler) == "function" then geterrorhandler()(err) end
end

-- Every quest text window (NPC, quest log, map details) is drawn by QuestInfo_Display.
local displayHooked = false
local function hookQuestInfoDisplay()
    if displayHooked or type(QuestInfo_Display) ~= "function" then return end
    displayHooked = true
    hooksecurefunc("QuestInfo_Display", function()
        rewardRetries = 0
        refreshBestReward()
    end)
end
hookQuestInfoDisplay()

local retryQueued = false
local function onItemInfoReceived()
    if not rewardWaiting or retryQueued then return end
    retryQueued = true
    -- several items usually arrive together; redo the mark once
    C_Timer.After(0.1, function()
        retryQueued = false
        if not (rewardWaiting and rewardsShown()) then return end
        rewardRetries = rewardRetries + 1
        refreshBestReward()
    end)
end

local function handleReward()
    local choices = tonumber(call(GetNumQuestChoices)) or 0
    -- with a choice the player picks (the best one is marked)
    if choices > 1 then return end
    if not completeOn() then return end
    call(GetQuestReward, choices == 1 and 1 or 0)
end

-----------------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------------
-- Shared and escort quests started by someone else ask for confirmation.
local function handleAcceptConfirm()
    if not acceptOn() then return end
    if type(ConfirmAcceptQuest) ~= "function" then return end
    call(ConfirmAcceptQuest)
    if type(StaticPopup_Hide) == "function" then
        C_Timer.After(0, function() call(StaticPopup_Hide, "QUEST_ACCEPT") end)
    end
end

local HANDLERS = {
    GOSSIP_SHOW = handleGossip,
    QUEST_GREETING = handleGreeting,
    QUEST_DETAIL = handleDetail,
    QUEST_PROGRESS = handleProgress,
    QUEST_COMPLETE = handleReward,
    QUEST_ACCEPT_CONFIRM = handleAcceptConfirm,
}

local eventFrame = CreateFrame("Frame")
for event in pairs(HANDLERS) do pcall(eventFrame.RegisterEvent, eventFrame, event) end
pcall(eventFrame.RegisterEvent, eventFrame, "QUEST_FINISHED")
pcall(eventFrame.RegisterEvent, eventFrame, "GOSSIP_CLOSED")
pcall(eventFrame.RegisterEvent, eventFrame, "GET_ITEM_INFO_RECEIVED")
if not displayHooked then pcall(eventFrame.RegisterEvent, eventFrame, "ADDON_LOADED") end
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "QUEST_FINISHED" then
        rewardWaiting = false
        hideBestMark()
        return
    elseif event == "GOSSIP_CLOSED" then
        forgetOldPicks()
        return
    elseif event == "ADDON_LOADED" then
        hookQuestInfoDisplay()
        if displayHooked then pcall(eventFrame.UnregisterEvent, eventFrame, "ADDON_LOADED") end
        return
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        onItemInfoReceived()
        return
    end
    local handler = HANDLERS[event]
    if handler then
        local ok, err = pcall(handler)
        if not ok and type(geterrorhandler) == "function" then geterrorhandler()(err) end
    end
end)
