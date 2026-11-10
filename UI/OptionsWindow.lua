--===========================================================================
-- EzWoW - Quest
-- UI/OptionsWindow.lua : EzWoW style settings window, scale toast & slash commands
--===========================================================================
local ADDON_NAME, ns = ...
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall

local SettingsDialog = ns.SettingsDialog or {}
ns.SettingsDialog = SettingsDialog

local ICON_PATH = "Interface\\AddOns\\EzWoW-Quest\\Media\\Icon"
local SETTINGS_NAME = "EzWoWQuestSettings"

local STYLE = {
    bgMain  = { 0.071, 0.094, 0.122, 0.96 },
    bgSub   = { 0.114, 0.157, 0.192, 0.92 },
    bgHover = { 0.165, 0.224, 0.275, 0.95 },
    border  = { 0.204, 0.298, 0.357, 1.00 },
    accent  = { 0.478, 0.635, 0.969, 1.00 },
    text    = { 0.929, 0.957, 0.969, 1.00 },
    textSub = { 0.655, 0.725, 0.773, 1.00 },
    danger  = { 0.906, 0.486, 0.439, 1.00 },
}

local FLAT_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

function SettingsDialog.assignSolidColor(tex, r, g, b, a)
    if not tex then return end
    if tex.SetColorTexture then
        tex:SetColorTexture(r, g, b, a or 1)
    elseif tex.SetTexture then
        tex:SetTexture(r, g, b, a or 1)
    end
end

function SettingsDialog.commitFlatBackdrop(frame, bg, border)
    if not frame or not frame.SetBackdrop then return end
    frame:SetBackdrop(FLAT_BACKDROP)
    local b = bg or STYLE.bgMain
    local e = border or STYLE.border
    frame:SetBackdropColor(b[1], b[2], b[3], b[4] or 1)
    frame:SetBackdropBorderColor(e[1], e[2], e[3], e[4] or 1)
end

function SettingsDialog.buildFlatButton(parent, width, height, text, onClick)
    local actionBtn = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    actionBtn:SetSize(width, height)
    SettingsDialog.commitFlatBackdrop(actionBtn, STYLE.bgSub, STYLE.border)

    local label = actionBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetTextColor(unpack(STYLE.text))
    label:SetText(text or "")
    actionBtn.label = label
    actionBtn.fitWidth = width - 8
    ns.UIKit:FitFontString(label, actionBtn.fitWidth, 1)

    actionBtn:SetScript("OnEnter", function(self)
        SettingsDialog.commitFlatBackdrop(self, STYLE.bgHover, STYLE.accent)
    end)
    actionBtn:SetScript("OnLeave", function(self)
        SettingsDialog.commitFlatBackdrop(self, STYLE.bgSub, STYLE.border)
    end)
    if onClick then
        actionBtn:SetScript("OnClick", onClick)
    end
    return actionBtn
end

-- Sets a button / checkbox label and shrinks long translations to fit
function SettingsDialog.setFittedLabel(widget, text)
    widget.label:SetText(text or "")
    ns.UIKit:FitFontString(widget.label, widget.fitWidth, 1)
end

function SettingsDialog.buildSectionHeader(parent, yOffset)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yOffset)
    holder:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yOffset)
    holder:SetHeight(20)

    local bar = holder:CreateTexture(nil, "ARTWORK")
    bar:SetSize(3, 14)
    bar:SetPoint("LEFT", holder, "LEFT", 0, 0)
    SettingsDialog.assignSolidColor(bar, unpack(STYLE.accent))

    local titleStr = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleStr:SetPoint("LEFT", bar, "RIGHT", 7, 0)
    titleStr:SetTextColor(unpack(STYLE.accent))
    holder.title = titleStr

    local line = holder:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", titleStr, "RIGHT", 10, 0)
    line:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
    SettingsDialog.assignSolidColor(line, STYLE.border[1], STYLE.border[2], STYLE.border[3], 0.65)

    return holder
end

function SettingsDialog.buildFlatCheckbox(parent, x, y, onToggle, width)
    width = width or 440
    local rowWidget = CreateFrame("Button", nil, parent)
    rowWidget:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    rowWidget:SetSize(width, 22)

    local box = CreateFrame("Frame", nil, rowWidget, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetSize(18, 18)
    box:SetPoint("LEFT", rowWidget, "LEFT", 0, 0)
    SettingsDialog.commitFlatBackdrop(box, STYLE.bgSub, STYLE.border)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetSize(10, 10)
    fill:SetPoint("CENTER", box, "CENTER", 0, 0)
    SettingsDialog.assignSolidColor(fill, unpack(STYLE.accent))
    fill:Hide()

    local label = rowWidget:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", box, "RIGHT", 9, 0)
    label:SetPoint("RIGHT", rowWidget, "RIGHT", 0, 0)
    label:SetJustifyH("LEFT")
    label:SetTextColor(unpack(STYLE.text))

    rowWidget.box = box
    rowWidget.fill = fill
    rowWidget.label = label
    rowWidget.fitWidth = width - 18 - 9
    rowWidget.checked = false

    function rowWidget:SetChecked(val)
        self.checked = not not val
        if self.checked then
            self.fill:Show()
            self.box:SetBackdropBorderColor(unpack(STYLE.accent))
        else
            self.fill:Hide()
            self.box:SetBackdropBorderColor(unpack(STYLE.border))
        end
    end

    function rowWidget:SetRowEnabled(enabled)
        self.rowDisabled = not enabled
        self:SetEnabled(enabled)
        self:SetAlpha(enabled and 1 or 0.45)
    end

    rowWidget:SetScript("OnEnter", function(self)
        self.box:SetBackdropBorderColor(unpack(STYLE.accent))
        self.label:SetTextColor(1, 1, 1, 1)
        if GameTooltip and self.label and self.label:GetText() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.label:GetText(), STYLE.accent[1], STYLE.accent[2], STYLE.accent[3], 1, true)
            if self.tipKey then
                GameTooltip:AddLine(ns:L(self.tipKey), STYLE.text[1], STYLE.text[2], STYLE.text[3], true)
            end
            GameTooltip:Show()
        end
    end)
    rowWidget:SetScript("OnLeave", function(self)
        if self.checked then
            self.box:SetBackdropBorderColor(unpack(STYLE.accent))
        else
            self.box:SetBackdropBorderColor(unpack(STYLE.border))
        end
        self.label:SetTextColor(unpack(STYLE.text))
        if GameTooltip then GameTooltip:Hide() end
    end)
    rowWidget:SetScript("OnClick", function(self)
        self:SetChecked(not self.checked)
        if onToggle then
            onToggle(self.checked)
        end
    end)

    return rowWidget
end

-- Tracker sub-options only matter while the tracker is in use
function SettingsDialog.syncTrackerOptionRows(windowFrame)
    local enabled = ns:InitializeDatabase().enableTracker ~= false
    for _, key in ipairs({ "chkHideDefaultTracker", "chkTrackerTrackAll", "chkTrackerShowZone", "chkTrackerShowBg" }) do
        local rowWidget = windowFrame[key]
        if rowWidget and rowWidget.SetRowEnabled then rowWidget:SetRowEnabled(enabled) end
    end
end

-- Map marks need Map Finder's location data
function SettingsDialog.syncMapOptionRows(windowFrame)
    local hasMap = ns.HasMapFinder()
    local savedDB = ns:InitializeDatabase()
    for _, key in ipairs({ "chkQuestLogPins", "chkQuestLogPinsAll", "chkQuestObjectivePins", "chkQuestGiverPins" }) do
        local rowWidget = windowFrame[key]
        if rowWidget and rowWidget.SetRowEnabled then rowWidget:SetRowEnabled(hasMap) end
    end
    if hasMap and windowFrame.chkQuestLogPinsAll then
        windowFrame.chkQuestLogPinsAll:SetRowEnabled(savedDB.questLogPins ~= false)
    end
    if windowFrame.mapNote then
        windowFrame.mapNote:SetShown(not hasMap)
    end
end

local function refreshMapMarks()
    if ns.RefreshQuestLogPins then pcall(ns.RefreshQuestLogPins) end
    if ns.RefreshQuestObjectivePins then pcall(ns.RefreshQuestObjectivePins) end
end

local toastFrame

function ns:ShowScaleToast(frameName, scalePct)
    if not toastFrame then
        toastFrame = CreateFrame("Frame", "EzWoWQuestToast", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        toastFrame:SetSize(250, 32)
        toastFrame:SetPoint("TOP", UIParent, "TOP", 0, -140)
        toastFrame:SetFrameStrata("TOOLTIP")
        SettingsDialog.commitFlatBackdrop(toastFrame, STYLE.bgMain, STYLE.accent)

        local bar = toastFrame:CreateTexture(nil, "ARTWORK")
        bar:SetHeight(2)
        bar:SetPoint("BOTTOMLEFT", toastFrame, "BOTTOMLEFT", 1, 1)
        bar:SetPoint("BOTTOMRIGHT", toastFrame, "BOTTOMRIGHT", -1, 1)
        SettingsDialog.assignSolidColor(bar, unpack(STYLE.accent))

        local displayText = toastFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        displayText:SetPoint("CENTER", 0, 1)
        displayText:SetTextColor(unpack(STYLE.text))
        toastFrame.txt = displayText

        toastFrame:SetScript("OnUpdate", function(self, elapsed)
            self.timer = (self.timer or 0) - elapsed
            if self.timer <= 0 then
                self:Hide()
            elseif self.timer < 0.35 then
                self:SetAlpha(self.timer / 0.35)
            else
                self:SetAlpha(1)
            end
        end)
        toastFrame:Hide()
    end

    toastFrame.txt:SetText(string.format(self:L("TOAST_SCALE"), tostring(frameName), scalePct or 100))
    local boxWidth = (toastFrame.txt:GetStringWidth() or 180) + 36
    if boxWidth < 200 then boxWidth = 200 end
    toastFrame:SetWidth(boxWidth)
    toastFrame.timer = 1.35
    toastFrame:SetAlpha(1)
    toastFrame:Show()
end

local settingsFrame

function ns:CreateSettingsWindow()
    if settingsFrame then return settingsFrame end

    local windowFrame = CreateFrame("Frame", SETTINGS_NAME, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    windowFrame:SetSize(480, 583)
    windowFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    windowFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    windowFrame:SetToplevel(true)
    windowFrame:EnableMouse(true)
    windowFrame:SetMovable(true)
    windowFrame:SetClampedToScreen(true)
    windowFrame:RegisterForDrag("LeftButton")
    windowFrame:SetScript("OnDragStart", windowFrame.StartMoving)
    windowFrame:SetScript("OnDragStop", windowFrame.StopMovingOrSizing)
    SettingsDialog.commitFlatBackdrop(windowFrame, STYLE.bgMain, STYLE.border)
    windowFrame:Hide()

    if type(UISpecialFrames) == "table" then
        local found = false
        for _, name in ipairs(UISpecialFrames) do
            if name == SETTINGS_NAME then found = true break end
        end
        if not found then table.insert(UISpecialFrames, SETTINGS_NAME) end
    end

    local headerRegion = CreateFrame("Frame", nil, windowFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    headerRegion:SetPoint("TOPLEFT", windowFrame, "TOPLEFT", 1, -1)
    headerRegion:SetPoint("TOPRIGHT", windowFrame, "TOPRIGHT", -1, -1)
    headerRegion:SetHeight(56)
    SettingsDialog.commitFlatBackdrop(headerRegion, STYLE.bgSub, STYLE.border)
    headerRegion:EnableMouse(true)
    headerRegion:RegisterForDrag("LeftButton")
    headerRegion:SetScript("OnDragStart", function() windowFrame:StartMoving() end)
    headerRegion:SetScript("OnDragStop", function() windowFrame:StopMovingOrSizing() end)

    local iconTex = headerRegion:CreateTexture(nil, "ARTWORK")
    iconTex:SetSize(28, 28)
    iconTex:SetPoint("LEFT", headerRegion, "LEFT", 14, 0)
    iconTex:SetTexture(ICON_PATH)

    local titleStr = headerRegion:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleStr:SetPoint("TOPLEFT", iconTex, "TOPRIGHT", 10, -1)
    titleStr:SetTextColor(unpack(STYLE.text))
    windowFrame.title = titleStr

    local verText = headerRegion:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    verText:SetPoint("LEFT", titleStr, "RIGHT", 8, 0)
    verText:SetTextColor(unpack(STYLE.textSub))
    -- version comes from the toc so it never goes stale
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local okMeta, tocVersion = false, nil
    if type(getMeta) == "function" then
        okMeta, tocVersion = pcall(getMeta, ADDON_NAME, "Version")
    end
    verText:SetText("v" .. tostring((okMeta and tocVersion) or self.VERSION))

    local subtitleRegion = headerRegion:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitleRegion:SetPoint("BOTTOMLEFT", iconTex, "BOTTOMRIGHT", 10, 1)
    subtitleRegion:SetTextColor(unpack(STYLE.textSub))
    windowFrame.subtitle = subtitleRegion

    local dismissBtn = SettingsDialog.buildFlatButton(headerRegion, 24, 24, "X", function() windowFrame:Hide() end)
    dismissBtn:SetPoint("TOPRIGHT", headerRegion, "TOPRIGHT", -12, -16)

    local accentLine = headerRegion:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(2)
    accentLine:SetPoint("BOTTOMLEFT", headerRegion, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", headerRegion, "BOTTOMRIGHT", 0, 0)
    SettingsDialog.assignSolidColor(accentLine, unpack(STYLE.accent))

    local langLabel = windowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    langLabel:SetPoint("TOPLEFT", windowFrame, "TOPLEFT", 20, -70)
    langLabel:SetTextColor(unpack(STYLE.textSub))
    windowFrame.langLabel = langLabel

    local langBtn = SettingsDialog.buildFlatButton(windowFrame, 160, 22, "Auto", nil)
    langBtn:SetPoint("LEFT", langLabel, "RIGHT", 12, 0)
    windowFrame.langBtn = langBtn

    -- click the box, then pick a language from the list
    local langItems = {}
    for index, item in ipairs(self.SUPPORTED_LANGS) do langItems[index] = { value = item.code, text = item.label } end
    ns.LanguageDropdown.Attach(langBtn, {
        items = langItems,
        colors = { bg = STYLE.bgMain, accent = STYLE.accent },
        get = function() return ns:InitializeDatabase().lang or "Auto" end,
        set = function(code)
            ns:InitializeDatabase().lang = code
            ns:RefreshSettingsUI()
            refreshMapMarks()
        end,
    })

    -- Quest tracker
    windowFrame.secTracker = SettingsDialog.buildSectionHeader(windowFrame, -98)
    windowFrame.chkEnableTracker = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -122, function(checked)
        ns:InitializeDatabase().enableTracker = checked
        if ns.UpdateQuestTracker then ns:UpdateQuestTracker() end
        SettingsDialog.syncTrackerOptionRows(windowFrame)
    end)
    windowFrame.chkHideDefaultTracker = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -145, function(checked)
        ns:InitializeDatabase().hideDefaultTracker = checked
        if ns.ApplyDefaultTrackerVisibility then ns:ApplyDefaultTrackerVisibility() end
    end)
    windowFrame.chkTrackerTrackAll = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -168, function(checked)
        local savedDB = ns:InitializeDatabase()
        savedDB.trackerTrackAll = checked
        if checked then savedDB.trackerHiddenQuests = {} end
        if ns.UpdateQuestTracker then ns:UpdateQuestTracker() end
    end)
    windowFrame.chkTrackerShowZone = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -191, function(checked)
        ns:InitializeDatabase().trackerShowZone = checked
        if ns.UpdateQuestTracker then ns:UpdateQuestTracker() end
    end)
    windowFrame.chkTrackerShowBg = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -214, function(checked)
        ns:InitializeDatabase().trackerShowBg = checked
        if ns.UpdateQuestTracker then ns:UpdateQuestTracker() end
    end)

    -- Automation and party messages (two columns)
    windowFrame.secQuest = SettingsDialog.buildSectionHeader(windowFrame, -246)
    local function questCheck(x, y, key)
        return SettingsDialog.buildFlatCheckbox(windowFrame, x, y, function(checked)
            ns:InitializeDatabase()[key] = checked
            if ns.UpdateQuestTracker then ns:UpdateQuestTracker() end
        end, 215)
    end
    windowFrame.chkQuestAccept = questCheck(20, -270, "questAutoAccept")
    windowFrame.chkQuestComplete = questCheck(245, -270, "questAutoComplete")
    windowFrame.chkQuestSkip = questCheck(20, -293, "questSkipRisky")
    windowFrame.chkQuestBest = questCheck(245, -293, "questMarkBest")
    windowFrame.chkQuestSkipItems = questCheck(20, -316, "questSkipItems")
    windowFrame.chkQuestAnnounce = questCheck(245, -316, "questPartyAnnounce")
    windowFrame.chkQuestAutoShare = questCheck(20, -339, "questAutoShare")
    windowFrame.chkQuestAutoShare.tipKey = "TIP_QUEST_AUTO_SHARE"
    windowFrame.chkTrackerParty = questCheck(245, -339, "trackerPartyStatus")
    windowFrame.chkTrackerParty.tipKey = "TIP_TRACKER_PARTY"

    -- Map and minimap marks
    windowFrame.secMap = SettingsDialog.buildSectionHeader(windowFrame, -371)
    windowFrame.chkQuestLogPins = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -395, function(checked)
        ns:InitializeDatabase().questLogPins = checked
        SettingsDialog.syncMapOptionRows(windowFrame)
        refreshMapMarks()
    end)
    windowFrame.chkQuestLogPins.tipKey = "TIP_QUEST_LOG_PINS"
    windowFrame.chkQuestLogPinsAll = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -418, function(checked)
        ns:InitializeDatabase().questLogPinsAll = checked
        refreshMapMarks()
    end)
    windowFrame.chkQuestLogPinsAll.tipKey = "TIP_QUEST_LOG_PINS_ALL"
    windowFrame.chkQuestObjectivePins = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -441, function(checked)
        ns:InitializeDatabase().questObjectivePins = checked
        refreshMapMarks()
    end)
    windowFrame.chkQuestObjectivePins.tipKey = "TIP_QUEST_OBJECTIVE_PINS"
    windowFrame.chkQuestGiverPins = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -464, function(checked)
        ns:InitializeDatabase().questGiverPins = checked
        refreshMapMarks()
    end)
    windowFrame.chkQuestGiverPins.tipKey = "TIP_QUEST_GIVER_PINS"
    windowFrame.chkQuestShareData = SettingsDialog.buildFlatCheckbox(windowFrame, 20, -487, function(checked)
        ns:InitializeDatabase().questShareData = checked
        if ns.DataShare and ns.DataShare.setEnabled then pcall(ns.DataShare.setEnabled) end
    end)
    windowFrame.chkQuestShareData.tipKey = "TIP_QUEST_SHARE_DATA"

    local mapNote = windowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mapNote:SetPoint("TOPLEFT", windowFrame, "TOPLEFT", 22, -515)
    mapNote:SetPoint("TOPRIGHT", windowFrame, "TOPRIGHT", -20, -515)
    mapNote:SetJustifyH("LEFT")
    mapNote:SetTextColor(unpack(STYLE.danger))
    mapNote:Hide()
    windowFrame.mapNote = mapNote

    local footerRegion = CreateFrame("Frame", nil, windowFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    footerRegion:SetPoint("BOTTOMLEFT", windowFrame, "BOTTOMLEFT", 1, 1)
    footerRegion:SetPoint("BOTTOMRIGHT", windowFrame, "BOTTOMRIGHT", -1, 1)
    footerRegion:SetHeight(40)
    SettingsDialog.commitFlatBackdrop(footerRegion, STYLE.bgSub, STYLE.border)

    windowFrame.btnDefaults = SettingsDialog.buildFlatButton(footerRegion, 136, 24, "", function()
        ns:ResetToDefaults()
    end)
    windowFrame.btnDefaults:SetPoint("LEFT", footerRegion, "LEFT", 14, 0)

    windowFrame.btnResetTracker = SettingsDialog.buildFlatButton(footerRegion, 176, 24, "", function()
        if ns.ResetQuestTrackerPosition then ns:ResetQuestTrackerPosition(false) end
    end)
    windowFrame.btnResetTracker:SetPoint("RIGHT", footerRegion, "RIGHT", -14, 0)

    local footerHint = footerRegion:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footerHint:SetPoint("LEFT", windowFrame.btnDefaults, "RIGHT", 6, 0)
    footerHint:SetPoint("RIGHT", windowFrame.btnResetTracker, "LEFT", -6, 0)
    footerHint:SetJustifyH("CENTER")
    if footerHint.SetWordWrap then footerHint:SetWordWrap(false) end
    footerHint:SetTextColor(unpack(STYLE.textSub))
    windowFrame.footerHint = footerHint

    windowFrame:SetScript("OnShow", function()
        ns:RefreshSettingsUI()
    end)
    windowFrame:SetScript("OnHide", function()
        ns.LanguageDropdown.Close(windowFrame.langBtn)
    end)

    settingsFrame = windowFrame
    self:RefreshSettingsUI()
    return windowFrame
end

function ns:RefreshSettingsUI()
    local savedDB = self:InitializeDatabase()
    if settingsFrame then
        local w = settingsFrame
        w.title:SetText(self:L("ADDON_TITLE"))
        w.subtitle:SetText(self:L("ADDON_SUBTITLE"))
        w.langLabel:SetText(self:L("OPT_LANGUAGE"))

        local langLabel = "Auto"
        for _, item in ipairs(self.SUPPORTED_LANGS) do
            if item.code == (savedDB.lang or "Auto") then
                langLabel = item.label
                break
            end
        end
        SettingsDialog.setFittedLabel(w.langBtn, langLabel .. "  ▾")

        w.secTracker.title:SetText(self:L("SECTION_TRACKER"))
        SettingsDialog.setFittedLabel(w.chkEnableTracker, self:L("OPT_ENABLE_TRACKER"))
        w.chkEnableTracker:SetChecked(savedDB.enableTracker ~= false)
        SettingsDialog.setFittedLabel(w.chkHideDefaultTracker, self:L("OPT_HIDE_DEFAULT_TRACKER"))
        w.chkHideDefaultTracker:SetChecked(savedDB.hideDefaultTracker ~= false)
        SettingsDialog.setFittedLabel(w.chkTrackerTrackAll, self:L("OPT_TRACKER_ALL_QUESTS"))
        w.chkTrackerTrackAll:SetChecked(savedDB.trackerTrackAll ~= false)
        SettingsDialog.setFittedLabel(w.chkTrackerShowZone, self:L("OPT_TRACKER_SHOW_ZONE"))
        w.chkTrackerShowZone:SetChecked(savedDB.trackerShowZone ~= false)
        SettingsDialog.setFittedLabel(w.chkTrackerShowBg, self:L("OPT_TRACKER_SHOW_BG"))
        w.chkTrackerShowBg:SetChecked(savedDB.trackerShowBg ~= false)
        SettingsDialog.syncTrackerOptionRows(w)

        w.secQuest.title:SetText(self:L("SECTION_QUEST_AUTO"))
        SettingsDialog.setFittedLabel(w.chkQuestAccept, self:L("OPT_QUEST_ACCEPT"))
        w.chkQuestAccept:SetChecked(savedDB.questAutoAccept == true)
        SettingsDialog.setFittedLabel(w.chkQuestComplete, self:L("OPT_QUEST_COMPLETE"))
        w.chkQuestComplete:SetChecked(savedDB.questAutoComplete == true)
        SettingsDialog.setFittedLabel(w.chkQuestSkip, self:L("OPT_QUEST_SKIP"))
        w.chkQuestSkip:SetChecked(savedDB.questSkipRisky ~= false)
        SettingsDialog.setFittedLabel(w.chkQuestBest, self:L("OPT_QUEST_BEST"))
        w.chkQuestBest:SetChecked(savedDB.questMarkBest ~= false)
        SettingsDialog.setFittedLabel(w.chkQuestSkipItems, self:L("OPT_QUEST_SKIP_ITEMS"))
        w.chkQuestSkipItems:SetChecked(savedDB.questSkipItems == true)
        SettingsDialog.setFittedLabel(w.chkQuestAnnounce, self:L("OPT_QUEST_ANNOUNCE"))
        w.chkQuestAnnounce:SetChecked(savedDB.questPartyAnnounce == true)
        SettingsDialog.setFittedLabel(w.chkQuestAutoShare, self:L("OPT_QUEST_AUTO_SHARE"))
        w.chkQuestAutoShare:SetChecked(savedDB.questAutoShare == true)
        SettingsDialog.setFittedLabel(w.chkTrackerParty, self:L("OPT_TRACKER_PARTY"))
        w.chkTrackerParty:SetChecked(savedDB.trackerPartyStatus ~= false)

        w.secMap.title:SetText(self:L("SECTION_MAP"))
        SettingsDialog.setFittedLabel(w.chkQuestLogPins, self:L("questLogPins"))
        w.chkQuestLogPins:SetChecked(savedDB.questLogPins ~= false)
        SettingsDialog.setFittedLabel(w.chkQuestLogPinsAll, self:L("questLogPinsAll"))
        w.chkQuestLogPinsAll:SetChecked(savedDB.questLogPinsAll == true)
        SettingsDialog.setFittedLabel(w.chkQuestObjectivePins, self:L("questObjectivePins"))
        w.chkQuestObjectivePins:SetChecked(savedDB.questObjectivePins ~= false)
        SettingsDialog.setFittedLabel(w.chkQuestGiverPins, self:L("questGiverPins"))
        w.chkQuestGiverPins:SetChecked(savedDB.questGiverPins ~= false)
        SettingsDialog.setFittedLabel(w.chkQuestShareData, self:L("questShareData"))
        -- the shared setting (Libs/EzWoWShare), also changed with /ezshare
        w.chkQuestShareData:SetChecked(ns.DataShare and ns.DataShare.isEnabled() or false)
        w.mapNote:SetText(self:L("MAP_NEEDS_MAPFINDER"))
        SettingsDialog.syncMapOptionRows(w)

        SettingsDialog.setFittedLabel(w.btnDefaults, self:L("BTN_RESET_DEFAULTS"))
        SettingsDialog.setFittedLabel(w.btnResetTracker, self:L("BTN_RESET_TRACKER"))
        w.footerHint:SetText(self:L("HINT_FOOTER"))
    end

    if self.UpdateQuestTracker then
        self:UpdateQuestTracker()
    end
    if self.canvasPanel and self.canvasPanel.RefreshTexts then
        self.canvasPanel:RefreshTexts()
    end
end

-- Every setting back to its default; learned quest data is kept.
local KEEP_ON_RESET = { questDropSources = true, questStarters = true, questEnders = true, questEventSpots = true, questDropItems = true, questEventShared = true, questGivers = true, lang = true }

function ns:ResetToDefaults()
    local savedDB = self:InitializeDatabase()
    for key, value in pairs(self.DEFAULTS) do
        if not KEEP_ON_RESET[key] then
            if type(value) == "table" then
                savedDB[key] = {}
            else
                savedDB[key] = value
            end
        end
    end
    if self.ResetQuestTrackerPosition then
        self:ResetQuestTrackerPosition(true)
    end
    refreshMapMarks()
    self:PrintMsg(self:L("MSG_DEFAULTS_RESET"))
    self:RefreshSettingsUI()
end

function ns:ToggleSettings()
    local windowFrame = self:CreateSettingsWindow()
    if windowFrame:IsShown() then
        windowFrame:Hide()
    else
        self:RefreshSettingsUI()
        windowFrame:Show()
    end
end

function ns:RegisterBlizzardCanvas()
    if self.canvasPanel then return end

    local panel = CreateFrame("Frame", "EzWoWQuestCanvasPanel", UIParent)
    panel.name = "EzWoW - Quest"
    panel:Hide()

    local iconTex = panel:CreateTexture(nil, "ARTWORK")
    iconTex:SetSize(32, 32)
    iconTex:SetPoint("TOPLEFT", 18, -18)
    iconTex:SetTexture(ICON_PATH)

    local titleStr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    titleStr:SetPoint("LEFT", iconTex, "RIGHT", 10, 0)
    titleStr:SetTextColor(unpack(STYLE.accent))

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", iconTex, "BOTTOMLEFT", 0, -14)
    desc:SetWidth(520)
    desc:SetJustifyH("LEFT")
    desc:SetSpacing(4)
    desc:SetTextColor(unpack(STYLE.text))

    local launchBtn = SettingsDialog.buildFlatButton(panel, 220, 28, "", function()
        ns:ToggleSettings()
    end)
    launchBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -18)

    local slashInfo = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    slashInfo:SetPoint("TOPLEFT", launchBtn, "BOTTOMLEFT", 0, -14)
    slashInfo:SetTextColor(unpack(STYLE.textSub))

    function panel:RefreshTexts()
        titleStr:SetText(ns:L("ADDON_TITLE"))
        desc:SetText(ns:L("CANVAS_DESC"))
        SettingsDialog.setFittedLabel(launchBtn, ns:L("CANVAS_OPEN_BTN"))
        slashInfo:SetText(ns:L("CANVAS_SLASH_INFO"))
    end

    panel:SetScript("OnShow", function(self)
        self:RefreshTexts()
    end)
    panel:RefreshTexts()

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok and category then
            pcall(Settings.RegisterAddOnCategory, category)
        end
    elseif InterfaceOptions_AddCategory then
        pcall(InterfaceOptions_AddCategory, panel)
    end

    self.canvasPanel = panel
end

function ns:InitUI()
    self:RegisterBlizzardCanvas()
end

SLASH_EZWOWQUEST1 = "/ezq"
SLASH_EZWOWQUEST2 = "/퀘스트"

SlashCmdList["EZWOWQUEST"] = function(msg)
    local cmd = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))
    if cmd == "reset" or cmd == "초기화" then
        if ns.ResetQuestTrackerPosition then ns:ResetQuestTrackerPosition(false) end
    elseif cmd == "help" or cmd == "?" or cmd == "도움말" then
        ns:PrintMsg(ns:L("MSG_HELP"))
    else
        ns:ToggleSettings()
    end
end
