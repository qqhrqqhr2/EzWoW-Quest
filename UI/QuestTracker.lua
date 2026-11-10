--===========================================================================
-- EzWoW - Quest
-- UI/QuestTracker.lua : Custom Scrollable Quest Objective Tracker & Action Item Bar
--===========================================================================
local ADDON_NAME, ns = ...

local ObjectiveTrackerController = ns.ObjectiveTrackerController or {}
ns.ObjectiveTrackerController = ObjectiveTrackerController

local ICON_PATH = "Interface\\AddOns\\EzWoW-Quest\\Media\\Icon"

local STYLE = {
    bgMain  = { 0.071, 0.094, 0.122, 0.78 }, 
    bgHover = { 0.114, 0.157, 0.192, 0.88 }, 
    header  = { 0.114, 0.157, 0.192, 0.92 }, 
    border  = { 0.204, 0.298, 0.357, 0.85 }, 
    accent  = { 0.478, 0.635, 0.969, 1.00 }, 
    zone    = { 0.722, 0.800, 0.878, 1.00 }, 
    text    = { 0.929, 0.957, 0.969, 1.00 }, 
    textSub = { 0.655, 0.725, 0.773, 1.00 }, 
}

local FLAT_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

local TRACKER_MIN_WIDTH = 190
local TRACKER_MAX_WIDTH = 520
local TRACKER_DEFAULT_WIDTH = 270
local TRACKER_MIN_HEIGHT = 90
local TRACKER_MAX_HEIGHT = 820
local TRACKER_DEFAULT_HEIGHT = 360
local HEADER_HEIGHT = 24
local LINE_PADDING_X = 8

local trackerFrame
local headerBtn
local bodyFrame
local scrollFrame
local scrollChild
local scrollBar
local scrollThumb
local resizeGripBR
local resizeGripBL
local resizeBarBottom
local currentScrollOffset = 0
local maxScrollOffset = 0
local hasResizingTracker = false
local linePool = {}
local itemBtnPool = {}
local questMetaCache = {}
local lastWatchedState = {}
local hasInternalWatchEdit = false
local watchHooksInstalled = false
local refreshPending = false
local defaultTrackerHiddenByUs = false
local defaultTrackerHooked = false
local defaultTrackerVisibilityQueued = false

function ObjectiveTrackerController.hasInCombat()
    return InCombatLockdown and InCombatLockdown()
end

function ObjectiveTrackerController.assignSolidColor(tex, r, g, b, a)
    if not tex then return end
    if tex.SetColorTexture then
        tex:SetColorTexture(r, g, b, a or 1)
    elseif tex.SetTexture then
        tex:SetTexture(r, g, b, a or 1)
    end
end

function ObjectiveTrackerController.resolveRGBToHex(r, g, b)
    r = math.max(0, math.min(1, tonumber(r) or 1))
    g = math.max(0, math.min(1, tonumber(g) or 1))
    b = math.max(0, math.min(1, tonumber(b) or 1))
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function ObjectiveTrackerController.resolveDifficultyHex(level, questID)
    -- the same color as the game's quest list: the client's own difficulty for the quest
    if questID and C_PlayerInfo and type(C_PlayerInfo.GetContentDifficultyQuestForPlayer) == "function"
        and type(GetDifficultyColor) == "function" then
        local okD, difficulty = pcall(C_PlayerInfo.GetContentDifficultyQuestForPlayer, questID)
        if okD and difficulty ~= nil and not (issecretvalue and issecretvalue(difficulty)) then
            local okC, c = pcall(GetDifficultyColor, difficulty)
            if okC and type(c) == "table" and c.r then
                return ObjectiveTrackerController.resolveRGBToHex(c.r, c.g, c.b)
            end
        end
    end
    local lvVal = tonumber(level) or 0
    if lvVal <= 0 then
        return "|cffffd100"
    end
    if type(GetQuestDifficultyColor) == "function" then
        local isCallOk, themeColor = pcall(GetQuestDifficultyColor, lvVal)
        if isCallOk and type(themeColor) == "table" and themeColor.r then
            return ObjectiveTrackerController.resolveRGBToHex(themeColor.r, themeColor.g, themeColor.b)
        end
    end
    return "|cffffd100"
end

function ObjectiveTrackerController.resolveObjectiveProgressHex(collected, needed, finished)
    if finished then
        return "|cff40ff59"
    end
    local currentState = tonumber(collected)
    local req = tonumber(needed)
    if currentState and req and req > 0 then
        if currentState >= req then
            return "|cff40ff59"
        elseif currentState <= 0 then
            return "|cffdce6ec"
        end
        local pct = math.max(0, math.min(1, currentState / req))
        local r, g, b
        if pct < 0.5 then
            local resolvedValue = pct * 2
            r = 1.00
            g = 0.55 + 0.35 * resolvedValue
            b = 0.38 - 0.08 * resolvedValue
        else
            local resolvedValue = (pct - 0.5) * 2
            r = 1.00 - 0.45 * resolvedValue
            g = 0.90 + 0.10 * resolvedValue
            b = 0.30 + 0.05 * resolvedValue
        end
        return ObjectiveTrackerController.resolveRGBToHex(r, g, b)
    end
    return "|cffdce6ec"
end

function ObjectiveTrackerController.resolveMaxQuests()
    if C_QuestLog and type(C_QuestLog.GetMaxNumQuestsCanAccept) == "function" then
        local isCallOk, matchRef = pcall(C_QuestLog.GetMaxNumQuestsCanAccept)
        if isCallOk and type(matchRef) == "number" and matchRef > 0 then
            return matchRef
        end
    end
    if type(_G.MAX_QUESTS) == "number" and _G.MAX_QUESTS > 0 then
        return _G.MAX_QUESTS
    end
    return 20
end

function ObjectiveTrackerController.resolveItemCountSafe(itemID)
    if not itemID then return 0 end
    if C_Item and type(C_Item.GetItemCount) == "function" then
        local isCallOk, itemCount = pcall(C_Item.GetItemCount, itemID, false, true)
        if isCallOk and type(itemCount) == "number" then return itemCount end
    end
    if type(GetItemCount) == "function" then
        local isCallOk, itemCount = pcall(GetItemCount, itemID, false, true)
        if isCallOk and type(itemCount) == "number" then return itemCount end
    end
    return 0
end

function ObjectiveTrackerController.resolveItemCooldownSafe(itemID)
    if not itemID then return 0, 0, 0 end
    if C_Container and type(C_Container.GetItemCooldown) == "function" then
        local isCallOk, stateFlag, dataEntry, recordEntry = pcall(C_Container.GetItemCooldown, itemID)
        if isCallOk then return tonumber(stateFlag) or 0, tonumber(dataEntry) or 0, (recordEntry == 1 or recordEntry == true) and 1 or 0 end
    end
    if C_Item and type(C_Item.GetItemCooldown) == "function" then
        local isCallOk, stateFlag, dataEntry, recordEntry = pcall(C_Item.GetItemCooldown, itemID)
        if isCallOk then return tonumber(stateFlag) or 0, tonumber(dataEntry) or 0, (recordEntry == 1 or recordEntry == true) and 1 or 0 end
    end
    if type(GetItemCooldown) == "function" then
        local isCallOk, stateFlag, dataEntry, recordEntry = pcall(GetItemCooldown, itemID)
        if isCallOk then return tonumber(stateFlag) or 0, tonumber(dataEntry) or 0, (recordEntry == 1 or recordEntry == true) and 1 or 0 end
    end
    return 0, 0, 0
end

function ObjectiveTrackerController.resolveQuestIDFromLogIndex(logIndex)
    logIndex = tonumber(logIndex)
    if not logIndex or logIndex <= 0 then return nil end
    if C_QuestLog and type(C_QuestLog.GetQuestIDForLogIndex) == "function" then
        local isCallOk, qID = pcall(C_QuestLog.GetQuestIDForLogIndex, logIndex)
        if isCallOk and type(qID) == "number" and qID > 0 then return qID end
    end
    if C_QuestLog and type(C_QuestLog.GetInfo) == "function" then
        local isCallOk, apiInfo = pcall(C_QuestLog.GetInfo, logIndex)
        if isCallOk and apiInfo and type(apiInfo.questID) == "number" and apiInfo.questID > 0 then
            return apiInfo.questID
        end
    end
    if type(GetQuestLogTitle) == "function" then
        local isCallOk, _, _, _, hasHeader, _, _, _, qID = pcall(GetQuestLogTitle, logIndex)
        if isCallOk and not hasHeader and type(qID) == "number" and qID > 0 then
            return qID
        end
    end
    return nil
end

function ObjectiveTrackerController.assembleWatchedQuestSet()
    local set = {}
    if C_QuestLog and type(C_QuestLog.GetNumQuestWatches) == "function" and type(C_QuestLog.GetQuestIDForQuestWatchIndex) == "function" then
        local okN, numW = pcall(C_QuestLog.GetNumQuestWatches)
        if okN and type(numW) == "number" and numW > 0 then
            for indexEntry = 1, numW do
                local okQ, qID = pcall(C_QuestLog.GetQuestIDForQuestWatchIndex, indexEntry)
                if okQ and type(qID) == "number" and qID > 0 then
                    set[qID] = true
                end
            end
        end
    elseif type(GetNumQuestWatches) == "function" and type(GetQuestIndexForWatch) == "function" then
        local okN, numW = pcall(GetNumQuestWatches)
        if okN and type(numW) == "number" and numW > 0 then
            for indexEntry = 1, numW do
                local okIdx, logIdx = pcall(GetQuestIndexForWatch, indexEntry)
                if okIdx and type(logIdx) == "number" and logIdx > 0 then
                    local qID = ObjectiveTrackerController.resolveQuestIDFromLogIndex(logIdx)
                    if qID and qID > 0 then
                        set[qID] = true
                    end
                end
            end
        end
    end
    return set
end

function ObjectiveTrackerController.hasClientQuestWatched(questID, logIndex, watchedSet)
    if watchedSet and questID and watchedSet[questID] then
        return true
    end
    if C_QuestLog and type(C_QuestLog.GetQuestWatchType) == "function" and questID then
        local isCallOk, wtVal = pcall(C_QuestLog.GetQuestWatchType, questID)
        if isCallOk and wtVal ~= nil then return true end
    end
    if type(IsQuestWatched) == "function" and logIndex then
        local isCallOk, boxWidth = pcall(IsQuestWatched, logIndex)
        if isCallOk and boxWidth then return true end
    end
    return false
end

function ObjectiveTrackerController.hasQuestWatchedSafe(questID, logIndex, watchedSet)
    if ObjectiveTrackerController.hasClientQuestWatched(questID, logIndex, watchedSet) then
        return true
    end
    local savedDB = ns:InitializeDatabase()
    if questID and savedDB.trackerWatchedQuests and savedDB.trackerWatchedQuests[questID] then
        return true
    end
    return false
end

function ObjectiveTrackerController.onUserWatchQuest(questID)
    questID = tonumber(questID)
    if not questID or questID <= 0 then return end
    local savedDB = ns:InitializeDatabase()
    if savedDB.trackerHiddenQuests then
        savedDB.trackerHiddenQuests[questID] = nil
    end
    if type(savedDB.trackerWatchedQuests) ~= "table" then
        savedDB.trackerWatchedQuests = {}
    end
    savedDB.trackerWatchedQuests[questID] = true
    if savedDB.trackerCollapsedQuests then
        savedDB.trackerCollapsedQuests[questID] = nil
    end
    local meta = questMetaCache[questID]
    if meta and meta.zoneName and savedDB.trackerCollapsedZones then
        savedDB.trackerCollapsedZones[meta.zoneName] = nil
    end
    lastWatchedState[questID] = true
    ns:ScheduleTrackerUpdate()
end

function ObjectiveTrackerController.onUserUnwatchQuest(questID)
    questID = tonumber(questID)
    if not questID or questID <= 0 then return end
    local savedDB = ns:InitializeDatabase()
    if type(savedDB.trackerHiddenQuests) ~= "table" then
        savedDB.trackerHiddenQuests = {}
    end
    savedDB.trackerHiddenQuests[questID] = true
    if savedDB.trackerWatchedQuests then
        savedDB.trackerWatchedQuests[questID] = nil
    end
    lastWatchedState[questID] = false
    ns:ScheduleTrackerUpdate()
end

function ObjectiveTrackerController.installQuestWatchHooks()
    if watchHooksInstalled or type(hooksecurefunc) ~= "function" then return end
    watchHooksInstalled = true

    if C_QuestLog then
        if type(C_QuestLog.AddQuestWatch) == "function" then
            pcall(hooksecurefunc, C_QuestLog, "AddQuestWatch", function(questID)
                if not hasInternalWatchEdit then
                    ObjectiveTrackerController.onUserWatchQuest(questID)
                end
            end)
        end
        if type(C_QuestLog.RemoveQuestWatch) == "function" then
            pcall(hooksecurefunc, C_QuestLog, "RemoveQuestWatch", function(questID)
                if not hasInternalWatchEdit then
                    ObjectiveTrackerController.onUserUnwatchQuest(questID)
                end
            end)
        end
    end

    if type(_G.AddQuestWatch) == "function" then
        pcall(hooksecurefunc, "AddQuestWatch", function(logIndex)
            if not hasInternalWatchEdit then
                local qID = ObjectiveTrackerController.resolveQuestIDFromLogIndex(logIndex) or tonumber(logIndex)
                ObjectiveTrackerController.onUserWatchQuest(qID)
            end
        end)
    end
    if type(_G.AutoQuestWatch_Insert) == "function" then
        pcall(hooksecurefunc, "AutoQuestWatch_Insert", function(logIndex)
            if not hasInternalWatchEdit then
                local qID = ObjectiveTrackerController.resolveQuestIDFromLogIndex(logIndex) or tonumber(logIndex)
                ObjectiveTrackerController.onUserWatchQuest(qID)
            end
        end)
    end
    if type(_G.RemoveQuestWatch) == "function" then
        pcall(hooksecurefunc, "RemoveQuestWatch", function(logIndex)
            if not hasInternalWatchEdit then
                local qID = ObjectiveTrackerController.resolveQuestIDFromLogIndex(logIndex) or tonumber(logIndex)
                ObjectiveTrackerController.onUserUnwatchQuest(qID)
            end
        end)
    end
end

function ObjectiveTrackerController.resolveQuestObjectivesSafe(questID, logIndex)
    local results = {}
    if C_QuestLog and type(C_QuestLog.GetQuestObjectives) == "function" and questID then
        local isCallOk, itemList = pcall(C_QuestLog.GetQuestObjectives, questID)
        if isCallOk and type(itemList) == "table" then
            for _, obj in ipairs(itemList) do
                if obj and obj.text and obj.text ~= "" then
                    results[#results + 1] = {
                        text = obj.text,
                        type = obj.type,
                        finished = obj.finished == true,
                        numFulfilled = tonumber(obj.numFulfilled) or 0,
                        numRequired = tonumber(obj.numRequired) or 0,
                    }
                end
            end
            return results
        end
    end
    if type(GetNumQuestLeaderBoards) == "function" and type(GetQuestLogLeaderBoard) == "function" and logIndex then
        local okNum, numObj = pcall(GetNumQuestLeaderBoards, logIndex)
        if okNum and type(numObj) == "number" and numObj > 0 then
            for indexEntry = 1, numObj do
                local okO, extractSafeTooltipText, objType, finished = pcall(GetQuestLogLeaderBoard, indexEntry, logIndex)
                if okO and extractSafeTooltipText and extractSafeTooltipText ~= "" then
                    local currentState, req = string.match(extractSafeTooltipText, "(%d+)%s*/%s*(%d+)")
                    results[#results + 1] = {
                        text = extractSafeTooltipText,
                        type = objType,
                        finished = finished == true or finished == 1,
                        numFulfilled = tonumber(currentState) or 0,
                        numRequired = tonumber(req) or 0,
                    }
                end
            end
        end
    end
    return results
end

function ObjectiveTrackerController.resolveSpecialQuestItem(logIndex, isComplete)
    if not logIndex or logIndex <= 0 or type(GetQuestLogSpecialItemInfo) ~= "function" then
        return nil, nil
    end
    local isCallOk, link, iconTex, charges, presentWhenComplete = pcall(GetQuestLogSpecialItemInfo, logIndex)
    if not isCallOk or not link then return nil, nil end
    if isComplete == 1 and not presentWhenComplete then return nil, nil end
    local itemID = tonumber(string.match(link, "item:(%d+)"))
    if not itemID then return nil, nil end
    if ObjectiveTrackerController.resolveItemCountSafe(itemID) <= 0 then return nil, nil end
    if not iconTex and C_Item and type(C_Item.GetItemIconByID) == "function" then
        iconTex = C_Item.GetItemIconByID(itemID)
    end
    return itemID, iconTex
end

function ObjectiveTrackerController.resolveShortTagSuffix(tagID, tagName)
    if not tagID and not tagName then return "" end
    if tagID == 1 or tagName == ELITE then return "+" end
    if tagID == 81 or tagName == LFG_TYPE_DUNGEON then return "D" end
    if tagID == 62 or tagName == LFG_TYPE_RAID then return "R" end
    if tagID == 41 or tagName == PVP then return "P" end
    return "+"
end

function ObjectiveTrackerController.gatherWatchedQuestRecords()
    ObjectiveTrackerController.installQuestWatchHooks()
    local savedDB = ns:InitializeDatabase()
    local trackAll = savedDB.trackerTrackAll ~= false
    if type(savedDB.trackerHiddenQuests) ~= "table" then savedDB.trackerHiddenQuests = {} end
    if type(savedDB.trackerWatchedQuests) ~= "table" then savedDB.trackerWatchedQuests = {} end
    local hiddenQuests = savedDB.trackerHiddenQuests
    local watchedQuests = savedDB.trackerWatchedQuests
    local watchedSet = ObjectiveTrackerController.assembleWatchedQuestSet()

    local zones = {}
    local zoneOrder = {}
    local seenZone = {}
    local seenQuest = {}
    local totalActiveQuests = 0

    local function addQuestRecord(questID, logIndex, title, level, zoneName, isComplete, tagSuffix)
        if not questID or seenQuest[questID] then return end
        seenQuest[questID] = true
        totalActiveQuests = totalActiveQuests + 1

        local clientWatched = ObjectiveTrackerController.hasClientQuestWatched(questID, logIndex, watchedSet)
        local prevWatched = lastWatchedState[questID]
        lastWatchedState[questID] = clientWatched

        if prevWatched == nil then
            if clientWatched and hiddenQuests[questID] then
                hiddenQuests[questID] = nil
            end
        elseif not prevWatched and clientWatched then
            hiddenQuests[questID] = nil
            watchedQuests[questID] = true
            if savedDB.trackerCollapsedQuests then savedDB.trackerCollapsedQuests[questID] = nil end
            if zoneName and savedDB.trackerCollapsedZones then savedDB.trackerCollapsedZones[zoneName] = nil end
        elseif prevWatched and not clientWatched then
            hiddenQuests[questID] = true
            watchedQuests[questID] = nil
        end

        local watched = clientWatched or (watchedQuests[questID] == true)
        if trackAll then
            if hiddenQuests[questID] then return end
        else
            if not watched or hiddenQuests[questID] then return end
        end

        local zName = (zoneName and zoneName ~= "") and zoneName or ns:L("TRACKER_OTHER_ZONE")
        if not seenZone[zName] then
            seenZone[zName] = true
            zoneOrder[#zoneOrder + 1] = zName
            zones[zName] = {}
        end

        local objectives = ObjectiveTrackerController.resolveQuestObjectivesSafe(questID, logIndex)
        if isComplete == 0 and #objectives > 0 then
            local allDone = true
            for _, obj in ipairs(objectives) do
                if not obj.finished then
                    allDone = false
                    break
                end
            end
            if allDone and not (type(IsQuestSequenced) == "function" and IsQuestSequenced(questID)) then
                isComplete = 1
            end
        end

        local itemID, itemIcon = ObjectiveTrackerController.resolveSpecialQuestItem(logIndex, isComplete)

        zones[zName][#zones[zName] + 1] = {
            questID = questID,
            logIndex = logIndex,
            title = title,
            level = (level and level > 0) and level or (UnitLevel and UnitLevel("player")) or 1,
            zoneName = zName,
            isComplete = isComplete,
            tagSuffix = tagSuffix or "",
            objectives = objectives,
            itemID = itemID,
            itemIcon = itemIcon,
        }
    end

    if C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function" and type(C_QuestLog.GetInfo) == "function" then
        local numEntries = C_QuestLog.GetNumQuestLogEntries() or 0
        local maxScan = math.max(numEntries, 200)
        local currentHeader = ns:L("TRACKER_OTHER_ZONE")
        for indexEntry = 1, maxScan do
            local apiInfo = C_QuestLog.GetInfo(indexEntry)
            if not apiInfo then break end
            if apiInfo.isHeader then
                if apiInfo.title and apiInfo.title ~= "" then
                    currentHeader = apiInfo.title
                end
            elseif apiInfo.questID and apiInfo.questID > 0 and not apiInfo.isBounty and not apiInfo.isTask then
                local qID = apiInfo.questID
                local hasExplicitlyWatched = watchedSet[qID] or watchedQuests[qID] or ObjectiveTrackerController.hasClientQuestWatched(qID, indexEntry, watchedSet)
                if not apiInfo.isHidden or hasExplicitlyWatched then
                    local hasComp = 0
                    if C_QuestLog.IsFailed and C_QuestLog.IsFailed(qID) then
                        hasComp = -1
                    elseif C_QuestLog.IsComplete and C_QuestLog.IsComplete(qID) then
                        hasComp = 1
                    end
                    local tagSuffix = ""
                    if C_QuestLog.GetQuestTagInfo then
                        local okT, tagInfo = pcall(C_QuestLog.GetQuestTagInfo, qID)
                        if okT and tagInfo then
                            tagSuffix = ObjectiveTrackerController.resolveShortTagSuffix(tagInfo.tagID, tagInfo.tagName)
                        end
                    end
                    questMetaCache[qID] = {
                        title = apiInfo.title,
                        level = apiInfo.level,
                        zoneName = currentHeader,
                        tagSuffix = tagSuffix,
                    }
                    addQuestRecord(qID, indexEntry, apiInfo.title, apiInfo.level, currentHeader, hasComp, tagSuffix)
                end
            end
        end

        local candidateIDs = {}
        for qID in pairs(questMetaCache) do candidateIDs[qID] = true end
        for qID in pairs(watchedSet) do candidateIDs[qID] = true end
        for qID in pairs(watchedQuests) do candidateIDs[qID] = true end

        for qID in pairs(candidateIDs) do
            if not seenQuest[qID] then
                local stillOnQuest = C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(qID)
                if stillOnQuest then
                    local logIdx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(qID)
                    local apiInfo = (logIdx and logIdx > 0 and C_QuestLog.GetInfo) and C_QuestLog.GetInfo(logIdx) or nil
                    local meta = questMetaCache[qID]
                    local title = (apiInfo and apiInfo.title) or (meta and meta.title) or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(qID))
                    if title and title ~= "" then
                        local level = (apiInfo and apiInfo.level) or (meta and meta.level) or (C_QuestLog.GetQuestDifficultyLevel and C_QuestLog.GetQuestDifficultyLevel(qID)) or (UnitLevel and UnitLevel("player")) or 1
                        local zoneName = (meta and meta.zoneName) or ns:L("TRACKER_OTHER_ZONE")
                        local tagSuffix = (meta and meta.tagSuffix) or ""
                        if tagSuffix == "" and C_QuestLog.GetQuestTagInfo then
                            local okT, tagInfo = pcall(C_QuestLog.GetQuestTagInfo, qID)
                            if okT and tagInfo then
                                tagSuffix = ObjectiveTrackerController.resolveShortTagSuffix(tagInfo.tagID, tagInfo.tagName)
                            end
                        end
                        local hasComp = 0
                        if C_QuestLog.IsFailed and C_QuestLog.IsFailed(qID) then
                            hasComp = -1
                        elseif C_QuestLog.IsComplete and C_QuestLog.IsComplete(qID) then
                            hasComp = 1
                        end
                        questMetaCache[qID] = {
                            title = title,
                            level = level,
                            zoneName = zoneName,
                            tagSuffix = tagSuffix,
                        }
                        addQuestRecord(qID, logIdx, title, level, zoneName, hasComp, tagSuffix)
                    end
                else
                    questMetaCache[qID] = nil
                    lastWatchedState[qID] = nil
                    hiddenQuests[qID] = nil
                    watchedQuests[qID] = nil
                    if savedDB.trackerCollapsedQuests then savedDB.trackerCollapsedQuests[qID] = nil end
                    ObjectiveTrackerController.markQuestNew(qID, false)
                end
            end
        end
    elseif type(GetNumQuestLogEntries) == "function" and type(GetQuestLogTitle) == "function" then
        local currentHeader = ns:L("TRACKER_OTHER_ZONE")
        for indexEntry = 1, 75 do
            local title, level, questTag, hasHeader, _, isComplete, _, questID = GetQuestLogTitle(indexEntry)
            if not title then break end
            if hasHeader then
                currentHeader = title
            elseif questID and questID > 0 then
                local hasComp = (isComplete == 1 and 1) or (isComplete == -1 and -1) or 0
                local tagSuffix = questTag and "+" or ""
                addQuestRecord(questID, indexEntry, title, level, currentHeader, hasComp, tagSuffix)
            end
        end
    end

    return zoneOrder, zones, totalActiveQuests
end

-----------------------------------------------------------------------------
-- Quest log overlay. Opening the world map from addon code taints its pins
-- (the map's own SetPassThroughButtons calls are then blocked in combat), so
-- a plain left click on a quest line goes through one secure button that
-- clicks a button of the game's own: the quest's header in the default
-- tracker (opens the map at the quest's details) or, when that block does not
-- exist, the quest log micro button. The overlay lies over the hovered line,
-- placed by screen position (never anchored to the tracker, which would make
-- the tracker protected), and only out of combat: it hides when combat starts.
-- Other clicks (modifiers, right button) go on to the line's own handler.
-----------------------------------------------------------------------------
local questOverlay
local QUEST_TRACKER_MODULES = { "QuestObjectiveTracker", "CampaignQuestObjectiveTracker" }

function ObjectiveTrackerController.findDefaultQuestHeader(questID)
    for _, moduleName in ipairs(QUEST_TRACKER_MODULES) do
        local module = _G[moduleName]
        if type(module) == "table" and type(module.GetExistingBlock) == "function" then
            local ok, block = pcall(module.GetExistingBlock, module, questID)
            local header = ok and type(block) == "table" and block.HeaderButton
            if header and type(header.Click) == "function" then return header end
        end
    end
    return nil
end

function ObjectiveTrackerController.resolveQuestLogClickTarget(questID)
    local header = ObjectiveTrackerController.findDefaultQuestHeader(questID)
    if header then return header end
    local micro = _G.QuestLogMicroButton
    if micro and type(micro.Click) == "function" then return micro end
    return nil
end

function ObjectiveTrackerController.hideQuestOverlay()
    if not questOverlay or ObjectiveTrackerController.hasInCombat() then return end
    questOverlay:SetScript("OnUpdate", nil)
    questOverlay:Hide()
    questOverlay.line = nil
end

-- Covers the part of the line inside the scroll view (after the +/- badge).
function ObjectiveTrackerController.placeQuestOverlay(line)
    local overlay = questOverlay
    if not (overlay and line and scrollFrame) then return false end
    local left, right = line:GetLeft(), line:GetRight()
    local top, bottom = line:GetTop(), line:GetBottom()
    local viewTop, viewBottom = scrollFrame:GetTop(), scrollFrame:GetBottom()
    if not (left and right and top and bottom and viewTop and viewBottom) then return false end
    if line.badgeBtn and line.badgeBtn:IsShown() then left = left + 15 end
    top, bottom = math.min(top, viewTop), math.max(bottom, viewBottom)
    if top <= bottom or right <= left then return false end
    local ratio = line:GetEffectiveScale() / overlay:GetEffectiveScale()
    overlay:ClearAllPoints()
    overlay:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * ratio, top * ratio)
    overlay:SetSize((right - left) * ratio, (top - bottom) * ratio)
    return true
end

function ObjectiveTrackerController.ensureQuestOverlay()
    if questOverlay then return questOverlay end
    local overlay = CreateFrame("Button", "EzWoWQuest_TrackerOverlay", UIParent, "SecureActionButtonTemplate")
    overlay:Hide()
    overlay:SetFrameStrata("MEDIUM")
    overlay:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    overlay:SetAttribute("useOnKeyDown", false)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function(self)
        ObjectiveTrackerController.startTrackerDrag()
        -- the overlay is not attached to the tracker: follow the line while it moves
        self:SetScript("OnUpdate", function(me)
            if ObjectiveTrackerController.hasInCombat() then return end
            if me.line then ObjectiveTrackerController.placeQuestOverlay(me.line) end
        end)
    end)
    overlay:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        ObjectiveTrackerController.stopTrackerDrag()
        if self.line and not ObjectiveTrackerController.hasInCombat() then
            ObjectiveTrackerController.placeQuestOverlay(self.line)
        end
    end)
    overlay:EnableMouseWheel(true)
    overlay:SetScript("OnMouseWheel", function(self, delta)
        local line = self.line
        ObjectiveTrackerController.onTrackerMouseWheel(self, delta)
        -- the lines moved: let the one now under the cursor take the overlay
        if line and line.hl then line.hl:Hide() end
        if GameTooltip then GameTooltip:Hide() end
        ObjectiveTrackerController.hideQuestOverlay()
    end)
    -- unmodified left click: done by the secure "click" action (type1)
    overlay:SetScript("PostClick", function(self, button)
        if button == "LeftButton" and not (IsModifierKeyDown and IsModifierKeyDown()) then
            -- after the quest log has opened: guide to the nearest place to go
            local data = self.line and self.line.questData
            local qop = ns.QuestObjectivePins
            if data and data.questID and qop and qop.requestGuide then qop.requestGuide(data.questID) end
            return
        end
        local line = self.line
        local handler = line and line:GetScript("OnClick")
        if handler then handler(line, button) end
    end)
    overlay:SetScript("OnLeave", function(self)
        local line = self.line
        if line and line.hl then line.hl:Hide() end
        if GameTooltip then GameTooltip:Hide() end
        ObjectiveTrackerController.hideQuestOverlay()
    end)
    questOverlay = overlay

    local combatWatch = CreateFrame("Frame")
    pcall(combatWatch.RegisterEvent, combatWatch, "PLAYER_REGEN_DISABLED")
    combatWatch:SetScript("OnEvent", function()
        -- still allowed here: the lockdown starts right after this event
        if questOverlay and not InCombatLockdown() then
            questOverlay:SetScript("OnUpdate", nil)
            questOverlay:Hide()
            questOverlay.line = nil
        end
    end)
    return overlay
end

function ObjectiveTrackerController.showQuestOverlay(line)
    if ObjectiveTrackerController.hasInCombat() then return end
    local questData = line and line.questData
    if not (questData and questData.questID) then
        ObjectiveTrackerController.hideQuestOverlay()
        return
    end
    local target = ObjectiveTrackerController.resolveQuestLogClickTarget(questData.questID)
    -- no block of this quest in the default tracker (it only builds what fits):
    -- the quest log button would open the map without the quest's details, so
    -- the line's own click opens them instead
    -- (with the gamepad on the secure button is kept: see ns.IsGamePadUI)
    if target and target == _G.QuestLogMicroButton and _G.QuestMapFrame and not ns.IsGamePadUI()
        and (type(QuestMapFrame_OpenToQuestDetails) == "function" or type(QuestMapFrame_ShowQuestDetails) == "function") then
        target = nil
    end
    if not target then
        ObjectiveTrackerController.hideQuestOverlay()
        return
    end
    local overlay = ObjectiveTrackerController.ensureQuestOverlay()
    if not ObjectiveTrackerController.placeQuestOverlay(line) then
        ObjectiveTrackerController.hideQuestOverlay()
        return
    end
    overlay:SetFrameLevel(line:GetFrameLevel() + 5)
    overlay:SetAttribute("type1", "click")
    overlay:SetAttribute("clickbutton1", target)
    overlay.line = line
    overlay:Show()
end

-- After the list is redrawn: keep the overlay on its line if the cursor is
-- still there (the target may have changed), else take it away.
function ObjectiveTrackerController.refreshQuestOverlay()
    if not (questOverlay and questOverlay:IsShown()) or ObjectiveTrackerController.hasInCombat() then return end
    local line = questOverlay.line
    if line and line:IsVisible() and line.questData and questOverlay:IsMouseOver() then
        ObjectiveTrackerController.showQuestOverlay(line)
    else
        ObjectiveTrackerController.hideQuestOverlay()
    end
end

-- Without a secure target (or in combat, where the overlay is off) the line's
-- own click lands here.
-- The quest log's texts for the tooltip: the short "what to do" text and the
-- story (cut at about 360 bytes, on a whole character). nil when not readable.
local STORY_BYTES = 360
local function shortenText(text, limit)
    if #text <= limit then return text end
    local cut = limit
    -- step back to the first byte of a UTF-8 character
    while cut > 1 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut) .. "…"
end

function ObjectiveTrackerController.questLogTexts(questData)
    if type(GetQuestLogQuestText) ~= "function" or not questData or not questData.questID then return nil end
    local logIndex = questData.logIndex
    if (not logIndex or logIndex <= 0) and C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, questData.questID)
        logIndex = ok and index or nil
    end
    if type(logIndex) ~= "number" or (issecretvalue and issecretvalue(logIndex)) then return nil end
    local ok, story, summary = pcall(GetQuestLogQuestText, logIndex)
    if not ok then return nil end
    local function clean(text)
        if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return nil end
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        return text ~= "" and text or nil
    end
    summary, story = clean(summary), clean(story)
    if story then story = shortenText(story, STORY_BYTES) end
    return summary, story
end

-- Background and frame are drawn unless turned off, or while the list is
-- locked (a locked window shows only its contents, like the other EzWoW windows).
function ObjectiveTrackerController.isSolid(savedDB)
    if ObjectiveTrackerController.hoverActive then return true end
    return savedDB.trackerShowBg ~= false and not savedDB.trackerLocked
end

-- The quest's details in the World Map's quest list: with the map already open
-- only the details change, as a click in the list does; else the map opens at them.
function ObjectiveTrackerController.openQuestOnMap(questID)
    local list = _G.QuestMapFrame
    if not (questID and list and WorldMapFrame) or ns.IsGamePadUI() then return false end
    if WorldMapFrame:IsShown() and list:IsShown() and type(QuestMapFrame_ShowQuestDetails) == "function" then
        if pcall(QuestMapFrame_ShowQuestDetails, questID) then return true end
    end
    if type(QuestMapFrame_OpenToQuestDetails) == "function" then
        if pcall(QuestMapFrame_OpenToQuestDetails, questID) then return true end
    end
    if type(QuestMapFrame_ShowQuestDetails) == "function" then
        if not WorldMapFrame:IsShown() and type(ShowUIPanel) == "function" then pcall(ShowUIPanel, WorldMapFrame) end
        return pcall(QuestMapFrame_ShowQuestDetails, questID) and true or false
    end
    return false
end

function ObjectiveTrackerController.launchQuestInLog(questData)
    if not questData or not questData.questID then return end
    if ObjectiveTrackerController.hasInCombat() then
        -- a chat line added in combat would taint the chat history: note it on the tooltip
        if GameTooltip and GameTooltip:IsShown() then
            GameTooltip:AddLine(ns:L("TRACKER_COMBAT_LOG"), 1, 0.35, 0.35, true)
            GameTooltip:Show()
        end
        return
    end
    if ns.IsGamePadUI() then return end

    if type(QuestMapFrame_OpenToQuestDetails) == "function" and not _G.QuestLogFrame then
        pcall(QuestMapFrame_OpenToQuestDetails, questData.questID)
        return
    end

    local logIndex = questData.logIndex
    if (not logIndex or logIndex <= 0) and C_QuestLog and type(C_QuestLog.GetLogIndexForQuestID) == "function" then
        logIndex = C_QuestLog.GetLogIndexForQuestID(questData.questID)
    end

    if logIndex and logIndex > 0 then
        if C_QuestLog and type(C_QuestLog.SetSelectedQuest) == "function" then
            pcall(C_QuestLog.SetSelectedQuest, questData.questID)
        end
        if type(SelectQuestLogEntry) == "function" then
            pcall(SelectQuestLogEntry, logIndex)
        end
        if type(QuestLog_SetSelection) == "function" then
            pcall(QuestLog_SetSelection, logIndex)
        end
    end

    local qFrame = _G.QuestLogFrame
    if qFrame then
        if not qFrame:IsShown() and type(ShowUIPanel) == "function" then
            pcall(ShowUIPanel, qFrame)
        end
        if type(QuestLog_UpdateQuestDetails) == "function" then
            pcall(QuestLog_UpdateQuestDetails)
        end
        if type(QuestLog_Update) == "function" then
            pcall(QuestLog_Update)
        end
    elseif type(ToggleQuestLog) == "function" then
        pcall(ToggleQuestLog)
    end
end

function ObjectiveTrackerController.insertQuestChatLink(questData)
    if not questData then return false end
    local editBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if not editBox then return false end

    local link = nil
    if type(GetQuestLink) == "function" and questData.questID then
        local isCallOk, leftPos = pcall(GetQuestLink, questData.questID)
        if isCallOk and leftPos and leftPos ~= "" then link = leftPos end
    end
    if not link and questData.logIndex and type(GetQuestLink) == "function" then
        local isCallOk, leftPos = pcall(GetQuestLink, questData.logIndex)
        if isCallOk and leftPos and leftPos ~= "" then link = leftPos end
    end
    if not link then
        link = string.format("[%d] %s", questData.level or 1, questData.title or "")
    end
    if type(ChatEdit_InsertLink) == "function" then
        ChatEdit_InsertLink(link)
        return true
    elseif editBox.Insert then
        editBox:Insert(link)
        return true
    end
    return false
end

function ObjectiveTrackerController.dismissOrUntrackQuest(questData)
    if not questData or not questData.questID then return end
    local qID = questData.questID
    local savedDB = ns:InitializeDatabase()
    savedDB.trackerHiddenQuests = savedDB.trackerHiddenQuests or {}
    savedDB.trackerHiddenQuests[qID] = true
    if savedDB.trackerWatchedQuests then
        savedDB.trackerWatchedQuests[qID] = nil
    end

    hasInternalWatchEdit = true
    if C_QuestLog and type(C_QuestLog.RemoveQuestWatch) == "function" then
        pcall(C_QuestLog.RemoveQuestWatch, qID)
    end
    if questData.logIndex and type(RemoveQuestWatch) == "function" then
        pcall(RemoveQuestWatch, questData.logIndex)
    end
    hasInternalWatchEdit = false

    lastWatchedState[qID] = ObjectiveTrackerController.hasClientQuestWatched(qID, questData.logIndex)
    ns:UpdateQuestTracker()
end

-- the tracker refreshes many times per fight; queue the post-combat re-apply only once
function ObjectiveTrackerController.queueDefaultTrackerVisibility()
    if defaultTrackerVisibilityQueued then return end
    defaultTrackerVisibilityQueued = true
    ns:EnqueuePostCombatCallback(function()
        defaultTrackerVisibilityQueued = false
        ns:ApplyDefaultTrackerVisibility()
    end)
end

function ns:ApplyDefaultTrackerVisibility()
    local savedDB = self:InitializeDatabase()
    local shouldHide = (savedDB.enableTracker ~= false) and (savedDB.hideDefaultTracker ~= false)

    local defaultTracker = _G.ObjectiveTrackerFrame or _G.QuestWatchFrame or _G.WatchFrame
    if not defaultTracker then return end

    if ObjectiveTrackerController.hasInCombat() and defaultTracker.IsProtected and defaultTracker:IsProtected() then
        ObjectiveTrackerController.queueDefaultTrackerVisibility()
        return
    end

    if not defaultTrackerHooked and defaultTracker.HookScript then
        defaultTrackerHooked = true
        pcall(defaultTracker.HookScript, defaultTracker, "OnShow", function(f)
            local dBVal = ns:InitializeDatabase()
            if dBVal.enableTracker ~= false and dBVal.hideDefaultTracker ~= false then
                if ObjectiveTrackerController.hasInCombat() and f.IsProtected and f:IsProtected() then
                    ObjectiveTrackerController.queueDefaultTrackerVisibility()
                else
                    pcall(f.Hide, f)
                    defaultTrackerHiddenByUs = true
                end
            end
        end)
    end

    if shouldHide then
        if defaultTracker:IsShown() then
            pcall(defaultTracker.Hide, defaultTracker)
        end
        defaultTrackerHiddenByUs = true
    elseif defaultTrackerHiddenByUs then
        -- only undo our own hide; Blizzard or another tracker addon may hide it for its own reasons
        defaultTrackerHiddenByUs = false
        if not defaultTracker:IsShown() then
            -- no forced tracker update from here: running the game's tracker update from
            -- addon code taints the tables it fills, and the game's own later updates
            -- (for example the one the splash screen runs when it closes) would then carry
            -- that taint into secure frames. The tracker refreshes itself on its next event.
            pcall(defaultTracker.Show, defaultTracker)
        end
    end
end

function ObjectiveTrackerController.clampValue(val, minV, maxV)
    if val < minV then return minV end
    if val > maxV then return maxV end
    return val
end

function ObjectiveTrackerController.resolveTrackerDimensions()
    local savedDB = ns:InitializeDatabase()
    local boxWidth = ObjectiveTrackerController.clampValue(math.floor((tonumber(savedDB.trackerWidth) or TRACKER_DEFAULT_WIDTH) + 0.5), TRACKER_MIN_WIDTH, TRACKER_MAX_WIDTH)
    local headerBar = ObjectiveTrackerController.clampValue(math.floor((tonumber(savedDB.trackerHeight) or TRACKER_DEFAULT_HEIGHT) + 0.5), TRACKER_MIN_HEIGHT, TRACKER_MAX_HEIGHT)
    return boxWidth, headerBar
end

function ObjectiveTrackerController.commitSavedTrackerTransform()
    if not trackerFrame then return end
    local savedDB = ns:InitializeDatabase()
    local calculateCanvasScale = tonumber(savedDB.trackerScale) or 1.0
    if calculateCanvasScale < 0.50 then calculateCanvasScale = 0.50 elseif calculateCanvasScale > 1.50 then calculateCanvasScale = 1.50 end
    if not (ObjectiveTrackerController.hasInCombat() and trackerFrame:IsProtected()) then
        pcall(trackerFrame.SetScale, trackerFrame, calculateCanvasScale)
        trackerFrame:ClearAllPoints()
        local coordPos = savedDB.trackerPos
        if type(coordPos) == "table" and coordPos.point then
            trackerFrame:SetPoint(coordPos.point, UIParent, coordPos.relPoint or coordPos.point, coordPos.x or -36, coordPos.y or -210)
        else
            trackerFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -36, -210)
        end
    end
end

function ObjectiveTrackerController.persistTrackerPosition()
    if not trackerFrame then return end
    local savedDB = ns:InitializeDatabase()
    local calculateCanvasScale = trackerFrame:GetScale() or 1
    local right = trackerFrame:GetRight()
    local top = trackerFrame:GetTop()
    local parentW = UIParent:GetWidth() or 1920
    local parentH = UIParent:GetHeight() or 1080
    if right and top and calculateCanvasScale > 0 then
        local coordX = (right * calculateCanvasScale - parentW) / calculateCanvasScale
        local coordY = (top * calculateCanvasScale - parentH) / calculateCanvasScale
        savedDB.trackerPos = {
            point = "TOPRIGHT",
            relPoint = "TOPRIGHT",
            x = coordX,
            y = coordY,
        }
        trackerFrame:ClearAllPoints()
        trackerFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", coordX, coordY)
    else
        local point, _, relPoint, coordX, coordY = trackerFrame:GetPoint(1)
        if point then
            savedDB.trackerPos = {
                point = point,
                relPoint = relPoint or point,
                x = coordX or -36,
                y = coordY or -210,
            }
        end
    end
end

function ObjectiveTrackerController.refreshScrollBarVisual()
    if not scrollBar or not scrollThumb or not scrollFrame then return end
    if maxScrollOffset <= 0 then
        scrollBar:Hide()
        return
    end
    scrollBar:Show()
    local viewH = scrollFrame:GetHeight() or 100
    local contentH = viewH + maxScrollOffset
    local trackH = math.max(24, scrollBar:GetHeight() or (viewH - 4))
    local thumbH = math.max(20, math.min(trackH, math.floor((viewH / contentH) * trackH + 0.5)))
    scrollThumb:SetHeight(thumbH)

    local travel = math.max(0, trackH - thumbH)
    local ratio = (maxScrollOffset > 0) and (currentScrollOffset / maxScrollOffset) or 0
    local yOff = -math.floor(ratio * travel + 0.5)
    scrollThumb:ClearAllPoints()
    scrollThumb:SetPoint("TOPLEFT", scrollBar, "TOPLEFT", 1, yOff)
    scrollThumb:SetPoint("TOPRIGHT", scrollBar, "TOPRIGHT", -1, yOff)
end

function ObjectiveTrackerController.assignTrackerScroll(offset)
    if not scrollFrame then return end
    -- secure quest-item buttons inside the scroll child make it protected in combat
    if ObjectiveTrackerController.hasInCombat() and scrollFrame:IsProtected() then return end
    currentScrollOffset = ObjectiveTrackerController.clampValue(offset or 0, 0, maxScrollOffset)
    scrollFrame:SetVerticalScroll(currentScrollOffset)
    ObjectiveTrackerController.refreshScrollBarVisual()
end

function ns:ResetQuestTrackerPosition(silent)
    local savedDB = self:InitializeDatabase()
    savedDB.trackerPos = nil
    savedDB.trackerScale = nil
    savedDB.trackerWidth = TRACKER_DEFAULT_WIDTH
    savedDB.trackerHeight = TRACKER_DEFAULT_HEIGHT
    savedDB.trackerHiddenQuests = {}
    currentScrollOffset = 0
    ObjectiveTrackerController.commitSavedTrackerTransform()
    self:UpdateQuestTracker()
    if not silent then
        self:PrintMsg(string.format(self:L("MSG_SINGLE_RESET"), self:L("TRACKER_TITLE")))
    end
end

function ObjectiveTrackerController.resetTrackerSizeOnly()
    local savedDB = ns:InitializeDatabase()
    savedDB.trackerWidth = TRACKER_DEFAULT_WIDTH
    savedDB.trackerHeight = TRACKER_DEFAULT_HEIGHT
    currentScrollOffset = 0
    ns:UpdateQuestTracker()
end

function ObjectiveTrackerController.startTrackerDrag()
    if not trackerFrame or hasResizingTracker then return end
    local savedDB = ns:InitializeDatabase()
    if savedDB.enableMove == false then return end
    -- like the other EzWoW windows: a locked list still moves with Ctrl + drag
    if savedDB.trackerLocked and not (IsControlKeyDown and IsControlKeyDown()) then return end
    if savedDB.requireCtrl and not (IsControlKeyDown and IsControlKeyDown()) then return end
    if ObjectiveTrackerController.hasInCombat() and trackerFrame:IsProtected() then return end
    trackerFrame.isDragging = true
    trackerFrame:StartMoving()
end

function ObjectiveTrackerController.stopTrackerDrag()
    if not trackerFrame or not trackerFrame.isDragging then return end
    trackerFrame.isDragging = false
    trackerFrame:StopMovingOrSizing()
    ObjectiveTrackerController.persistTrackerPosition()
end

function ObjectiveTrackerController.onTrackerMouseWheel(_, delta)
    local savedDB = ns:InitializeDatabase()
    if IsControlKeyDown and IsControlKeyDown() then
        if savedDB.enableScale == false or savedDB.trackerLocked then return end
        if ObjectiveTrackerController.hasInCombat() and trackerFrame:IsProtected() then return end
        local currentState = tonumber(savedDB.trackerScale) or (trackerFrame and trackerFrame:GetScale()) or 1.0
        local nextScale = math.floor((currentState + (delta > 0 and 0.05 or -0.05)) * 100 + 0.5) / 100
        if nextScale < 0.50 then nextScale = 0.50 end
        if nextScale > 1.50 then nextScale = 1.50 end
        savedDB.trackerScale = math.abs(nextScale - 1.0) < 0.005 and nil or nextScale
        ObjectiveTrackerController.commitSavedTrackerTransform()
        if ns.ShowScaleToast then
            ns:ShowScaleToast(ns:L("TRACKER_TITLE"), math.floor(nextScale * 100 + 0.5))
        end
        return
    end

    if maxScrollOffset > 0 then
        local step = 38
        ObjectiveTrackerController.assignTrackerScroll(currentScrollOffset - (delta > 0 and step or -step))
    end
end

function ObjectiveTrackerController.handleQuickResetClick(button)
    if button ~= "RightButton" then return false end
    local savedDB = ns:InitializeDatabase()
    if savedDB.quickReset == false then return false end
    local hasCtrl = IsControlKeyDown and IsControlKeyDown()
    local hasShift = IsShiftKeyDown and IsShiftKeyDown()
    local hasAlt = IsAltKeyDown and IsAltKeyDown()
    if hasCtrl and hasAlt then
        ns:ResetQuestTrackerPosition(false)
        return true
    elseif hasShift then
        savedDB.trackerPos = nil
        ObjectiveTrackerController.commitSavedTrackerTransform()
        return true
    elseif hasCtrl then
        savedDB.trackerScale = nil
        savedDB.trackerWidth = TRACKER_DEFAULT_WIDTH
        savedDB.trackerHeight = TRACKER_DEFAULT_HEIGHT
        ObjectiveTrackerController.commitSavedTrackerTransform()
        ns:UpdateQuestTracker()
        if ns.ShowScaleToast then
            ns:ShowScaleToast(ns:L("TRACKER_TITLE"), 100)
        end
        return true
    end
    return false
end

-----------------------------------------------------------------------------
-- Party quest status (Modules/QuestShare.lua): "[2/4]" at the end of a quest
-- line (party members that have it / party members the client answered for)
-- and one tooltip line per member. Only in a party, with the option on.
-----------------------------------------------------------------------------
local PARTY_HEX_ALL = "|cff40ff59"
local PARTY_HEX_SOME = "|cffaaaaff"
local PARTY_HEX_NONE = "|cff8a949b"

function ObjectiveTrackerController.resolvePartySuffix(questData)
    local share = ns.QuestShare
    if not (share and questData and questData.questID and share.PartyStatusEnabled()) then return "" end
    local have, known = share.GetPartyStatus(questData.questID, questData.logIndex)
    if not have then return "" end
    local hex = (have >= known and PARTY_HEX_ALL) or (have > 0 and PARTY_HEX_SOME) or PARTY_HEX_NONE
    return string.format(" %s[%d/%d]|r", hex, have, known)
end

function ObjectiveTrackerController.addPartyTooltipLines(questData)
    local share = ns.QuestShare
    if not (share and questData and questData.questID and share.PartyStatusEnabled()) then return end
    local have, known, members = share.GetPartyStatus(questData.questID, questData.logIndex)
    if not members then return end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("%s (%d/%d)", ns:L("TRACKER_TT_PARTY"), have, known), STYLE.accent[1], STYLE.accent[2], STYLE.accent[3])
    for _, member in ipairs(members) do
        if member.has then
            GameTooltip:AddDoubleLine(member.name, ns:L("TRACKER_PARTY_HAS"), STYLE.text[1], STYLE.text[2], STYLE.text[3], 0.25, 1, 0.35)
        else
            GameTooltip:AddDoubleLine(member.name, ns:L("TRACKER_PARTY_MISSING"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3], 0.54, 0.58, 0.61)
        end
    end
end

-----------------------------------------------------------------------------
-- Quest rewards in the quest line tooltip: XP, money, items and the items to
-- choose one from, as the quest log shows them. The quest log answers for its
-- selected quest, so the quest is selected for the reading and the log gets
-- its own selection back.
-----------------------------------------------------------------------------
local function rewardValue(v)
    if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

local function rewardItemText(name, texture, count, quality, itemID)
    name, texture = rewardValue(name), rewardValue(texture)
    count, quality, itemID = tonumber(rewardValue(count)), tonumber(rewardValue(quality)), tonumber(rewardValue(itemID))
    if type(name) ~= "string" or name == "" then
        -- item data not loaded yet: asked for, shown on the next hover
        if itemID and C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
            pcall(C_Item.RequestLoadItemDataByID, itemID)
        end
        name = "..."
    end
    local hex = "|cffffffff"
    local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if qc and type(qc.hex) == "string" then hex = qc.hex end
    local icon = (texture and texture ~= "") and ("|T" .. tostring(texture) .. ":14:14:0:0|t ") or ""
    local countText = (count and count > 1) and (" x" .. count) or ""
    return icon .. hex .. name .. "|r" .. countText
end

function ObjectiveTrackerController.questRewards(questID)
    if not questID then return nil end
    local function get(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, a, b, c, d, e, f = pcall(fn, ...)
        if not ok then return nil end
        return a, b, c, d, e, f
    end
    local log = C_QuestLog
    local before = log and rewardValue((get(log.GetSelectedQuest)))
    local switched = false
    if before ~= questID and log and type(log.SetSelectedQuest) == "function" then
        switched = pcall(log.SetSelectedQuest, questID)
    end

    local rewards = { items = {}, choices = {} }
    rewards.xp = tonumber(rewardValue((get(GetQuestLogRewardXP, questID)))) or 0
    rewards.money = tonumber(rewardValue((get(GetQuestLogRewardMoney, questID)))) or 0
    local numItems = tonumber(rewardValue((get(GetNumQuestLogRewards, questID)))) or 0
    for i = 1, numItems do
        local name, texture, count, quality, _, itemID = get(GetQuestLogRewardInfo, i, questID)
        rewards.items[#rewards.items + 1] = rewardItemText(name, texture, count, quality, itemID)
    end
    local numChoices = tonumber(rewardValue((get(GetNumQuestLogChoices, questID)))) or 0
    for i = 1, numChoices do
        local name, texture, count, quality, _, itemID = get(GetQuestLogChoiceInfo, i)
        rewards.choices[#rewards.choices + 1] = rewardItemText(name, texture, count, quality, itemID)
    end

    if switched and type(before) == "number" and before > 0 then
        pcall(log.SetSelectedQuest, before)
    end
    return rewards
end

function ObjectiveTrackerController.addRewardTooltipLines(questData)
    local rewards = questData and ObjectiveTrackerController.questRewards(questData.questID)
    if not rewards then return end
    if rewards.xp <= 0 and rewards.money <= 0 and #rewards.items == 0 and #rewards.choices == 0 then return end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns:L("TRACKER_TT_REWARDS"), STYLE.accent[1], STYLE.accent[2], STYLE.accent[3])
    if rewards.xp > 0 then
        local xpText = type(BreakUpLargeNumbers) == "function" and BreakUpLargeNumbers(rewards.xp) or tostring(rewards.xp)
        GameTooltip:AddLine(ns:L("TRACKER_TT_REWARD_XP") .. " " .. xpText, 1, 1, 1)
    end
    if rewards.money > 0 then
        local moneyText
        if type(GetCoinTextureString) == "function" then
            local ok, s = pcall(GetCoinTextureString, rewards.money)
            if ok then moneyText = s end
        end
        if not moneyText and type(GetMoneyString) == "function" then
            local ok, s = pcall(GetMoneyString, rewards.money, true)
            if ok then moneyText = s end
        end
        if moneyText then GameTooltip:AddLine(moneyText, 1, 1, 1) end
    end
    for _, text in ipairs(rewards.items) do
        GameTooltip:AddLine(text, 1, 1, 1)
    end
    if #rewards.choices > 0 then
        GameTooltip:AddLine(ns:L("TRACKER_TT_REWARD_CHOICE"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
        for _, text in ipairs(rewards.choices) do
            GameTooltip:AddLine("  " .. text, 1, 1, 1)
        end
    end
end

-- party members' quest logs change often: one tracker refresh per half second
local partyRefreshPending = false
function ObjectiveTrackerController.schedulePartyRefresh()
    if partyRefreshPending then return end
    if ns:InitializeDatabase().trackerPartyStatus == false then return end
    partyRefreshPending = true
    C_Timer.After(0.5, function()
        partyRefreshPending = false
        ns:ScheduleTrackerUpdate()
    end)
end

-- Newly accepted quests get a "NEW" mark until the mouse goes over them.
-- Kept per character (the saved data is shared by all characters).
function ObjectiveTrackerController.newQuestSet(create)
    local savedDB = ns:InitializeDatabase()
    local guid = UnitGUID and UnitGUID("player")
    if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then return nil end
    if type(savedDB.trackerNewQuests) ~= "table" then
        if not create then return nil end
        savedDB.trackerNewQuests = {}
    end
    local set = savedDB.trackerNewQuests[guid]
    if not set and create then
        set = {}
        savedDB.trackerNewQuests[guid] = set
    end
    return set
end

function ObjectiveTrackerController.markQuestNew(questID, isNew)
    local set = ObjectiveTrackerController.newQuestSet(isNew)
    if not set then return end
    set[questID] = isNew and true or nil
end

function ObjectiveTrackerController.isQuestNew(questID)
    local set = ObjectiveTrackerController.newQuestSet(false)
    return set and questID and set[questID] or false
end

function ObjectiveTrackerController.acquireTrackerRowWidget(index)
    local line = linePool[index]
    if line then
        line:Show()
        return line
    end

    line = CreateFrame("Button", nil, scrollChild or bodyFrame)
    line:SetHeight(16)
    line:EnableMouse(true)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    line:RegisterForDrag("LeftButton")
    line:SetScript("OnDragStart", ObjectiveTrackerController.startTrackerDrag)
    line:SetScript("OnDragStop", ObjectiveTrackerController.stopTrackerDrag)
    line:EnableMouseWheel(true)
    line:SetScript("OnMouseWheel", ObjectiveTrackerController.onTrackerMouseWheel)

    local hlVal = line:CreateTexture(nil, "BACKGROUND")
    hlVal:SetAllPoints(line)
    ObjectiveTrackerController.assignSolidColor(hlVal, 1, 1, 1, 0.06)
    hlVal:Hide()
    line.hl = hlVal

    local badgeBtn = CreateFrame("Button", nil, line)
    badgeBtn:SetSize(14, 14)
    badgeBtn:SetPoint("TOPLEFT", line, "TOPLEFT", 0, -1)
    badgeBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local badgeTxt = badgeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badgeTxt:SetPoint("CENTER", 0, 0)
    badgeTxt:SetTextColor(unpack(STYLE.textSub))
    badgeBtn.txt = badgeTxt
    line.badgeBtn = badgeBtn

    local extractSafeTooltipText = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    extractSafeTooltipText:SetJustifyH("LEFT")
    extractSafeTooltipText:SetJustifyV("TOP")
    extractSafeTooltipText:SetWordWrap(true)
    if extractSafeTooltipText.SetShadowOffset then
        extractSafeTooltipText:SetShadowOffset(1, -1)
        extractSafeTooltipText:SetShadowColor(0, 0, 0, 0.95)
    end
    line.text = extractSafeTooltipText

    line:SetScript("OnEnter", function(self)
        self.hl:Show()
        local hovered = self.questData and self.questData.questID
        if hovered and ObjectiveTrackerController.isQuestNew(hovered) then
            ObjectiveTrackerController.markQuestNew(hovered, false)
            ns:ScheduleTrackerUpdate()
        end
        if self.questData and GameTooltip then
            local priorityQueue = self.questData
            local cxVal = self:GetCenter() or 0
            local swVal = (UIParent and UIParent:GetWidth()) or 1920
            GameTooltip:SetOwner(self, cxVal < (swVal * 0.5) and "ANCHOR_RIGHT" or "ANCHOR_LEFT")
            local diffHex = ObjectiveTrackerController.resolveDifficultyHex(priorityQueue.level, priorityQueue.questID)
            GameTooltip:SetText(string.format("%s[%d%s] %s|r", diffHex, priorityQueue.level or 1, priorityQueue.tagSuffix or "", priorityQueue.title or ""), 1, 1, 1)
            if priorityQueue.zoneName then
                GameTooltip:AddLine(priorityQueue.zoneName, STYLE.accent[1], STYLE.accent[2], STYLE.accent[3])
            end
            -- what to do (the quest log's short text) and the story, shortened
            local summary, story = ObjectiveTrackerController.questLogTexts(priorityQueue)
            if summary then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(summary, 1, 0.94, 0.78, true)
            end
            if story then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(story, STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3], true)
            end
            if priorityQueue.objectives and #priorityQueue.objectives > 0 then
                GameTooltip:AddLine(" ")
                for _, obj in ipairs(priorityQueue.objectives) do
                    local cHex = ObjectiveTrackerController.resolveObjectiveProgressHex(obj.numFulfilled, obj.numRequired, obj.finished)
                    GameTooltip:AddLine("• " .. cHex .. (obj.text or "") .. "|r", 1, 1, 1, true)
                end
            end
            ObjectiveTrackerController.addRewardTooltipLines(priorityQueue)
            ObjectiveTrackerController.addPartyTooltipLines(priorityQueue)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(ns:L("TRACKER_TT_QUEST_LCLICK"), STYLE.text[1], STYLE.text[2], STYLE.text[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_QUEST_SHIFT"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_QUEST_SHARE"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_QUEST_RCLICK"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            if maxScrollOffset > 0 then
                GameTooltip:AddLine(ns:L("TRACKER_TT_SCROLL"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            end
            GameTooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
            GameTooltip:Show()
            if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
        end
        ObjectiveTrackerController.showQuestOverlay(self)
    end)
    line:SetScript("OnLeave", function(self)
        -- the overlay just went over this line: it keeps the hover
        if questOverlay and questOverlay:IsShown() and questOverlay.line == self then return end
        self.hl:Hide()
        if GameTooltip then GameTooltip:Hide() end
    end)

    linePool[index] = line
    return line
end

function ObjectiveTrackerController.acquireQuestActionItemBtn(index)
    local actionBtn = itemBtnPool[index]
    if not actionBtn then
        actionBtn = CreateFrame("Button", "EzWoWQuest_TrackerItemBtn" .. index, UIParent, "SecureActionButtonTemplate")
        actionBtn:SetSize(20, 20)
        actionBtn:RegisterForClicks("AnyUp", "AnyDown")

        local borderTex = actionBtn:CreateTexture(nil, "BACKGROUND")
        borderTex:SetAllPoints(actionBtn)
        ObjectiveTrackerController.assignSolidColor(borderTex, STYLE.border[1], STYLE.border[2], STYLE.border[3], 0.95)
        actionBtn.border = borderTex

        local iconTex = actionBtn:CreateTexture(nil, "ARTWORK")
        iconTex:SetPoint("TOPLEFT", 1, -1)
        iconTex:SetPoint("BOTTOMRIGHT", -1, 1)
        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        actionBtn.icon = iconTex

        local cdVal = CreateFrame("Cooldown", nil, actionBtn, "CooldownFrameTemplate")
        cdVal:SetAllPoints(iconTex)
        actionBtn.cd = cdVal

        local hlVal = actionBtn:CreateTexture(nil, "HIGHLIGHT")
        hlVal:SetAllPoints(iconTex)
        ObjectiveTrackerController.assignSolidColor(hlVal, 1, 0.85, 0.4, 0.22)

        actionBtn:SetScript("OnEnter", function(self)
            if not self.itemID or not GameTooltip then return end
            local cxVal = self:GetCenter() or 0
            local swVal = (UIParent and UIParent:GetWidth()) or 1920
            GameTooltip:SetOwner(self, cxVal < (swVal * 0.5) and "ANCHOR_RIGHT" or "ANCHOR_LEFT")
            GameTooltip:SetHyperlink("item:" .. tostring(self.itemID))
            GameTooltip:Show()
        end)
        actionBtn:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)
        actionBtn:SetScript("OnUpdate", function(self, elapsed)
            self.cdTimer = (self.cdTimer or 0) - elapsed
            if self.cdTimer > 0 then return end
            self.cdTimer = 0.25
            if self.itemID then
                local start, duration, enabled = ObjectiveTrackerController.resolveItemCooldownSafe(self.itemID)
                if enabled == 1 and duration > 0 then
                    self.cd:SetCooldown(start, duration)
                    self.cd:Show()
                else
                    self.cd:Hide()
                end
            end
        end)

        itemBtnPool[index] = actionBtn
    end
    return actionBtn
end

function ObjectiveTrackerController.dismissUnusedPools(usedLines, usedButtons)
    for indexEntry = usedLines + 1, #linePool do
        linePool[indexEntry]:Hide()
    end
    if not ObjectiveTrackerController.hasInCombat() then
        for indexEntry = usedButtons + 1, #itemBtnPool do
            local unusedBtn = itemBtnPool[indexEntry]
            unusedBtn:SetAttribute("type", nil)
            unusedBtn:SetAttribute("item", nil)
            unusedBtn:Hide()
            -- detach from the tracker so an idle secure button does not keep the tracker protected
            unusedBtn:ClearAllPoints()
            unusedBtn:SetParent(UIParent)
            unusedBtn.itemID = nil
        end
    end
end

function ObjectiveTrackerController.buildCornerGrip(parent, isLeft)
    local cornerResizeGrip = CreateFrame("Button", nil, parent)
    cornerResizeGrip:SetSize(14, 14)
    cornerResizeGrip:SetFrameLevel(parent:GetFrameLevel() + 25)
    cornerResizeGrip:EnableMouse(true)
    cornerResizeGrip:RegisterForClicks("RightButtonUp")

    local bars = {}
    local heights = { 3, 6, 9 }
    for indexEntry = 1, 3 do
        local statusBar = cornerResizeGrip:CreateTexture(nil, "OVERLAY")
        statusBar:SetSize(2, heights[indexEntry])
        if isLeft then
            
            statusBar:SetPoint("BOTTOMLEFT", cornerResizeGrip, "BOTTOMLEFT", 2 + (indexEntry - 1) * 3, 2)
            statusBar:SetSize(2, heights[4 - indexEntry])
        else
            
            statusBar:SetPoint("BOTTOMRIGHT", cornerResizeGrip, "BOTTOMRIGHT", -2 - (3 - indexEntry) * 3, 2)
            statusBar:SetSize(2, heights[indexEntry])
        end
        ObjectiveTrackerController.assignSolidColor(statusBar, STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3], 0.55)
        bars[indexEntry] = statusBar
    end
    cornerResizeGrip.bars = bars

    function cornerResizeGrip:SetHighlightState(active)
        for _, statusBar in ipairs(self.bars) do
            if active then
                ObjectiveTrackerController.assignSolidColor(statusBar, STYLE.accent[1], STYLE.accent[2], STYLE.accent[3], 1.0)
            else
                ObjectiveTrackerController.assignSolidColor(statusBar, STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3], 0.55)
            end
        end
    end

    return cornerResizeGrip
end

function ObjectiveTrackerController.attachResizeHandlers(handle, mode)
    handle:SetScript("OnEnter", function(self)
        if self.SetHighlightState then self:SetHighlightState(true) end
        if resizeGripBR and resizeGripBR.SetHighlightState then resizeGripBR:SetHighlightState(true) end
        if resizeGripBL and resizeGripBL.SetHighlightState then resizeGripBL:SetHighlightState(true) end
        if bodyFrame then
            bodyFrame:SetBackdropBorderColor(unpack(STYLE.accent))
        end
        if GameTooltip then
            local cxVal = self:GetCenter() or 0
            local swVal = (UIParent and UIParent:GetWidth()) or 1920
            GameTooltip:SetOwner(self, cxVal < (swVal * 0.5) and "ANCHOR_RIGHT" or "ANCHOR_LEFT")
            GameTooltip:SetText(ns:L("TRACKER_TITLE"), STYLE.accent[1], STYLE.accent[2], STYLE.accent[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_RESIZE"), STYLE.text[1], STYLE.text[2], STYLE.text[3])
            GameTooltip:Show()
        end
    end)

    handle:SetScript("OnLeave", function(self)
        if not hasResizingTracker then
            if self.SetHighlightState then self:SetHighlightState(false) end
            if resizeGripBR and resizeGripBR.SetHighlightState then resizeGripBR:SetHighlightState(false) end
            if resizeGripBL and resizeGripBL.SetHighlightState then resizeGripBL:SetHighlightState(false) end
            local savedDB = ns:InitializeDatabase()
            if bodyFrame then
                if ObjectiveTrackerController.isSolid(savedDB) then
                    bodyFrame:SetBackdropBorderColor(unpack(STYLE.border))
                else
                    bodyFrame:SetBackdropBorderColor(0, 0, 0, 0)
                end
            end
        end
        if GameTooltip then GameTooltip:Hide() end
    end)

    handle:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ObjectiveTrackerController.resetTrackerSizeOnly()
        end
    end)

    handle:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or not trackerFrame or not bodyFrame then return end
        if ObjectiveTrackerController.hasInCombat() and trackerFrame:IsProtected() then return end

        hasResizingTracker = true
        local startX, startY = GetCursorPosition()
        local effScale = trackerFrame:GetEffectiveScale() or 1
        local startW, startH = ObjectiveTrackerController.resolveTrackerDimensions()

        local calculateCanvasScale = trackerFrame:GetScale() or 1
        local left = trackerFrame:GetLeft()
        local right = trackerFrame:GetRight()
        local top = trackerFrame:GetTop()
        local parentW = UIParent:GetWidth() or 1920
        local parentH = UIParent:GetHeight() or 1080

        if mode == "BR" and left and top and calculateCanvasScale > 0 then
            
            trackerFrame:ClearAllPoints()
            trackerFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, (top * calculateCanvasScale - parentH) / calculateCanvasScale)
        elseif right and top and calculateCanvasScale > 0 then
            
            trackerFrame:ClearAllPoints()
            trackerFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", (right * calculateCanvasScale - parentW) / calculateCanvasScale, (top * calculateCanvasScale - parentH) / calculateCanvasScale)
        end

        self:SetScript("OnUpdate", function()
            local posX, posY = GetCursorPosition()
            local dxVal = (posX - startX) / effScale
            local dyVal = (startY - posY) / effScale

            local newW = startW
            if mode == "BR" then
                newW = ObjectiveTrackerController.clampValue(math.floor(startW + dxVal + 0.5), TRACKER_MIN_WIDTH, TRACKER_MAX_WIDTH)
            elseif mode == "BL" then
                newW = ObjectiveTrackerController.clampValue(math.floor(startW - dxVal + 0.5), TRACKER_MIN_WIDTH, TRACKER_MAX_WIDTH)
            end
            local newH = ObjectiveTrackerController.clampValue(math.floor(startH + dyVal + 0.5), TRACKER_MIN_HEIGHT, TRACKER_MAX_HEIGHT)

            local savedDB = ns:InitializeDatabase()
            if savedDB.trackerWidth ~= newW or savedDB.trackerHeight ~= newH then
                savedDB.trackerWidth = newW
                savedDB.trackerHeight = newH
                ns:UpdateQuestTracker()
            end
        end)
    end)

    handle:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self:SetScript("OnUpdate", nil)
        if hasResizingTracker then
            hasResizingTracker = false
            if resizeGripBR and resizeGripBR.SetHighlightState then resizeGripBR:SetHighlightState(false) end
            if resizeGripBL and resizeGripBL.SetHighlightState then resizeGripBL:SetHighlightState(false) end
            ObjectiveTrackerController.persistTrackerPosition()
            ns:UpdateQuestTracker()
        end
    end)
end

function ObjectiveTrackerController.prepareTrackerFrame()
    if trackerFrame then return trackerFrame end

    local bootstrapW, bootstrapH = ObjectiveTrackerController.resolveTrackerDimensions()

    trackerFrame = CreateFrame("Frame", "EzWoWQuest_TrackerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    trackerFrame:SetSize(bootstrapW, HEADER_HEIGHT + 2 + bootstrapH)
    trackerFrame:SetFrameStrata("MEDIUM")
    trackerFrame:SetFrameLevel(10)
    trackerFrame:SetMovable(true)
    trackerFrame:SetClampedToScreen(true)
    trackerFrame:EnableMouse(true)
    trackerFrame:RegisterForDrag("LeftButton")
    trackerFrame:SetScript("OnDragStart", ObjectiveTrackerController.startTrackerDrag)
    trackerFrame:SetScript("OnDragStop", ObjectiveTrackerController.stopTrackerDrag)
    trackerFrame:EnableMouseWheel(true)
    trackerFrame:SetScript("OnMouseWheel", ObjectiveTrackerController.onTrackerMouseWheel)

    headerBtn = CreateFrame("Button", "EzWoWQuest_TrackerHeader", trackerFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    headerBtn:SetPoint("TOPLEFT", trackerFrame, "TOPLEFT", 0, 0)
    headerBtn:SetPoint("TOPRIGHT", trackerFrame, "TOPRIGHT", 0, 0)
    headerBtn:SetHeight(HEADER_HEIGHT)
    headerBtn:SetBackdrop(FLAT_BACKDROP)
    headerBtn:SetBackdropColor(unpack(STYLE.header))
    headerBtn:SetBackdropBorderColor(unpack(STYLE.border))
    headerBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    headerBtn:RegisterForDrag("LeftButton")
    headerBtn:SetScript("OnDragStart", ObjectiveTrackerController.startTrackerDrag)
    headerBtn:SetScript("OnDragStop", ObjectiveTrackerController.stopTrackerDrag)
    headerBtn:EnableMouseWheel(true)
    headerBtn:SetScript("OnMouseWheel", ObjectiveTrackerController.onTrackerMouseWheel)

    local accentLine = headerBtn:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", headerBtn, "BOTTOMLEFT", 1, 0)
    accentLine:SetPoint("BOTTOMRIGHT", headerBtn, "BOTTOMRIGHT", -1, 0)
    ObjectiveTrackerController.assignSolidColor(accentLine, unpack(STYLE.accent))
    headerBtn.accentLine = accentLine

    local headerText = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerText:SetPoint("LEFT", headerBtn, "LEFT", 8, 0)
    headerText:SetTextColor(unpack(STYLE.accent))
    headerBtn.text = headerText

    local switchSign = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    switchSign:SetPoint("RIGHT", headerBtn, "RIGHT", -8, 0)
    switchSign:SetTextColor(unpack(STYLE.accent))
    headerBtn.toggleSign = switchSign

    -- lock: position and size stay as they are
    -- the same square button as the other EzWoW windows' lock
    local lockBtn = CreateFrame("Button", nil, headerBtn, BackdropTemplateMixin and "BackdropTemplate" or nil)
    lockBtn:SetSize(23, 23)
    lockBtn:SetPoint("RIGHT", switchSign, "LEFT", -6, 0)
    if lockBtn.SetBackdrop then
        lockBtn:SetBackdrop(FLAT_BACKDROP)
        lockBtn:SetBackdropColor(0.114, 0.157, 0.192, 0.92)
        lockBtn:SetBackdropBorderColor(0.204, 0.298, 0.357, 0.95)
    end
    lockBtn.icon = lockBtn:CreateTexture(nil, "ARTWORK")
    lockBtn.icon:SetPoint("TOPLEFT", 3, -3)
    lockBtn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    lockBtn:SetScript("OnClick", function()
        local savedDB = ns:InitializeDatabase()
        savedDB.trackerLocked = not savedDB.trackerLocked or nil
        ns:UpdateQuestTracker()
        if GameTooltip and GameTooltip:GetOwner() == lockBtn then lockBtn:GetScript("OnEnter")(lockBtn) end
    end)
    lockBtn:SetScript("OnEnter", function(self)
        if self.SetBackdropColor then
            self:SetBackdropColor(0.16, 0.24, 0.26, 0.98)
            self:SetBackdropBorderColor(STYLE.accent[1], STYLE.accent[2], STYLE.accent[3], 1)
        end
        if not GameTooltip then return end
        local locked = ns:InitializeDatabase().trackerLocked
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(ns:L(locked and "TRACKER_LOCKED" or "TRACKER_UNLOCKED"), STYLE.accent[1], STYLE.accent[2], STYLE.accent[3])
        GameTooltip:AddLine(ns:L("TRACKER_LOCK_TIP"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3], true)
        GameTooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
        GameTooltip:Show()
        if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
    end)
    lockBtn:SetScript("OnLeave", function(self)
        if self.SetBackdropColor then
            self:SetBackdropColor(0.114, 0.157, 0.192, 0.92)
            self:SetBackdropBorderColor(0.204, 0.298, 0.357, 0.95)
        end
        if GameTooltip then GameTooltip:Hide() end
    end)
    headerBtn.lockBtn = lockBtn
    lockBtn:Hide()

    headerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(STYLE.accent))
        if GameTooltip then
            local cxVal = self:GetCenter() or 0
            local swVal = (UIParent and UIParent:GetWidth()) or 1920
            GameTooltip:SetOwner(self, cxVal < (swVal * 0.5) and "ANCHOR_RIGHT" or "ANCHOR_LEFT")
            GameTooltip:SetText(ns:L("TRACKER_TITLE"), STYLE.accent[1], STYLE.accent[2], STYLE.accent[3])
            GameTooltip:AddLine(ns:L("SECTION_TRACKER"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_HEADER_LCLICK"), STYLE.text[1], STYLE.text[2], STYLE.text[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_HEADER_RCLICK"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            GameTooltip:AddLine(ns:L("TT_DRAG_MOVE"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_RESIZE"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            GameTooltip:AddLine(ns:L("TRACKER_TT_SCROLL"), STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            local scalePct = math.floor(((trackerFrame and trackerFrame:GetScale()) or 1) * 100 + 0.5)
            local isCallOk, wheelStr = pcall(string.format, ns:L("TT_WHEEL_SCALE"), scalePct)
            if isCallOk and wheelStr then
                GameTooltip:AddLine(wheelStr, STYLE.textSub[1], STYLE.textSub[2], STYLE.textSub[3])
            end
            GameTooltip:Show()
        end
    end)
    headerBtn:SetScript("OnLeave", function(self)
        if ObjectiveTrackerController.isSolid(ns:InitializeDatabase()) then
            self:SetBackdropBorderColor(unpack(STYLE.border))
        else
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end
        if GameTooltip then GameTooltip:Hide() end
    end)
    headerBtn:SetScript("OnClick", function(_, button)
        if ObjectiveTrackerController.handleQuickResetClick(button) then return end
        local savedDB = ns:InitializeDatabase()
        if button == "LeftButton" then
            savedDB.trackerExpanded = not (savedDB.trackerExpanded ~= false)
            ns:UpdateQuestTracker()
        elseif button == "RightButton" then
            ns:ToggleSettings()
        end
    end)

    bodyFrame = CreateFrame("Frame", nil, trackerFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    bodyFrame:SetPoint("TOPLEFT", headerBtn, "BOTTOMLEFT", 0, -2)
    bodyFrame:SetPoint("TOPRIGHT", headerBtn, "BOTTOMRIGHT", 0, -2)
    bodyFrame:SetBackdrop(FLAT_BACKDROP)
    bodyFrame:EnableMouse(true)
    bodyFrame:RegisterForDrag("LeftButton")
    bodyFrame:SetScript("OnDragStart", ObjectiveTrackerController.startTrackerDrag)
    bodyFrame:SetScript("OnDragStop", ObjectiveTrackerController.stopTrackerDrag)
    bodyFrame:EnableMouseWheel(true)
    bodyFrame:SetScript("OnMouseWheel", ObjectiveTrackerController.onTrackerMouseWheel)

    scrollFrame = CreateFrame("ScrollFrame", "EzWoWQuest_TrackerScrollFrame", bodyFrame)
    scrollFrame:SetPoint("TOPLEFT", bodyFrame, "TOPLEFT", 2, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", bodyFrame, "BOTTOMRIGHT", -12, 8)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", ObjectiveTrackerController.onTrackerMouseWheel)

    scrollChild = CreateFrame("Frame", "EzWoWQuest_TrackerScrollChild", scrollFrame)
    scrollChild:SetSize(bootstrapW - 14, 100)
    scrollFrame:SetScrollChild(scrollChild)

    scrollBar = CreateFrame("Button", nil, bodyFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    scrollBar:SetWidth(8)
    scrollBar:SetPoint("TOPRIGHT", bodyFrame, "TOPRIGHT", -3, -4)
    scrollBar:SetPoint("BOTTOMRIGHT", bodyFrame, "BOTTOMRIGHT", -3, 16)
    scrollBar:SetFrameLevel(bodyFrame:GetFrameLevel() + 20)
    scrollBar:SetBackdrop(FLAT_BACKDROP)
    scrollBar:SetBackdropColor(0.05, 0.07, 0.09, 0.85)
    scrollBar:SetBackdropBorderColor(STYLE.border[1], STYLE.border[2], STYLE.border[3], 0.75)
    scrollBar:EnableMouse(true)
    scrollBar:EnableMouseWheel(true)
    scrollBar:SetScript("OnMouseWheel", ObjectiveTrackerController.onTrackerMouseWheel)
    scrollBar:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or maxScrollOffset <= 0 then return end
        local _, posY = GetCursorPosition()
        local effScale = self:GetEffectiveScale() or 1
        local cursorLocalY = posY / effScale
        local thumbTop = scrollThumb:GetTop() or 0
        local thumbBottom = scrollThumb:GetBottom() or 0
        local pageStep = math.max(40, (scrollFrame:GetHeight() or 200) * 0.8)
        if cursorLocalY > thumbTop then
            ObjectiveTrackerController.assignTrackerScroll(currentScrollOffset - pageStep)
        elseif cursorLocalY < thumbBottom then
            ObjectiveTrackerController.assignTrackerScroll(currentScrollOffset + pageStep)
        end
    end)

    scrollThumb = CreateFrame("Button", nil, scrollBar)
    scrollThumb:SetHeight(32)
    scrollThumb:SetPoint("TOPLEFT", scrollBar, "TOPLEFT", 1, 0)
    scrollThumb:SetPoint("TOPRIGHT", scrollBar, "TOPRIGHT", -1, 0)
    scrollThumb:EnableMouse(true)
    scrollThumb:EnableMouseWheel(true)
    scrollThumb:SetScript("OnMouseWheel", ObjectiveTrackerController.onTrackerMouseWheel)

    local thumbTex = scrollThumb:CreateTexture(nil, "ARTWORK")
    thumbTex:SetAllPoints(scrollThumb)
    ObjectiveTrackerController.assignSolidColor(thumbTex, STYLE.border[1] * 1.35, STYLE.border[2] * 1.35, STYLE.border[3] * 1.35, 0.95)
    scrollThumb.tex = thumbTex

    scrollThumb:SetScript("OnEnter", function(self)
        ObjectiveTrackerController.assignSolidColor(self.tex, STYLE.accent[1], STYLE.accent[2], STYLE.accent[3], 1.0)
    end)
    scrollThumb:SetScript("OnLeave", function(self)
        if not self.isDragging then
            ObjectiveTrackerController.assignSolidColor(self.tex, STYLE.border[1] * 1.35, STYLE.border[2] * 1.35, STYLE.border[3] * 1.35, 0.95)
        end
    end)
    scrollThumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or maxScrollOffset <= 0 then return end
        self.isDragging = true
        ObjectiveTrackerController.assignSolidColor(self.tex, STYLE.accent[1], STYLE.accent[2], STYLE.accent[3], 1.0)
        local _, startY = GetCursorPosition()
        local startOffset = currentScrollOffset
        local effScale = self:GetEffectiveScale() or 1
        self:SetScript("OnUpdate", function()
            local _, posY = GetCursorPosition()
            local dyVal = (startY - posY) / effScale
            local trackH = scrollBar:GetHeight() or 100
            local thumbH = self:GetHeight() or 24
            local travel = math.max(1, trackH - thumbH)
            local nextOffset = startOffset + (dyVal / travel) * maxScrollOffset
            ObjectiveTrackerController.assignTrackerScroll(nextOffset)
        end)
    end)
    scrollThumb:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self.isDragging = false
        self:SetScript("OnUpdate", nil)
        ObjectiveTrackerController.assignSolidColor(self.tex, STYLE.border[1] * 1.35, STYLE.border[2] * 1.35, STYLE.border[3] * 1.35, 0.95)
    end)

    resizeGripBR = ObjectiveTrackerController.buildCornerGrip(bodyFrame, false)
    resizeGripBR:SetPoint("BOTTOMRIGHT", bodyFrame, "BOTTOMRIGHT", -1, 1)
    ObjectiveTrackerController.attachResizeHandlers(resizeGripBR, "BR")

    resizeGripBL = ObjectiveTrackerController.buildCornerGrip(bodyFrame, true)
    resizeGripBL:SetPoint("BOTTOMLEFT", bodyFrame, "BOTTOMLEFT", 1, 1)
    ObjectiveTrackerController.attachResizeHandlers(resizeGripBL, "BL")

    resizeBarBottom = CreateFrame("Button", nil, bodyFrame)
    resizeBarBottom:SetPoint("BOTTOMLEFT", resizeGripBL, "BOTTOMRIGHT", 0, 0)
    resizeBarBottom:SetPoint("BOTTOMRIGHT", resizeGripBR, "BOTTOMLEFT", 0, 0)
    resizeBarBottom:SetHeight(6)
    resizeBarBottom:SetFrameLevel(bodyFrame:GetFrameLevel() + 24)
    resizeBarBottom:EnableMouse(true)
    resizeBarBottom:RegisterForClicks("RightButtonUp")
    ObjectiveTrackerController.attachResizeHandlers(resizeBarBottom, "B")

    ObjectiveTrackerController.commitSavedTrackerTransform()
    return trackerFrame
end

function ns:UpdateQuestTracker()
    local savedDB = self:InitializeDatabase()
    self:ApplyDefaultTrackerVisibility()

    -- secure quest-item buttons make the tracker (implicitly) protected: Show/Hide/SetSize/SetHeight
    -- would be blocked in combat, so relayout after PLAYER_REGEN_ENABLED instead
    if trackerFrame and ObjectiveTrackerController.hasInCombat() and trackerFrame:IsProtected() then
        return
    end

    if savedDB.enableTracker == false then
        if trackerFrame then
            ObjectiveTrackerController.dismissUnusedPools(0, 0)
            trackerFrame:Hide()
        end
        ObjectiveTrackerController.hideQuestOverlay()
        return
    end

    ObjectiveTrackerController.prepareTrackerFrame()
    trackerFrame:Show()

    if not (ObjectiveTrackerController.hasInCombat() and trackerFrame:IsProtected()) then
        pcall(trackerFrame.SetClampedToScreen, trackerFrame, savedDB.clampToScreen ~= false)
    end

    local userWidth, userBodyHeight = ObjectiveTrackerController.resolveTrackerDimensions()
    local zoneOrder, zones, totalActive = ObjectiveTrackerController.gatherWatchedQuestRecords()
    local maxQuests = ObjectiveTrackerController.resolveMaxQuests()
    local expanded = savedDB.trackerExpanded ~= false
    local presentZoneAndLevel = savedDB.trackerShowZone ~= false

    local baseTitle = string.format("EzWoW - Quest  |cffa7b9c5%d/%d|r", totalActive, maxQuests)
    if hasResizingTracker then
        headerBtn.text:SetText(string.format("%s (%d×%d)", baseTitle, userWidth, userBodyHeight))
    else
        headerBtn.text:SetText(baseTitle)
    end
    headerBtn.toggleSign:SetText(expanded and "[-]" or "[+]")
    -- lock button and resize handles
    local locked = savedDB.trackerLocked and true or false
    local hovered = ObjectiveTrackerController.hoverActive and true or false
    if headerBtn.lockBtn then headerBtn.lockBtn:SetShown(hovered) end
    if headerBtn.lockBtn then
        headerBtn.lockBtn.icon:SetTexture("Interface\\AddOns\\EzWoW-Quest\\Media\\" .. (locked and "lock" or "unlock") .. ".tga")
    end
    if not ObjectiveTrackerController.hasInCombat() then
        for _, handle in ipairs({ resizeGripBR, resizeGripBL, resizeBarBottom }) do
            if handle then handle:SetShown(not locked) end
        end
    end
    -- see-through: header, border and scroll bar too, only the text stays
    local solid = ObjectiveTrackerController.isSolid(savedDB)
    headerBtn:SetBackdropColor(unpack(solid and STYLE.header or { 0, 0, 0, 0 }))
    headerBtn:SetBackdropBorderColor(unpack(solid and STYLE.border or { 0, 0, 0, 0 }))
    if headerBtn.accentLine then headerBtn.accentLine:SetShown(solid) end
    -- the scroll thumb too: only the quest text stays (the wheel still scrolls)
    if scrollThumb then scrollThumb:SetAlpha(solid and 1 or 0) end
    if scrollBar and scrollBar.SetBackdropColor then
        if solid then
            scrollBar:SetBackdropColor(0.05, 0.07, 0.09, 0.85)
            scrollBar:SetBackdropBorderColor(STYLE.border[1], STYLE.border[2], STYLE.border[3], 0.75)
        else
            scrollBar:SetBackdropColor(0, 0, 0, 0)
            scrollBar:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end

    if not expanded then
        ObjectiveTrackerController.dismissUnusedPools(0, 0)
        bodyFrame:Hide()
        trackerFrame:SetSize(userWidth, HEADER_HEIGHT)
        return
    end

    bodyFrame:Show()
    if hasResizingTracker then
        bodyFrame:SetBackdropColor(STYLE.bgMain[1], STYLE.bgMain[2], STYLE.bgMain[3], math.max(0.65, STYLE.bgMain[4]))
        bodyFrame:SetBackdropBorderColor(unpack(STYLE.accent))
    elseif ObjectiveTrackerController.isSolid(savedDB) then
        bodyFrame:SetBackdropColor(unpack(STYLE.bgMain))
        bodyFrame:SetBackdropBorderColor(unpack(STYLE.border))
        if ObjectiveTrackerController.hoverActive then
            bodyFrame:SetBackdropColor(STYLE.bgMain[1], STYLE.bgMain[2], STYLE.bgMain[3], 0.88)
            bodyFrame:SetBackdropBorderColor(STYLE.accent[1], STYLE.accent[2], STYLE.accent[3], 0.90)
        end
    else
        bodyFrame:SetBackdropColor(0, 0, 0, 0)
        bodyFrame:SetBackdropBorderColor(0, 0, 0, 0)
    end

    local innerWidth = userWidth - 18
    scrollChild:SetWidth(innerWidth)

    local lineIdx = 0
    local btnIdx = 0
    local yOffset = -4

    local collapsedZones = savedDB.trackerCollapsedZones
    if type(collapsedZones) ~= "table" then
        collapsedZones = {}
        savedDB.trackerCollapsedZones = collapsedZones
    end
    local collapsedQuests = savedDB.trackerCollapsedQuests
    if type(collapsedQuests) ~= "table" then
        collapsedQuests = {}
        savedDB.trackerCollapsedQuests = collapsedQuests
    end

    local superTrackedID = (C_SuperTrack and type(C_SuperTrack.GetSuperTrackedQuestID) == "function" and C_SuperTrack.GetSuperTrackedQuestID()) or nil

    if #zoneOrder == 0 then
        lineIdx = lineIdx + 1
        local emptyLine = ObjectiveTrackerController.acquireTrackerRowWidget(lineIdx)
        emptyLine.questData = nil
        emptyLine.badgeBtn:Hide()
        emptyLine:ClearAllPoints()
        emptyLine:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LINE_PADDING_X - 2, yOffset)
        emptyLine.text:ClearAllPoints()
        emptyLine.text:SetPoint("TOPLEFT", emptyLine, "TOPLEFT", 2, 0)
        emptyLine.text:SetWidth(innerWidth - 12)
        emptyLine.text:SetFontObject(GameFontDisableSmall)
        emptyLine.text:SetTextColor(unpack(STYLE.textSub))
        emptyLine.text:SetText(self:L("TRACKER_EMPTY"))
        local headerBar = math.max(14, (emptyLine.text:GetStringHeight() or 12) + 2)
        emptyLine:SetSize(innerWidth - 8, headerBar)
        emptyLine:SetScript("OnClick", nil)
        yOffset = yOffset - headerBar - 4
    else
        for _, zoneName in ipairs(zoneOrder) do
            local questList = zones[zoneName]
            local hasZoneCollapsed = presentZoneAndLevel and collapsedZones[zoneName] == true

            if presentZoneAndLevel then
                lineIdx = lineIdx + 1
                local zLine = ObjectiveTrackerController.acquireTrackerRowWidget(lineIdx)
                zLine.questData = nil
                zLine.badgeBtn:Hide()
                zLine:ClearAllPoints()
                zLine:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LINE_PADDING_X - 2, yOffset)
                zLine.text:ClearAllPoints()
                zLine.text:SetPoint("TOPLEFT", zLine, "TOPLEFT", 0, 0)
                zLine.text:SetWidth(innerWidth - 10)
                zLine.text:SetFontObject(GameFontNormalSmall)
                zLine.text:SetTextColor(unpack(STYLE.zone))
                local zDisplay = (hasZoneCollapsed and "▸ " or "▾ ") .. zoneName .. (hasZoneCollapsed and string.format(" (%d) +", #questList) or "")
                zLine.text:SetText(zDisplay)
                local zhVal = math.max(15, (zLine.text:GetStringHeight() or 13) + 2)
                zLine:SetSize(innerWidth - 8, zhVal)
                zLine:SetScript("OnClick", function(_, button)
                    if ObjectiveTrackerController.handleQuickResetClick(button) then return end
                    if button == "LeftButton" then
                        collapsedZones[zoneName] = not collapsedZones[zoneName] or nil
                        ns:UpdateQuestTracker()
                    end
                end)
                yOffset = yOffset - zhVal - 2
            end

            if not hasZoneCollapsed then
                for _, priorityQueue in ipairs(questList) do
                    local qCollapsed = collapsedQuests[priorityQueue.questID] == true
                    local itemIndent = 0

                    if priorityQueue.itemID and priorityQueue.itemIcon and not ObjectiveTrackerController.hasInCombat() then
                        btnIdx = btnIdx + 1
                        local itemBtn = ObjectiveTrackerController.acquireQuestActionItemBtn(btnIdx)
                        itemBtn.itemID = priorityQueue.itemID
                        itemBtn.icon:SetTexture(priorityQueue.itemIcon)
                        itemBtn:SetParent(scrollChild)
                        itemBtn:ClearAllPoints()
                        itemBtn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LINE_PADDING_X - 2, yOffset)
                        itemBtn:SetAttribute("type", "item")
                        itemBtn:SetAttribute("item", "item:" .. tostring(priorityQueue.itemID))
                        itemBtn:Show()
                        itemIndent = 23
                    end

                    lineIdx = lineIdx + 1
                    local qLine = ObjectiveTrackerController.acquireTrackerRowWidget(lineIdx)
                    qLine.questData = priorityQueue
                    qLine:ClearAllPoints()
                    qLine:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LINE_PADDING_X - 2 + itemIndent, yOffset)

                    qLine.badgeBtn:Show()
                    qLine.badgeBtn.txt:SetText(qCollapsed and "+" or "-")
                    qLine.badgeBtn:SetScript("OnClick", function()
                        collapsedQuests[priorityQueue.questID] = not collapsedQuests[priorityQueue.questID] or nil
                        ns:UpdateQuestTracker()
                    end)

                    qLine.text:ClearAllPoints()
                    qLine.text:SetPoint("TOPLEFT", qLine, "TOPLEFT", 15, 0)
                    qLine.text:SetWidth(math.max(80, innerWidth - 24 - itemIndent))
                    qLine.text:SetFontObject(GameFontNormalSmall)

                    local diffHex = presentZoneAndLevel and ObjectiveTrackerController.resolveDifficultyHex(priorityQueue.level, priorityQueue.questID) or "|cffffd100"
                    local lvPrefix = presentZoneAndLevel and string.format("[%d%s] ", priorityQueue.level or 1, priorityQueue.tagSuffix or "") or ""
                    local focusMark = (superTrackedID and superTrackedID == priorityQueue.questID) and "|cff7aa2f7▸ |r" or ""
                    local stateSuffix = ""
                    if priorityQueue.isComplete == 1 then
                        stateSuffix = " |cff40ff59" .. self:L("TRACKER_COMPLETE_TAG") .. "|r"
                    elseif priorityQueue.isComplete == -1 then
                        stateSuffix = " |cffff5555" .. self:L("TRACKER_FAILED_TAG") .. "|r"
                    end

                    local partySuffix = ObjectiveTrackerController.resolvePartySuffix(priorityQueue)
                    local newMark = ObjectiveTrackerController.isQuestNew(priorityQueue.questID) and "|cff4fd1ffNEW|r " or ""
                    qLine.text:SetText(focusMark .. newMark .. diffHex .. lvPrefix .. (priorityQueue.title or "") .. "|r" .. stateSuffix .. partySuffix)

                    local qhVal = math.max(15, (qLine.text:GetStringHeight() or 13) + 2)
                    qLine:SetSize(math.max(90, innerWidth - 8 - itemIndent), qhVal)

                    local function onQuestOrObjClick(_, button)
                        if ObjectiveTrackerController.handleQuickResetClick(button) then return end
                        if button == "LeftButton" then
                            if IsShiftKeyDown and IsShiftKeyDown() then
                                if not ObjectiveTrackerController.insertQuestChatLink(priorityQueue) then
                                    ObjectiveTrackerController.dismissOrUntrackQuest(priorityQueue)
                                end
                            elseif IsControlKeyDown and IsControlKeyDown() then
                                ObjectiveTrackerController.launchQuestInLog(priorityQueue)
                            elseif IsAltKeyDown and IsAltKeyDown() then
                                if ns.QuestShare then
                                    ns.QuestShare.Share(priorityQueue.questID, priorityQueue.logIndex, false)
                                end
                            else
                                -- the quest's details open on the map, then the guide to the
                                -- nearest place to go; the quest log when there is none
                                local qop = ns.QuestObjectivePins
                                local questID = priorityQueue.questID
                                local opened = false
                                if not ObjectiveTrackerController.hasInCombat() then
                                    opened = ObjectiveTrackerController.openQuestOnMap(questID)
                                end
                                local guided
                                if opened then
                                    -- the same as a click in the game's quest list: the guide
                                    -- comes a moment after the details have opened
                                    guided = true
                                    if qop and qop.requestGuide then qop.requestGuide(questID) end
                                else
                                    guided = qop and qop.guideTo and qop.guideTo(questID)
                                end
                                if not guided and not opened then
                                    ObjectiveTrackerController.launchQuestInLog(priorityQueue)
                                end
                            end
                        elseif button == "RightButton" then
                            if IsAltKeyDown and IsAltKeyDown() then
                                ObjectiveTrackerController.dismissOrUntrackQuest(priorityQueue)
                            else
                                collapsedQuests[priorityQueue.questID] = not collapsedQuests[priorityQueue.questID] or nil
                                ns:UpdateQuestTracker()
                            end
                        end
                    end

                    qLine:SetScript("OnClick", onQuestOrObjClick)
                    yOffset = yOffset - qhVal - 1

                    if not qCollapsed then
                        local objTextWidth = math.max(70, innerWidth - 26 - itemIndent)
                        if priorityQueue.isComplete == 1 and #priorityQueue.objectives == 0 then
                            lineIdx = lineIdx + 1
                            local cLine = ObjectiveTrackerController.acquireTrackerRowWidget(lineIdx)
                            cLine.questData = priorityQueue
                            cLine.badgeBtn:Hide()
                            cLine:ClearAllPoints()
                            cLine:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LINE_PADDING_X + 13 + itemIndent, yOffset)
                            cLine.text:ClearAllPoints()
                            cLine.text:SetPoint("TOPLEFT", cLine, "TOPLEFT", 0, 0)
                            cLine.text:SetWidth(objTextWidth)
                            cLine.text:SetFontObject(GameFontHighlightSmall)
                            cLine.text:SetText("|cff40ff59• " .. self:L("TRACKER_QUEST_COMPLETE") .. "|r")
                            local chVal = math.max(14, (cLine.text:GetStringHeight() or 12) + 1)
                            cLine:SetSize(objTextWidth, chVal)
                            cLine:SetScript("OnClick", onQuestOrObjClick)
                            yOffset = yOffset - chVal - 1
                        elseif priorityQueue.isComplete == -1 then
                            lineIdx = lineIdx + 1
                            local fLine = ObjectiveTrackerController.acquireTrackerRowWidget(lineIdx)
                            fLine.questData = priorityQueue
                            fLine.badgeBtn:Hide()
                            fLine:ClearAllPoints()
                            fLine:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LINE_PADDING_X + 13 + itemIndent, yOffset)
                            fLine.text:ClearAllPoints()
                            fLine.text:SetPoint("TOPLEFT", fLine, "TOPLEFT", 0, 0)
                            fLine.text:SetWidth(objTextWidth)
                            fLine.text:SetFontObject(GameFontHighlightSmall)
                            fLine.text:SetText("|cffff5555• " .. self:L("TRACKER_QUEST_FAILED") .. "|r")
                            local fhVal = math.max(14, (fLine.text:GetStringHeight() or 12) + 1)
                            fLine:SetSize(objTextWidth, fhVal)
                            fLine:SetScript("OnClick", onQuestOrObjClick)
                            yOffset = yOffset - fhVal - 1
                        else
                            for _, obj in ipairs(priorityQueue.objectives) do
                                lineIdx = lineIdx + 1
                                local oLine = ObjectiveTrackerController.acquireTrackerRowWidget(lineIdx)
                                oLine.questData = priorityQueue
                                oLine.badgeBtn:Hide()
                                oLine:ClearAllPoints()
                                oLine:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LINE_PADDING_X + 13 + itemIndent, yOffset)
                                oLine.text:ClearAllPoints()
                                oLine.text:SetPoint("TOPLEFT", oLine, "TOPLEFT", 0, 0)
                                oLine.text:SetWidth(objTextWidth)
                                oLine.text:SetFontObject(GameFontHighlightSmall)

                                local cHex = ObjectiveTrackerController.resolveObjectiveProgressHex(obj.numFulfilled, obj.numRequired, obj.finished or priorityQueue.isComplete == 1)
                                oLine.text:SetText(cHex .. "• " .. (obj.text or "") .. "|r")

                                local ohVal = math.max(14, (oLine.text:GetStringHeight() or 12) + 1)
                                oLine:SetSize(objTextWidth, ohVal)
                                oLine:SetScript("OnClick", onQuestOrObjClick)
                                yOffset = yOffset - ohVal - 1
                            end
                        end
                    end

                    yOffset = yOffset - 3
                end
            end
        end
    end

    ObjectiveTrackerController.dismissUnusedPools(lineIdx, btnIdx)

    local totalContentHeight = math.max(20, math.abs(yOffset) + 6)
    scrollChild:SetHeight(totalContentHeight)

    bodyFrame:SetHeight(userBodyHeight)
    trackerFrame:SetSize(userWidth, HEADER_HEIGHT + 2 + userBodyHeight)

    local viewHeight = math.max(20, userBodyHeight - 12)
    if totalContentHeight > viewHeight + 1 then
        maxScrollOffset = totalContentHeight - viewHeight
        currentScrollOffset = ObjectiveTrackerController.clampValue(currentScrollOffset, 0, maxScrollOffset)
        scrollFrame:SetVerticalScroll(currentScrollOffset)
        ObjectiveTrackerController.refreshScrollBarVisual()
    else
        maxScrollOffset = 0
        currentScrollOffset = 0
        scrollFrame:SetVerticalScroll(0)
        scrollBar:Hide()
    end
    ObjectiveTrackerController.refreshQuestOverlay()
end

function ns:ScheduleTrackerUpdate()
    if refreshPending then return end
    refreshPending = true
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0.08, function()
            refreshPending = false
            ns:UpdateQuestTracker()
        end)
    else
        refreshPending = false
        ns:UpdateQuestTracker()
    end
end

local trackerEvents = CreateFrame("Frame")
for _, eventFrame in ipairs({
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_REGEN_ENABLED",
    "QUEST_LOG_UPDATE",
    "QUEST_WATCH_LIST_CHANGED",
    "QUEST_ACCEPTED",
    "QUEST_REMOVED",
    "QUEST_TURNED_IN",
    "SUPER_TRACKING_CHANGED",
    "UNIT_QUEST_LOG_CHANGED",
    "GROUP_ROSTER_UPDATE",
    "BAG_UPDATE_DELAYED",
    "ZONE_CHANGED_NEW_AREA",
}) do
    pcall(trackerEvents.RegisterEvent, trackerEvents, eventFrame)
end

trackerEvents:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "UNIT_QUEST_LOG_CHANGED" then
        if type(arg1) ~= "string" or (type(issecretvalue) == "function" and issecretvalue(arg1)) then return end
        if arg1 ~= "player" then
            if arg1:find("^party%d") then ObjectiveTrackerController.schedulePartyRefresh() end
            return
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        ObjectiveTrackerController.schedulePartyRefresh()
        return
    end
    if event == "PLAYER_LOGIN" then
        ObjectiveTrackerController.installQuestWatchHooks()
    elseif event == "QUEST_WATCH_LIST_CHANGED" then
        local qID = tonumber(arg1)
        if qID and qID > 0 and not hasInternalWatchEdit then
            if arg2 == true then
                ObjectiveTrackerController.onUserWatchQuest(qID)
                return
            elseif arg2 == false then
                ObjectiveTrackerController.onUserUnwatchQuest(qID)
                return
            elseif ObjectiveTrackerController.hasClientQuestWatched(qID) then
                ObjectiveTrackerController.onUserWatchQuest(qID)
                return
            else
                ObjectiveTrackerController.onUserUnwatchQuest(qID)
                return
            end
        end
    elseif event == "QUEST_ACCEPTED" then
        local qID = tonumber(arg2) or tonumber(arg1)
        if qID and qID > 0 then
            ObjectiveTrackerController.markQuestNew(qID, true)
            ObjectiveTrackerController.onUserWatchQuest(qID)
            return
        end
    elseif event == "QUEST_REMOVED" then
        local qID = tonumber(arg1)
        if qID and qID > 0 then
            local savedDB = ns:InitializeDatabase()
            if savedDB.trackerHiddenQuests then savedDB.trackerHiddenQuests[qID] = nil end
            if savedDB.trackerWatchedQuests then savedDB.trackerWatchedQuests[qID] = nil end
            if savedDB.trackerCollapsedQuests then savedDB.trackerCollapsedQuests[qID] = nil end
            ObjectiveTrackerController.markQuestNew(qID, false)
            questMetaCache[qID] = nil
            lastWatchedState[qID] = nil
        end
    end
    ns:ScheduleTrackerUpdate()
end)

-- The mouse anywhere on the list shows its frame, background and lock button;
-- leaving it puts back the normal look (see-through while locked).
local hoverWatch = CreateFrame("Frame")
local hoverElapsed = 0
hoverWatch:SetScript("OnUpdate", function(_, elapsed)
    hoverElapsed = hoverElapsed + (elapsed or 0)
    if hoverElapsed < 0.1 then return end
    hoverElapsed = 0
    local over = false
    if trackerFrame and trackerFrame:IsShown() then
        over = trackerFrame:IsMouseOver() or (questOverlay and questOverlay:IsShown() and questOverlay:IsMouseOver()) or false
        if trackerFrame.isDragging or hasResizingTracker then over = true end
    end
    if over ~= (ObjectiveTrackerController.hoverActive or false) then
        ObjectiveTrackerController.hoverActive = over
        ns:UpdateQuestTracker()
    end
end)
