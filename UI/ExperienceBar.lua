--===========================================================================
-- EzWoW - Quest
-- UI/ExperienceBar.lua : experience window (XP of completed quests, rested,
-- XP per hour, time and kills to the next level), each quest's XP in the
-- tracker and on the map, the "turn in to level up" note and a level summary
--===========================================================================
local ADDON_NAME, ns = ...
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local floor, max, min, ceil, format = math.floor, math.max, math.min, math.ceil, string.format

local XP = {}
ns.XP = XP

local RATE_WINDOW = 15 * 60       -- XP per hour over the last 15 minutes of play
local SESSION_KEEP = 15 * 60      -- a relog within this goes on with the same session
local CHAR_KEEP = 120 * 86400     -- characters not seen this long are dropped
local KILL_SAMPLES = 15           -- XP per kill: the average of the last kills
local COMBAT_GRACE = 3            -- XP this soon after a fight still counts as a kill
local QUEST_MATCH = 3             -- seconds between a turn-in and its XP
local WIN_W, WIN_H = 280, 52
local BAR_W, BAR_H = WIN_W - 12, 12

local COLOR = {
    fill   = { 0.478, 0.635, 0.969 },  -- current XP
    done   = { 0.420, 0.902, 0.639 },  -- completed quests
    open   = { 0.902, 0.761, 0.380 },  -- quests in progress
    rested = { 0.361, 0.561, 1.000 },  -- rested (a band under the bar)
}
local HEX = { done = "6be6a3", open = "e6c261", rested = "5c8fff", muted = "a7b9c5", tag = "8fd3ff" }

-----------------------------------------------------------------------------
-- Safe reads
-----------------------------------------------------------------------------
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return a, b
end

local function num(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return tonumber(v)
end

local function truth(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return false end
    return v and true or false
end

local function fmtNum(n)
    n = floor((tonumber(n) or 0) + 0.5)
    if type(BreakUpLargeNumbers) == "function" then
        local ok, s = pcall(BreakUpLargeNumbers, n)
        if ok and type(s) == "string" then return s end
    end
    return tostring(n)
end

local function fmtDuration(sec)
    sec = tonumber(sec)
    if not sec or sec ~= sec or sec < 0 or sec > 99 * 3600 then return "-" end
    if sec < 60 then return ns:L("XP_UNDER_MIN") end
    local h = floor(sec / 3600)
    local m = floor((sec % 3600) / 60)
    if h > 0 then return format(ns:L("XP_HM"), h, m) end
    return format(ns:L("XP_M"), m)
end

-----------------------------------------------------------------------------
-- State
-----------------------------------------------------------------------------
local state = {
    cur = 0, maxv = 0, level = 0, rested = 0, atMax = true,
    lastCombatEnd = -100,
    pendingQuest = 0, pendingQuestAt = -100,      -- quest XP announced before its XP arrived
    recentOther = 0, recentOtherAt = -100,        -- XP from no fight (a turn-in may come after it)
    totals = { done = 0, doneN = 0, open = 0, openN = 0, list = {}, unknown = 0 },
    xpCache = {},
    disp = nil,                                   -- shown fill (0..1), moves toward the real one
    retry = 0,
}
local char                                        -- this character's saved record
local frame

local function db() return ns:InitializeDatabase() end

local function pctOf(x)
    if not state.maxv or state.maxv <= 0 then return "0%" end
    local p = (tonumber(x) or 0) / state.maxv * 100
    if p >= 100 then return format("%d%%", floor(p + 0.5)) end
    return format("%.1f%%", p)
end
XP.pctOf = pctOf

local function atMaxLevel(level, maxv)
    if truth(call(IsXPUserDisabled)) then return true end
    if truth(call(IsPlayerAtEffectiveMaxLevel)) then return true end
    if not maxv or maxv <= 0 then return true end
    local cap = num(call(GetMaxLevelForPlayerExpansion)) or num(MAX_PLAYER_LEVEL)
    if cap and cap > 0 and level and level >= cap then return true end
    return false
end

local function readXP()
    local cur = num(call(UnitXP, "player"))
    local maxv = num(call(UnitXPMax, "player"))
    local level = num(call(UnitLevel, "player"))
    local rested = num(call(GetXPExhaustion)) or 0
    return cur, maxv, level, rested
end

-----------------------------------------------------------------------------
-- Saved record of this character: session (XP per hour), level, kills
-----------------------------------------------------------------------------
local function newLevelRecord(level)
    return { level = level, start = time(), active = 0, quest = 0, kill = 0, other = 0, quests = 0, kills = 0 }
end

local function loadCharacter()
    local saved = db()
    if type(saved.xpChars) ~= "table" then saved.xpChars = {} end
    local now = time()
    for key, rec in pairs(saved.xpChars) do
        if type(rec) ~= "table" or (tonumber(rec.seen) and now - rec.seen > CHAR_KEEP) then
            saved.xpChars[key] = nil
        end
    end
    local guid = call(UnitGUID, "player")
    if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then return nil end
    local c = saved.xpChars[guid]
    if type(c) ~= "table" then
        c = {}
        saved.xpChars[guid] = c
    end
    -- a relog soon after keeps the session (and its XP per hour)
    local s = c.session
    if not (type(s) == "table" and tonumber(s.seen) and now - s.seen <= SESSION_KEEP) then
        s = { gain = 0, active = 0, events = {}, start = now }
        c.session = s
    end
    s.gain, s.active = tonumber(s.gain) or 0, tonumber(s.active) or 0
    if type(s.events) ~= "table" then s.events = {} end
    s.seen, c.seen = now, now
    if type(c.kills) ~= "table" then c.kills = {} end
    return c
end

local function levelRecord(level)
    if not char then return nil end
    local lv = char.lv
    if type(lv) ~= "table" or lv.level ~= level then
        lv = newLevelRecord(level)
        char.lv = lv
    end
    return lv
end

-- XP per hour: the last 15 minutes of play, and the whole session
function XP.rates()
    local s = char and char.session
    if not s then return nil, nil end
    local from = s.active - RATE_WINDOW
    local keep, recent = {}, 0
    for _, e in ipairs(s.events) do
        if type(e) == "table" and (tonumber(e[1]) or -1) >= from then
            keep[#keep + 1] = e
            recent = recent + (tonumber(e[2]) or 0)
        end
    end
    s.events = keep
    local span = min(RATE_WINDOW, s.active)
    local r15 = span >= 60 and recent / span * 3600 or nil
    local rs = s.active >= 60 and s.gain / s.active * 3600 or nil
    return r15, rs
end

-- XP of one kill, without the rested bonus: the last kills, or the usual
-- XP of a monster of the player's level
function XP.perKill()
    local list = char and char.kills
    if type(list) == "table" and #list > 0 then
        local sum = 0
        for _, v in ipairs(list) do sum = sum + (tonumber(v) or 0) end
        if sum > 0 then return sum / #list, #list end
    end
    return (state.level or 1) * 5 + 45, 0
end

-- kills needed for `need` XP: kills while rested give twice the XP
local function killsFor(need, perKill, rested)
    if not need or need <= 0 or not perKill or perKill <= 0 then return 0 end
    rested = max(0, rested or 0)
    local doubled = floor(rested / perKill)
    if 2 * perKill * doubled >= need then return ceil(need / (2 * perKill)) end
    local left = need - 2 * perKill * doubled
    local bonus = rested - doubled * perKill
    if left <= perKill + bonus then return doubled + 1 end
    return doubled + 1 + ceil((left - perKill - bonus) / perKill)
end
XP.killsFor = killsFor

-----------------------------------------------------------------------------
-- Quests in the log and their XP
-----------------------------------------------------------------------------
local function questXP(questID)
    if not questID then return nil end
    local v = state.xpCache[questID]
    if v then return v end
    v = num(call(GetQuestLogRewardXP, questID))
    if v and v > 0 then state.xpCache[questID] = v end
    return v
end
XP.questXP = questXP

local function questDone(questID)
    local log = C_QuestLog
    if not log then return false end
    if truth(call(log.IsComplete, questID)) then return true end
    -- every objective done counts as complete (like the tracker's "(Complete)")
    local objectives = call(log.GetQuestObjectives, questID)
    if type(objectives) ~= "table" or #objectives == 0 then return false end
    for _, o in ipairs(objectives) do
        if type(o) ~= "table" or not truth(o.finished) then return false end
    end
    if type(IsQuestSequenced) == "function" and truth(call(IsQuestSequenced, questID)) then return false end
    return true
end

function XP.refreshQuests()
    local t = { done = 0, doneN = 0, open = 0, openN = 0, list = {}, unknown = 0 }
    local log = C_QuestLog
    if log and type(log.GetNumQuestLogEntries) == "function" and type(log.GetInfo) == "function" then
        local n = num(call(log.GetNumQuestLogEntries)) or 0
        for i = 1, n do
            local info = call(log.GetInfo, i)
            if type(info) == "table" and not truth(info.isHeader) and not truth(info.isHidden) then
                local id = num(info.questID)
                if id and id > 0 and not truth(call(log.IsFailed, id)) then
                    local xp = questXP(id)
                    if xp == nil then t.unknown = t.unknown + 1 end
                    xp = xp or 0
                    if questDone(id) then
                        t.done, t.doneN = t.done + xp, t.doneN + 1
                        local title = info.title
                        if issecretvalue and issecretvalue(title) then title = nil end
                        t.list[#t.list + 1] = { id = id, title = title, level = num(info.level), xp = xp }
                    else
                        t.open, t.openN = t.open + xp, t.openN + 1
                    end
                end
            end
        end
    end
    table.sort(t.list, function(a, b) return a.xp > b.xp end)
    state.totals = t
end

-- " +1,250" after a quest's name (tracker lines, map marks)
function XP.questSuffix(questID)
    local saved = ns.db
    if not saved or saved.xpQuestTags == false or state.atMax then return "" end
    local xp = questXP(questID)
    if not xp or xp <= 0 then return "" end
    return " |cff" .. HEX.tag .. "+" .. fmtNum(xp) .. "|r"
end

-----------------------------------------------------------------------------
-- XP changes
-----------------------------------------------------------------------------
local floatGain                                    -- set once the window exists

function XP.addGain(gain, restedBefore, restedAfter)
    local s = char and char.session
    if not s then return end
    local now = GetTime()
    s.gain = s.gain + gain
    s.events[#s.events + 1] = { s.active, gain }
    local lv = char.lv
    local questPart = 0
    if state.pendingQuest > 0 and now - state.pendingQuestAt <= QUEST_MATCH then
        questPart = min(gain, state.pendingQuest)
        state.pendingQuest = state.pendingQuest - questPart
    end
    local rest = gain - questPart
    if lv then lv.quest = lv.quest + questPart end
    if rest > 0 then
        local fighting = truth(call(UnitAffectingCombat, "player")) or now - state.lastCombatEnd <= COMBAT_GRACE
        if fighting then
            if lv then
                lv.kill = lv.kill + rest
                lv.kills = lv.kills + 1
            end
            -- the rested bonus is what left the rested pool (at most the kill's own XP)
            local bonus = min(max(0, (restedBefore or 0) - (restedAfter or 0)), rest / 2)
            local base = rest - bonus
            if base > 0 then
                local list = char.kills
                list[#list + 1] = floor(base + 0.5)
                while #list > KILL_SAMPLES do table.remove(list, 1) end
            end
        else
            if lv then lv.other = lv.other + rest end
            state.recentOther, state.recentOtherAt = rest, now
        end
    end
    if floatGain then floatGain(gain, questPart >= rest) end
end

function XP.onQuestTurnedIn(xpReward)
    local xp = num(xpReward) or 0
    local lv = char and char.lv
    if lv then lv.quests = lv.quests + 1 end
    if xp <= 0 then return end
    local now = GetTime()
    -- its XP came first and was taken as "other": it was the quest
    if state.recentOther > 0 and now - state.recentOtherAt <= QUEST_MATCH then
        local m = min(xp, state.recentOther)
        state.recentOther = state.recentOther - m
        if lv then
            lv.other = max(0, lv.other - m)
            lv.quest = lv.quest + m
        end
        xp = xp - m
    end
    if xp > 0 then
        state.pendingQuest = state.pendingQuest + xp
        state.pendingQuestAt = now
    end
end

function XP.onLevelUp(oldLevel, newLevel)
    state.xpCache = {}
    if not char then return end
    local lv = char.lv
    if db().xpLevelSummary ~= false and type(lv) == "table" and lv.level == oldLevel then
        local total = (lv.quest or 0) + (lv.kill or 0) + (lv.other or 0)
        local rate = (lv.active or 0) >= 60 and total / lv.active * 3600 or nil
        ns:PrintMsg(format(ns:L("XP_MSG_LEVEL_UP"), newLevel, oldLevel, fmtDuration(lv.active),
            lv.quests or 0, fmtNum(lv.quest), lv.kills or 0, fmtNum(lv.kill), rate and fmtNum(rate) or "-"))
    end
    char.lv = newLevelRecord(newLevel)
    char.dingAt = nil
end

local processQueued = false
local function queueProcess()
    if processQueued then return end
    processQueued = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0.15, function()
            processQueued = false
            pcall(XP.process)
        end)
    else
        processQueued = false
        pcall(XP.process)
    end
end

-- reads the XP now and books what changed since the last time
function XP.process()
    local cur, maxv, level, rested = readXP()
    if not (cur and maxv and level) then return end
    if not char then
        char = loadCharacter()
        if not char then return end
    end
    local gain, levelled
    if state.level > 0 then
        if level == state.level then
            gain = cur - state.cur
        elseif level > state.level then
            levelled = true
            -- one level: what was left of the old one plus the new XP; several: unknown
            if level == state.level + 1 then gain = (state.maxv - state.cur) + cur end
            -- the new level's XP cap may come a moment after the level
            if maxv == state.maxv and state.retry < 5 then
                state.retry = state.retry + 1
                queueProcess()
                return
            end
        end
    end
    state.retry = 0
    local oldLevel, restedBefore = state.level, state.rested
    state.cur, state.maxv, state.level, state.rested = cur, maxv, level, rested
    state.atMax = atMaxLevel(level, maxv)
    levelRecord(oldLevel > 0 and oldLevel or level)
    if gain and gain > 0 then XP.addGain(gain, restedBefore, rested) end
    if levelled then
        XP.onLevelUp(oldLevel, level)
        XP.refreshQuests()
        if ns.ScheduleTrackerUpdate then ns:ScheduleTrackerUpdate() end
    end
    XP.update()
end

-----------------------------------------------------------------------------
-- Window
-----------------------------------------------------------------------------
-- band: "bottom" / "top" for a thin band along that edge, nil for the full height
local function setSpan(tex, from, to, band)
    from, to = max(0, min(1, from)), max(0, min(1, to))
    if to - from < 0.002 then
        tex:Hide()
        return
    end
    tex:ClearAllPoints()
    if band == "bottom" then
        tex:SetPoint("BOTTOMLEFT", tex:GetParent(), "BOTTOMLEFT", from * BAR_W, 0)
        tex:SetHeight(3)
    elseif band == "top" then
        tex:SetPoint("TOPLEFT", tex:GetParent(), "TOPLEFT", from * BAR_W, 0)
        tex:SetHeight(3)
    else
        tex:SetPoint("TOPLEFT", tex:GetParent(), "TOPLEFT", from * BAR_W, 0)
        tex:SetHeight(BAR_H)
    end
    tex:SetWidth(max(1, (to - from) * BAR_W))
    tex:Show()
end

local function savePosition(f)
    local cx, cy = f:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not (cx and cy and ux and uy) then return end
    local s = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    db().xpPos = { floor((cx * s - ux) + 0.5), floor((cy * s - uy) + 0.5) }
end

function XP.applyPosition()
    if not frame then return end
    local saved = db()
    local scale = tonumber(saved.xpScale) or 1
    frame:SetScale(scale)
    frame:ClearAllPoints()
    local pos = saved.xpPos
    if type(pos) == "table" and tonumber(pos[1]) and tonumber(pos[2]) then
        frame:SetPoint("CENTER", UIParent, "CENTER", pos[1] / scale, pos[2] / scale)
    else
        frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 190)
    end
end

function XP.resetSession()
    if not char then return end
    char.session = { gain = 0, active = 0, events = {}, start = time(), seen = time() }
    ns:PrintMsg(ns:L("XP_MSG_RESET"))
    XP.update()
end

local function addTooltip(self)
    if not GameTooltip then return end
    local t = state.totals
    local maxv = state.maxv
    local cur = state.cur
    local remaining = max(0, maxv - cur)
    local muted = { 0.655, 0.725, 0.773 }
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(ns:L("XP_TT_TITLE"), 0.478, 0.635, 0.969)
    GameTooltip:AddDoubleLine(format(ns:L("XP_LEVEL"), state.level),
        format("%s / %s (%s)", fmtNum(cur), fmtNum(maxv), pctOf(cur)), muted[1], muted[2], muted[3], 1, 1, 1)
    GameTooltip:AddDoubleLine(ns:L("XP_TT_LEFT"), format("%s (%s)", fmtNum(remaining), pctOf(remaining)),
        muted[1], muted[2], muted[3], 1, 1, 1)
    if state.rested > 0 then
        GameTooltip:AddDoubleLine(ns:L("XP_TT_RESTED"), format("%s (%s)", fmtNum(state.rested), pctOf(state.rested)),
            muted[1], muted[2], muted[3], COLOR.rested[1], COLOR.rested[2], COLOR.rested[3])
    end
    if t.doneN > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(format(ns:L("XP_TT_DONE"), t.doneN), format("+%s (%s)", fmtNum(t.done), pctOf(t.done)),
            COLOR.done[1], COLOR.done[2], COLOR.done[3], COLOR.done[1], COLOR.done[2], COLOR.done[3])
        for i = 1, min(#t.list, 10) do
            local q = t.list[i]
            local name = (q.level and q.level > 0 and format("[%d] ", q.level) or "") .. (q.title or ("#" .. q.id))
            GameTooltip:AddDoubleLine("  " .. name, q.xp > 0 and ("+" .. fmtNum(q.xp)) or "?", 0.929, 0.957, 0.969, 0.929, 0.957, 0.969)
        end
        if #t.list > 10 then GameTooltip:AddLine(format("  … +%d", #t.list - 10), muted[1], muted[2], muted[3]) end
        if remaining > 0 and t.done >= remaining then
            GameTooltip:AddLine(ns:L("XP_TT_DING"), COLOR.done[1], COLOR.done[2], COLOR.done[3])
        end
    end
    if t.openN > 0 then
        GameTooltip:AddDoubleLine(format(ns:L("XP_TT_OPEN"), t.openN), format("+%s (%s)", fmtNum(t.open), pctOf(t.open)),
            COLOR.open[1], COLOR.open[2], COLOR.open[3], COLOR.open[1], COLOR.open[2], COLOR.open[3])
    end
    GameTooltip:AddLine(" ")
    local r15, rs = XP.rates()
    GameTooltip:AddDoubleLine(ns:L("XP_TT_RATE"), format("%s / %s", r15 and fmtNum(r15) or "-", rs and fmtNum(rs) or "-"),
        muted[1], muted[2], muted[3], 1, 1, 1)
    local rate = r15 or rs
    local afterTurnIn = max(0, remaining - t.done)
    if rate and rate > 0 then
        local eta = fmtDuration(remaining / rate * 3600)
        if t.done > 0 then eta = eta .. "  (" .. fmtDuration(afterTurnIn / rate * 3600) .. ")" end
        GameTooltip:AddDoubleLine(ns:L("XP_TT_ETA"), eta, muted[1], muted[2], muted[3], 1, 1, 1)
    end
    local perKill, samples = XP.perKill()
    local kills = killsFor(remaining, perKill, state.rested)
    local killText = "~" .. kills
    if t.done > 0 then killText = killText .. "  (~" .. killsFor(afterTurnIn, perKill, state.rested) .. ")" end
    GameTooltip:AddDoubleLine(ns:L("XP_TT_KILLS"), killText, muted[1], muted[2], muted[3], 1, 1, 1)
    GameTooltip:AddDoubleLine(samples > 0 and format(ns:L("XP_TT_PER_KILL"), samples) or ns:L("XP_TT_PER_KILL_EST"),
        fmtNum(perKill), muted[1], muted[2], muted[3], 1, 1, 1)
    local lv = char and char.lv
    if type(lv) == "table" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(ns:L("XP_TT_THIS_LEVEL"), fmtDuration(lv.active), muted[1], muted[2], muted[3], 1, 1, 1)
        GameTooltip:AddLine(format(ns:L("XP_TT_LEVEL_LINE"), lv.quests or 0, fmtNum(lv.quest), lv.kills or 0, fmtNum(lv.kill)),
            muted[1], muted[2], muted[3], true)
    end
    local s = char and char.session
    if s then
        GameTooltip:AddDoubleLine(ns:L("XP_TT_SESSION"), fmtDuration(s.active) .. " · +" .. fmtNum(s.gain),
            muted[1], muted[2], muted[3], 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns:L("XP_TT_HINT"), muted[1], muted[2], muted[3], true)
    GameTooltip:AddDoubleLine(" ", "EzWoW - Quest", 0, 0, 0, 0.5, 0.5, 0.5)
    GameTooltip:Show()
    if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
end

function XP.build()
    if frame then return frame end
    local f = CreateFrame("Frame", "EzWoWQuestXPFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(WIN_W, WIN_H)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    -- the place is kept in the saved data, not by the game (that would win at the next login)
    if f.SetDontSavePosition then pcall(f.SetDontSavePosition, f, true) end
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    if ns.UIKit and ns.UIKit.ApplySurface then
        ns.UIKit:ApplySurface(f, { 0.071, 0.094, 0.122, 0.82 }, { 0.204, 0.298, 0.357, 0.90 })
    end

    f.top = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.top:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -5)
    f.topRight = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.topRight:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -5)
    f.topRight:SetJustifyH("RIGHT")

    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -19)
    bar:SetSize(BAR_W, BAR_H)
    f.bar = bar
    local function tex(layer, sub, color, alpha)
        local t = bar:CreateTexture(nil, layer, nil, sub)
        t:SetColorTexture(color[1], color[2], color[3], alpha or 1)
        t:Hide()
        return t
    end
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0.03, 0.04, 0.05, 0.92)
    -- quests in progress: a thin band along the top (all of them together are often
    -- more than a level, which would cover the whole bar)
    bar.open = tex("ARTWORK", 4, COLOR.open, 0.9)
    bar.done = tex("ARTWORK", 2, COLOR.done, 0.85)
    bar.fill = tex("ARTWORK", 3, COLOR.fill, 1)
    bar.rested = tex("ARTWORK", 4, COLOR.rested, 0.95)
    -- tenths of the level
    for i = 1, 9 do
        local d = bar:CreateTexture(nil, "OVERLAY", nil, 1)
        d:SetColorTexture(0, 0, 0, 0.45)
        d:SetSize(1, BAR_H)
        d:SetPoint("TOPLEFT", bar, "TOPLEFT", floor(BAR_W * i / 10), 0)
    end
    bar.spark = bar:CreateTexture(nil, "OVERLAY", nil, 3)
    bar.spark:SetColorTexture(1, 1, 1, 0.9)
    bar.spark:SetSize(2, BAR_H + 4)
    bar.landing = bar:CreateTexture(nil, "OVERLAY", nil, 2)
    bar.landing:SetColorTexture(COLOR.done[1], COLOR.done[2], COLOR.done[3], 1)
    bar.landing:SetSize(2, BAR_H + 4)
    bar.landing:Hide()
    -- a soft glow when the completed quests are enough to level up
    bar.glow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    bar.glow:SetPoint("TOPLEFT", bar, "TOPLEFT", -3, 3)
    bar.glow:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 3, -3)
    bar.glow:SetColorTexture(COLOR.done[1], COLOR.done[2], COLOR.done[3], 0.6)
    bar.glow:Hide()
    local pulse = bar.glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local a = pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(0.15)
    a:SetToAlpha(0.7)
    a:SetDuration(0.9)
    bar.pulse = pulse

    f.bottom = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.bottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 5)
    f.bottomRight = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.bottomRight:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 5)
    f.bottomRight:SetJustifyH("RIGHT")
    for _, fs in ipairs({ f.top, f.topRight, f.bottom, f.bottomRight }) do
        if fs.SetWordWrap then fs:SetWordWrap(false) end
    end

    -- "+1,250" rising from the end of the bar when XP comes in
    local float = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    float:SetPoint("BOTTOM", bar, "TOPLEFT", 0, 0)
    float:SetAlpha(0)
    local rise = float:CreateAnimationGroup()
    local move = rise:CreateAnimation("Translation")
    move:SetOffset(0, 16)
    move:SetDuration(1.4)
    local fade = rise:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(1.4)
    rise:SetScript("OnFinished", function() float:SetAlpha(0) end)
    floatGain = function(amount, fromQuest)
        if not f:IsShown() then return end
        float:ClearAllPoints()
        local frac = state.maxv > 0 and max(0, min(1, state.cur / state.maxv)) or 0
        float:SetPoint("BOTTOM", bar, "TOPLEFT", max(24, min(BAR_W - 24, frac * BAR_W)), 0)
        local c = fromQuest and COLOR.done or { 1, 1, 1 }
        float:SetTextColor(c[1], c[2], c[3])
        float:SetText("+" .. fmtNum(amount))
        float:SetAlpha(1)
        rise:Stop()
        rise:Play()
    end

    -- the fill moves toward the real XP instead of jumping
    f:SetScript("OnUpdate", function(self, elapsed)
        if state.maxv <= 0 then return end
        local target = max(0, min(1, state.cur / state.maxv))
        local d = state.disp
        if not d or target < d - 0.0005 then
            d = target                                 -- new level (or first look): from here
        elseif d < target then
            d = min(target, d + max(0.002, (target - d) * min(1, elapsed * 5)))
        end
        if d ~= state.disp then
            state.disp = d
            setSpan(bar.fill, 0, d)
            bar.spark:ClearAllPoints()
            bar.spark:SetPoint("CENTER", bar, "LEFT", max(1, d * BAR_W), 0)
        end
    end)

    f:SetScript("OnDragStart", function(self)
        -- moves only with Ctrl held, so it isn't dragged off by accident
        if not (IsControlKeyDown and IsControlKeyDown()) then return end
        self.isDragging = true
        self:StartMoving()
    end)
    local function stopDrag(self)
        if not self.isDragging then return end
        self.isDragging = nil
        self:StopMovingOrSizing()
        if self.SetUserPlaced then pcall(self.SetUserPlaced, self, false) end
        savePosition(self)
        XP.applyPosition()
    end
    f:SetScript("OnDragStop", stopDrag)
    f:SetScript("OnHide", stopDrag)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(self, delta)
        if not (IsControlKeyDown and IsControlKeyDown()) then return end
        local saved = db()
        local scale = tonumber(saved.xpScale) or 1
        scale = floor((scale + (delta > 0 and 0.05 or -0.05)) * 100 + 0.5) / 100
        scale = max(0.6, min(1.6, scale))
        savePosition(self)
        saved.xpScale = math.abs(scale - 1) < 0.005 and nil or scale
        XP.applyPosition()
        if ns.ShowScaleToast then ns:ShowScaleToast(ns:L("XP_TT_TITLE"), floor(scale * 100 + 0.5)) end
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then XP.resetSession() end
    end)
    f:SetScript("OnEnter", function(self)
        self.hovered = true
        addTooltip(self)
    end)
    f:SetScript("OnLeave", function(self)
        self.hovered = nil
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)

    f:Hide()
    frame = f
    XP.applyPosition()
    return f
end

-- texts and bar parts from the current state
function XP.update()
    local saved = db()
    local show = saved.xpWindow ~= false and state.level > 0 and not state.atMax and char ~= nil
    if not show then
        if frame then frame:Hide() end
        return
    end
    local f = XP.build()
    local t = state.totals
    local maxv, cur = state.maxv, state.cur
    local remaining = max(0, maxv - cur)
    local curFrac = cur / maxv

    f.top:SetText(format(ns:L("XP_LEVEL"), state.level) .. "  |cffffffff" .. pctOf(cur) .. "|r")
    local parts = {}
    if t.done > 0 then parts[#parts + 1] = "|cff" .. HEX.done .. format(ns:L("XP_TURNIN"), pctOf(t.done)) .. "|r" end
    if state.rested > 0 then parts[#parts + 1] = "|cff" .. HEX.rested .. format(ns:L("XP_RESTED"), pctOf(state.rested)) .. "|r" end
    f.topRight:SetText(table.concat(parts, "  "))

    local r15, rs = XP.rates()
    local rate = r15 or rs
    if rate and rate > 0 then
        f.bottom:SetText(format(ns:L("XP_PER_HOUR"), fmtNum(rate)) .. " · " .. format(ns:L("XP_ETA"), fmtDuration(remaining / rate * 3600)))
    else
        f.bottom:SetText("|cff" .. HEX.muted .. ns:L("XP_WAIT") .. "|r")
    end
    local perKill = XP.perKill()
    f.bottomRight:SetText(format(ns:L("XP_KILLS"), killsFor(remaining, perKill, state.rested)))

    local bar = f.bar
    local doneTo = curFrac + t.done / maxv
    setSpan(bar.done, curFrac, doneTo)
    setSpan(bar.open, min(1, doneTo), doneTo + t.open / maxv, "top")
    setSpan(bar.rested, curFrac, curFrac + state.rested / maxv, "bottom")
    if t.done > 0 and doneTo < 1 then
        bar.landing:ClearAllPoints()
        bar.landing:SetPoint("CENTER", bar, "LEFT", doneTo * BAR_W, 0)
        bar.landing:Show()
    else
        bar.landing:Hide()
    end
    local ready = remaining > 0 and t.done >= remaining
    if ready then
        if not bar.glow:IsShown() then
            bar.glow:Show()
            bar.pulse:Play()
        end
        if saved.xpDingAlert ~= false and char.dingAt ~= state.level then
            char.dingAt = state.level
            ns:PrintMsg(format(ns:L("XP_MSG_DING_READY"), fmtNum(t.done)))
            if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT.MAP_PING then pcall(PlaySound, SOUNDKIT.MAP_PING) end
        end
    elseif bar.glow:IsShown() then
        bar.pulse:Stop()
        bar.glow:Hide()
    end
    f:Show()
    if f.hovered then addTooltip(f) end
end

-- "/ezq xp": the same numbers in the chat
function XP.report()
    if state.level <= 0 or state.atMax then
        ns:PrintMsg(ns:L("XP_MSG_MAX"))
        return
    end
    local t = state.totals
    local remaining = max(0, state.maxv - state.cur)
    local r15, rs = XP.rates()
    local rate = r15 or rs
    ns:PrintMsg(format(ns:L("XP_MSG_REPORT"), state.level, pctOf(state.cur), t.doneN, fmtNum(t.done), pctOf(t.done),
        rate and fmtNum(rate) or "-", rate and fmtDuration(remaining / rate * 3600) or "-",
        killsFor(remaining, (XP.perKill()), state.rested)))
end

-----------------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------------
local questQueued = false
local function queueQuests()
    if questQueued then return end
    questQueued = true
    local function run()
        questQueued = false
        pcall(XP.refreshQuests)
        pcall(XP.update)
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.5, run) else run() end
end

local driver = CreateFrame("Frame")
local events = {
    PLAYER_ENTERING_WORLD = function()
        if not char then char = loadCharacter() end
        state.level = 0                            -- read fresh, nothing booked for the load
        XP.process()
        queueQuests()
    end,
    PLAYER_XP_UPDATE = function(unit)
        if unit == nil or unit == "player" then queueProcess() end
    end,
    PLAYER_LEVEL_UP = function() queueProcess() end,
    UPDATE_EXHAUSTION = function() queueProcess() end,
    ENABLE_XP_GAIN = function() queueProcess() end,
    DISABLE_XP_GAIN = function() queueProcess() end,
    QUEST_TURNED_IN = function(_, xpReward)
        XP.onQuestTurnedIn(xpReward)
        queueProcess()
        queueQuests()
    end,
    QUEST_LOG_UPDATE = function() queueQuests() end,
    PLAYER_REGEN_ENABLED = function() state.lastCombatEnd = GetTime() end,
    PLAYER_LOGOUT = function()
        if char then
            char.seen = time()
            if char.session then char.session.seen = time() end
            XP.rates()                             -- keeps only the last 15 minutes of entries
        end
    end,
}
for name in pairs(events) do pcall(driver.RegisterEvent, driver, name) end
driver:SetScript("OnEvent", function(_, name, ...)
    local fn = events[name]
    if fn then pcall(fn, ...) end
end)

-- play time (away from keyboard not counted) and a text refresh every few seconds
local acc, textAcc = 0, 0
driver:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 1 then return end
    local dt = min(acc, 5)                         -- a loading screen is not play
    acc = 0
    if char and char.session then
        if not truth(call(UnitIsAFK, "player")) then
            char.session.active = char.session.active + dt
            if type(char.lv) == "table" then char.lv.active = (char.lv.active or 0) + dt end
        end
        char.session.seen = time()
        char.seen = char.session.seen
    end
    textAcc = textAcc + dt
    if textAcc >= 5 then
        textAcc = 0
        if frame and frame:IsShown() then pcall(XP.update) end
    end
end)
