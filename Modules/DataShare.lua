--===========================================================================
-- EzWoW - Quest
-- Modules/DataShare.lua : sharing learned quest spots between players of
-- this addon (addon messages only; nothing appears in the chat windows)
--===========================================================================
-- What is shared: only what this character learned itself -
--   E  the NPC / object a quest is turned in to (and the spot)
--   D  a creature a quest item dropped from (by the item's name)
--   O  an object a quest item was looted from, with its spot
--   V  the spot an "event" objective (reach / scout a place) was completed
--   I  a creature or object a quest item (by item ID) was looted from
-- Received records wait until enough different players sent the same one:
-- one from the party, raid or guild, two from the server-wide channel.
-- Received records are never sent on, and never replace this character's
-- own records. Senders are kept only as a number (no names are saved).
local _, ns = ...

local DataShare = {}
ns.DataShare = DataShare

local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local floor, format, concat = math.floor, string.format, table.concat

local PREFIX = "EzWoWQData"           -- at most 16 characters
local CHANNEL_NAME = "EzWoWQuestData"
local MAX_MSG = 240                   -- addon messages are limited to 255 bytes
local SEND_EVERY = 8                  -- seconds between outgoing messages
local RESEND_AFTER = 20 * 60          -- everything is sent again after this long
local CONFIRM_GROUP, CONFIRM_PUBLIC = 1, 2
local INBOX_DAYS = 14
local INBOX_MAX = 6000
local RECEIVE_PER_MINUTE = 400        -- records accepted from one sender

local function isSecret(v) return issecretvalue and issecretvalue(v) end

local function enabled()
    return ns.DB and ns.DB.questShareData ~= false
end

local function now()
    return (type(time) == "function" and time()) or 0
end

-----------------------------------------------------------------------------
-- Record encoding
-----------------------------------------------------------------------------
local function num(v)
    local text = format("%.1f", v):gsub("%.0$", "")
    return text
end

local function spotText(spot)
    if type(spot) ~= "table" or type(spot[1]) ~= "number" or type(spot[2]) ~= "number" or type(spot[3]) ~= "number" then
        return nil
    end
    return spot[1] .. "," .. num(spot[2]) .. "," .. num(spot[3])
end

local function intIn(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= floor(v) or v < lo or v > hi then return nil end
    return v
end

local function parseSpot(text)
    if type(text) ~= "string" then return nil end
    local c, x, y = text:match("^(%d+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    c, x, y = intIn(c, 0, 100000), tonumber(x), tonumber(y)
    if not (c and x and y) or x ~= x or y ~= y or x < -100000 or x > 100000 or y < -100000 or y > 100000 then return nil end
    return { c, x, y }
end

-- item name keys are kept as the quest objective pins normalize them
local function cleanName(text)
    if type(text) ~= "string" or text == "" or #text > 90 or isSecret(text) then return nil end
    -- control characters by byte range: "%c" can match bytes of Hangul / CJK letters
    if text:find("[\1-\31\127|;]") or text:find("\0", 1, true) then return nil end
    if text ~= text:lower() then return nil end
    return text
end

local function locale()
    local loc = (GetLocale and GetLocale()) or "enUS"
    if loc == "esMX" then loc = "esES" elseif loc == "enGB" then loc = "enUS" end
    return loc
end

-- This character's own records, as message parts: { kind, body } where body
-- has no ";" (records are joined with ";").
local function ownRecords()
    local list = {}
    local db = ns.DB
    if not db then return list end
    if type(db.questEnders) == "table" then
        for questID, rec in pairs(db.questEnders) do
            if type(questID) == "number" and type(rec) == "table" and not rec.shared and type(rec.key) == "string" then
                local kind, id = rec.key:match("^(%a)%a*:(%d+)$")
                if kind == "n" or kind == "o" then
                    list[#list + 1] = { "E", questID .. "," .. kind .. "," .. id .. (spotText(rec.spot) and ("," .. spotText(rec.spot)) or "") }
                end
            end
        end
    end
    if type(db.questEventSpots) == "table" then
        for questID, spots in pairs(db.questEventSpots) do
            if type(questID) == "number" and type(spots) == "table" then
                for index, spot in pairs(spots) do
                    local text = type(index) == "number" and type(spot) == "table" and not spot.shared and spotText(spot)
                    if text then list[#list + 1] = { "V", questID .. "," .. index .. "," .. text } end
                end
            end
        end
    end
    if type(db.questDropItems) == "table" then
        for itemID, ids in pairs(db.questDropItems) do
            if type(itemID) == "number" and type(ids) == "table" then
                for id, value in pairs(ids) do
                    if type(id) == "number" and value == true then
                        list[#list + 1] = { "I", itemID .. ",n," .. id }
                    elseif type(id) == "string" and type(value) == "table" and not value.shared then
                        local objectID = tonumber(id:match("^o:(%d+)$"))
                        local text = objectID and spotText(value)
                        if text then list[#list + 1] = { "I", itemID .. ",o," .. objectID .. "," .. text } end
                    end
                end
            end
        end
    end
    if type(db.questDropSources) == "table" then
        for key, ids in pairs(db.questDropSources) do
            local name = cleanName(key)
            if name and type(ids) == "table" then
                for id, value in pairs(ids) do
                    if type(id) == "number" and value == true then
                        list[#list + 1] = { "D", id .. "," .. name }
                    elseif type(id) == "string" and type(value) == "table" and not value.shared then
                        local objectID = tonumber(id:match("^o:(%d+)$"))
                        local text = objectID and spotText(value)
                        if text then list[#list + 1] = { "O", objectID .. "," .. text .. "," .. name } end
                    end
                end
            end
        end
    end
    return list
end

-----------------------------------------------------------------------------
-- Applying a confirmed record
-----------------------------------------------------------------------------
local function store(key)
    if not ns.DB then return nil end
    if type(ns.DB[key]) ~= "table" then ns.DB[key] = {} end
    return ns.DB[key]
end

local changed = false

local function apply(kind, body)
    if kind == "E" then
        local q, k, id, rest = body:match("^(%d+),([no]),(%d+),?(.*)$")
        q, id = intIn(q, 1, 1000000), intIn(id, 1, 10000000)
        if not (q and id) then return end
        local enders = store("questEnders")
        local mine = enders and enders[q]
        if not enders or (type(mine) == "table" and not mine.shared) then return end
        enders[q] = { key = (k == "n" and "npc:" or "object:") .. id, spot = parseSpot(rest), shared = true }
        changed = true
    elseif kind == "V" then
        local q, index, rest = body:match("^(%d+),(%d+),(.+)$")
        q, index = intIn(q, 1, 1000000), intIn(index, 1, 20)
        local spot = parseSpot(rest)
        if not (q and index and spot) then return end
        local spots = store("questEventSpots")
        if not spots then return end
        spots[q] = spots[q] or {}
        if spots[q][index] then return end
        spot.shared = true
        spots[q][index] = spot
        changed = true
    elseif kind == "I" then
        local itemID, k, id, rest = body:match("^(%d+),([no]),(%d+),?(.*)$")
        itemID, id = intIn(itemID, 1, 10000000), intIn(id, 1, 10000000)
        if not (itemID and id) then return end
        local items = store("questDropItems")
        if not items then return end
        items[itemID] = items[itemID] or {}
        if k == "n" then
            if items[itemID][id] then return end
            items[itemID][id] = "s"
        else
            local spot = parseSpot(rest)
            local key = "o:" .. id
            if not spot or type(items[itemID][key]) == "table" then return end
            spot.shared = true
            items[itemID][key] = spot
        end
        changed = true
    elseif kind == "D" then
        local id, name = body:match("^(%d+),(.+)$")
        id, name = intIn(id, 1, 10000000), cleanName(name)
        if not (id and name) then return end
        local drops = store("questDropSources")
        if not drops then return end
        drops[name] = drops[name] or {}
        if drops[name][id] then return end
        drops[name][id] = "s"
        changed = true
    elseif kind == "O" then
        local id, c, x, y, name = body:match("^(%d+),(%d+),(%-?[%d%.]+),(%-?[%d%.]+),(.+)$")
        id, name = intIn(id, 1, 10000000), cleanName(name)
        local spot = parseSpot(c and (c .. "," .. x .. "," .. y))
        if not (id and name and spot) then return end
        local drops = store("questDropSources")
        if not drops then return end
        drops[name] = drops[name] or {}
        local key = "o:" .. id
        if type(drops[name][key]) == "table" then return end
        spot.shared = true
        drops[name][key] = spot
        changed = true
    end
end

-----------------------------------------------------------------------------
-- Receiving
-----------------------------------------------------------------------------
-- a number for the sender, so the same player is counted once
local function senderHash(sender)
    local h = 5381
    for i = 1, #sender do h = (h * 33 + sender:byte(i)) % 2147483647 end
    return h
end

local received = {}   -- sender hash -> { t, n } (this session)

local function allow(hash, n)
    local t = GetTime and GetTime() or 0
    local row = received[hash]
    if not row or t - row.t > 60 then
        row = { t = t, n = 0 }
        received[hash] = row
    end
    row.n = row.n + n
    return row.n <= RECEIVE_PER_MINUTE
end

local inboxCount

local function inbox()
    local box = store("questShareInbox")
    if box and not inboxCount then
        inboxCount = 0
        local oldest = now() - INBOX_DAYS * 86400
        for key, row in pairs(box) do
            if type(row) ~= "table" or (row.t or 0) < oldest then
                box[key] = nil
            else
                inboxCount = inboxCount + 1
            end
        end
    end
    return box
end

local function vote(kind, body, hash, needed)
    local box = inbox()
    if not box then return end
    local key = kind .. ";" .. body
    local row = box[key]
    if not row then
        if inboxCount >= INBOX_MAX then return end
        row = { s = {}, n = 0, t = now() }
        box[key] = row
        inboxCount = inboxCount + 1
    end
    if row.s[hash] then return end
    row.s[hash] = true
    row.n = row.n + 1
    if row.n >= needed then
        apply(kind, body)
        box[key] = nil
        inboxCount = inboxCount - 1
    end
end

local playerFull

local function isMe(sender)
    if not playerFull then
        local name = UnitName and UnitName("player")
        local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
        playerFull = (name or "") .. "-" .. realm
    end
    if sender == playerFull then return true end
    local short = Ambiguate and Ambiguate(sender, "none")
    return short ~= nil and UnitName and short == UnitName("player")
end

local GROUP_CHANNELS = { PARTY = true, RAID = true, GUILD = true, INSTANCE_CHAT = true }

local function onAddonMessage(prefix, text, channel, sender)
    if isSecret(prefix) or isSecret(text) or isSecret(channel) or isSecret(sender) then return end
    if prefix ~= PREFIX or type(text) ~= "string" or type(sender) ~= "string" or not enabled() then return end
    if channel == "WHISPER" or isMe(sender) then return end
    local kind, payload = text:match("^1(%u)|(.+)$")
    if not kind or not payload then return end
    local hash = senderHash(sender)
    local needed = GROUP_CHANNELS[channel] and CONFIRM_GROUP or CONFIRM_PUBLIC
    local loc = locale()
    for body in payload:gmatch("[^;]+") do
        if not allow(hash, 1) then break end
        if kind == "D" or kind == "O" then
            -- item names: only from players with the same client language
            local l, rest = body:match("^(%a%a%u%u),(.+)$")
            if l == loc then vote(kind, rest, hash, needed) end
        else
            vote(kind, body, hash, needed)
        end
    end
    if changed then
        changed = false
        if DataShare.onChanged then DataShare.onChanged() end
    end
end

-----------------------------------------------------------------------------
-- Sending: one message every few seconds, own records only
-----------------------------------------------------------------------------
local sentAt = {}        -- record text -> time sent (this session)
local channelReady = false

local function targets()
    local list = {}
    if IsInGuild and IsInGuild() then list[#list + 1] = { "GUILD" } end
    if IsInRaid and IsInRaid() then
        list[#list + 1] = { "RAID" }
    elseif IsInGroup and IsInGroup(LE_PARTY_CATEGORY_HOME) then
        list[#list + 1] = { "PARTY" }
    end
    if channelReady and ns.DB and ns.DB.questShareChannel ~= false and GetChannelName then
        local ok, id = pcall(GetChannelName, CHANNEL_NAME)
        if ok and type(id) == "number" and id > 0 then list[#list + 1] = { "CHANNEL", id } end
    end
    return list
end

local function nextMessage()
    local t = now()
    local loc = locale()
    local byKind = {}
    for _, rec in ipairs(ownRecords()) do
        local kind, body = rec[1], rec[2]
        if kind == "D" or kind == "O" then body = loc .. "," .. body end
        local key = kind .. ";" .. body
        local last = sentAt[key]
        if not last or t - last > RESEND_AFTER then
            byKind[kind] = byKind[kind] or {}
            local list = byKind[kind]
            list[#list + 1] = { key = key, body = body }
        end
    end
    for _, kind in ipairs({ "E", "V", "I", "O", "D" }) do
        local list = byKind[kind]
        if list then
            local head = "1" .. kind .. "|"
            local parts, size = {}, #head
            for _, rec in ipairs(list) do
                if size + #rec.body + 1 > MAX_MSG then break end
                parts[#parts + 1] = rec.body
                size = size + #rec.body + 1
                sentAt[rec.key] = t
            end
            if #parts > 0 then return head .. concat(parts, ";") end
        end
    end
    return nil
end

local function sendTick()
    if not enabled() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    local list = targets()
    if #list == 0 then return end
    local msg = nextMessage()
    if not msg then return end
    for _, target in ipairs(list) do
        pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, target[1], target[2])
    end
end

-----------------------------------------------------------------------------
-- The hidden channel: joined in the background, kept out of the chat windows
-----------------------------------------------------------------------------
local function isOurChannel(name)
    if type(name) ~= "string" or isSecret(name) then return false end
    -- the data channel and its short-lived placeholders ("EzWoWQPad1", ...)
    return name:lower():find("ezwowq", 1, true) ~= nil
end

local function removeFromChatWindows()
    local remove = (ChatFrameUtil and ChatFrameUtil.RemoveChannel) or _G.ChatFrame_RemoveChannel
    if type(remove) ~= "function" then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then pcall(remove, frame, CHANNEL_NAME) end
    end
end

-- The client gives a new channel the lowest free number (often 2, where
-- players expect Trade: "/2 ..." would go into this hidden channel). The
-- channel has to get a number from 10 up, which the game's own channels never
-- use. Numbers can't be picked, so placeholder channels are joined one at a
-- time (the client skips the numbers it keeps for Trade and the like) until
-- one lands on 9 or higher; the data channel joined after that gets 10 or
-- higher, and the placeholders are left again. The numbers of the player's
-- own channels never change. When that fails, the channel is left and sharing
-- goes through the party, raid and guild only (this session).
local LOW_LIMIT = 10           -- the data channel's number must be at least this
local MAX_SLOT = tonumber(MAX_WOW_CHAT_CHANNELS) or 20
local PAD_PREFIX = "EzWoWQPad"
local MAX_PADS = 12
local channelGaveUp, placing = false, false
local staleWaits = 0

local function channelIndex(name)
    local ok, id = pcall(GetChannelName, name)
    return ok and type(id) == "number" and not isSecret(id) and id > 0 and id or nil
end

local function joinByName(name)
    local join = (type(JoinTemporaryChannel) == "function" and JoinTemporaryChannel)
        or (C_ChatInfo and type(C_ChatInfo.JoinChannelByName) == "function" and C_ChatInfo.JoinChannelByName)
        or (type(JoinChannelByName) == "function" and JoinChannelByName)
    if join then pcall(join, name) end
end

local function leaveByName(name)
    if channelIndex(name) and type(LeaveChannelByName) == "function" then pcall(LeaveChannelByName, name) end
end

local function later(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, function() pcall(fn) end) end
end

-- placeholder channels still joined (also ones left over from an earlier try)
local function joinedPads()
    local list = {}
    for index = 1, MAX_SLOT do
        local ok, id, name = pcall(GetChannelName, index)
        if ok and type(id) == "number" and id == index and type(name) == "string" and not isSecret(name)
            and name:find(PAD_PREFIX, 1, true) == 1 then
            list[#list + 1] = name
        end
    end
    return list
end

-- leaves the placeholders, checking a few times that they are really gone
local function clearPads(tries)
    if placing then return end
    tries = tries or 0
    local pads = joinedPads()
    if #pads == 0 then return end
    if tries >= 4 then return end
    for _, name in ipairs(pads) do leaveByName(name) end
    later(2, function() clearPads(tries + 1) end)
end

-- waits until the named channel has a number: fn(index) or fn(nil) after ~4 s
local function whenJoined(name, fn, tries)
    tries = tries or 0
    local index = channelIndex(name)
    if index or tries >= 8 then fn(index) return end
    later(0.5, function() whenJoined(name, fn, tries + 1) end)
end

local function finishPlacing(ok)
    placing = false
    if ok then
        channelReady = true
        later(1, removeFromChatWindows)
    else
        channelReady = false
        channelGaveUp = true
        leaveByName(CHANNEL_NAME)
    end
    later(1, clearPads)
end

local function relocate()
    placing = true
    channelReady = false
    leaveByName(CHANNEL_NAME)
    local count = 0

    local function joinOurs()
        joinByName(CHANNEL_NAME)
        whenJoined(CHANNEL_NAME, function(index)
            finishPlacing(index ~= nil and index >= LOW_LIMIT)
        end)
    end

    local function addPad()
        if count >= MAX_PADS then joinOurs() return end
        count = count + 1
        local name = PAD_PREFIX .. count
        joinByName(name)
        whenJoined(name, function(index)
            if not index then
                -- no more channels can be joined: the data channel can't get a high number
                finishPlacing(false)
            elseif index >= LOW_LIMIT - 1 then
                joinOurs()
            else
                later(1, addPad)
            end
        end)
    end

    later(1.5, addPad)
end

local function joinChannel()
    if channelGaveUp or placing or not (enabled() and ns.DB.questShareChannel ~= false) then return end
    if InCombatLockdown and InCombatLockdown() then
        later(10, joinChannel)
        return
    end
    -- placeholders left over from an earlier try go first
    if #joinedPads() > 0 and staleWaits < 3 then
        staleWaits = staleWaits + 1
        clearPads()
        later(3, joinChannel)
        return
    end
    local mine = channelIndex(CHANNEL_NAME)
    if mine and mine >= LOW_LIMIT then
        channelReady = true
        later(1, removeFromChatWindows)
        return
    end
    relocate()
end

local function leaveChannel()
    channelReady = false
    leaveByName(CHANNEL_NAME)
end

-- join / leave notices and any text typed into the channel are not shown
local function chatFilter(_, _, _, _, _, channelString, _, _, _, _, channelBaseName)
    if isOurChannel(channelBaseName) or isOurChannel(channelString) then return true end
    return false
end

local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or _G.ChatFrame_AddMessageEventFilter
if type(addFilter) == "function" then
    for _, event in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER",
        "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
        pcall(addFilter, event, chatFilter)
    end
end

-- options window
function DataShare.setEnabled()
    if enabled() and ns.DB.questShareChannel ~= false then
        channelGaveUp = false
        joinChannel()
    else
        leaveChannel()
    end
end

-----------------------------------------------------------------------------
-- Start-up
-----------------------------------------------------------------------------
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "CHAT_MSG_ADDON" }) do
    pcall(events.RegisterEvent, events, event)
end
local started = false
events:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local ok, err = pcall(onAddonMessage, ...)
        if not ok and geterrorhandler then geterrorhandler()(err) end
        return
    end
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        end
    elseif event == "PLAYER_ENTERING_WORLD" and not started then
        started = true
        -- after the game's own channels have their numbers
        if C_Timer and C_Timer.After then C_Timer.After(12, joinChannel) end
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(SEND_EVERY, function() pcall(sendTick) end)
        end
    end
end)

-- map marks pick up confirmed records
DataShare.onChanged = function()
    if ns.QuestObjectivePins and ns.QuestObjectivePins.refreshAll then pcall(ns.QuestObjectivePins.refreshAll) end
    if ns.RefreshQuestLogPins then pcall(ns.RefreshQuestLogPins) end
end
