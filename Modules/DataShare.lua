--===========================================================================
-- EzWoW - Quest
-- Modules/DataShare.lua : the quest addon's side of the shared records
-- (Libs/EzWoWShare does the recording, sharing and saving for every EzWoW
-- addon; this file connects the quest options and map marks to it)
--===========================================================================
local _, ns = ...

local DataShare = {}
ns.DataShare = DataShare

local pcall = pcall

local function share() return ns.Share end

-- options window: the check box shows and sets the shared setting
function DataShare.isEnabled()
    local s = share()
    return s and s.IsEnabled() or false
end

function DataShare.setEnabled()
    local s = share()
    if not (s and ns.DB) then return end
    s.SetEnabled(ns.DB.questShareData ~= false, ns.DB.questShareChannel ~= false)
end

-- map marks pick up records confirmed by other players
local function onChanged(kinds)
    if type(kinds) == "table" and not kinds.quest then return end
    if ns.QuestLogPins and ns.QuestLogPins.resetNpcQuests then pcall(ns.QuestLogPins.resetNpcQuests) end
    if ns.QuestObjectivePins and ns.QuestObjectivePins.refreshAll then pcall(ns.QuestObjectivePins.refreshAll) end
    if ns.RefreshQuestLogPins then pcall(ns.RefreshQuestLogPins) end
end
DataShare.onChanged = onChanged

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    local s = share()
    if not s then return end
    s.RegisterCallback("EzWoW-Quest", onChanged)
    -- sharing turned off in this addon's options before the records moved to
    -- the shared library: that choice carries over once
    if ns.DB and not ns.DB.shareSettingMoved then
        ns.DB.shareSettingMoved = true
        if ns.DB.questShareData == false or ns.DB.questShareChannel == false then
            s.SetEnabled(ns.DB.questShareData ~= false, ns.DB.questShareChannel ~= false)
        end
    end
end)
