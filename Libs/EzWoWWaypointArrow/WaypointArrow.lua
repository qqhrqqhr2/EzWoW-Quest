--===========================================================================
-- EzWoW shared : Libs/EzWoWWaypointArrow/WaypointArrow.lua
-- On-screen arrow toward the map waypoint. The same file ships in each EzWoW
-- addon that sets waypoints; the newest copy fills the shared table and one
-- window serves them all.
--===========================================================================
-- While the game holds a map waypoint (set by an EzWoW addon or by hand on the
-- map), a small window shows what is tracked, an arrow turned toward it and
-- the distance in yards. The X clears the waypoint. Nothing is shown inside
-- instances (the game gives no position there).
--
-- Addons name the waypoint they set right after setting it:
--   EzWoW_WaypointArrow.SetLabel("Hogger", "EzWoW - Map Finder")
local ADDON_NAME, ns = ...
local type, pcall, tostring, tonumber, ipairs = type, pcall, tostring, tonumber, ipairs
local atan2, sqrt, floor, abs = math.atan2 or math.atan, math.sqrt, math.floor, math.abs

local LIB_VERSION = 3

local lib = _G.EzWoW_WaypointArrow
if type(lib) ~= "table" then
    lib = {}
    _G.EzWoW_WaypointArrow = lib
end
ns.WaypointArrow = lib
if (tonumber(lib.version) or 0) >= LIB_VERSION then return end
lib.version = LIB_VERSION

-- the arrow pictures ship next to this file; the game's minimap arrow if one is missing
local LIB_DIR = "Interface\\AddOns\\" .. tostring(ADDON_NAME) .. "\\Libs\\EzWoWWaypointArrow\\"
local ARROW_FALLBACK = "Interface\\Minimap\\MinimapArrow"
local ARRIVE_YARDS = 10
local TICK = 0.1
-- other EzWoW arrows that point at the same place: this one stays hidden then
local OTHER_ARROWS = { "EzWoW_DungeonRouteGuideArrow" }

local TEXT = {
    enUS = { yards = "%d yd", arrived = "Arrived", noPos = "Position unknown here", other = "On another continent: %s", stop = "Clear the waypoint" },
    koKR = { yards = "%d야드", arrived = "도착", noPos = "여기서는 위치를 알 수 없음", other = "다른 대륙: %s", stop = "추적 핀 지우기" },
    deDE = { yards = "%d m", arrived = "Angekommen", noPos = "Position hier unbekannt", other = "Anderer Kontinent: %s", stop = "Wegpunkt löschen" },
    frFR = { yards = "%d m", arrived = "Arrivé", noPos = "Position inconnue ici", other = "Autre continent : %s", stop = "Effacer le point de passage" },
    esES = { yards = "%d m", arrived = "Has llegado", noPos = "Posición desconocida aquí", other = "Otro continente: %s", stop = "Borrar el punto de ruta" },
    ruRU = { yards = "%d м", arrived = "На месте", noPos = "Позиция здесь неизвестна", other = "Другой континент: %s", stop = "Убрать путевую точку" },
    zhCN = { yards = "%d码", arrived = "已到达", noPos = "此处无法获取位置", other = "其他大陆：%s", stop = "清除路径点" },
    zhTW = { yards = "%d碼", arrived = "已抵達", noPos = "此處無法取得位置", other = "其他大陸：%s", stop = "清除路徑點" },
}
-- arrow looks (right-click the window): hint, menu title, then one name per look
local STYLE_TEXT = {
    enUS = { "Right-click: change the arrow look", "Arrow look", "Gold arrow", "Sticker", "Buddy", "Candy", "Car", "Airplane", "Dragonfly" },
    koKR = { "오른쪽 클릭: 화살표 모양 바꾸기", "화살표 모양", "금색 화살표", "노란 스티커", "파란 친구", "사탕", "자동차", "비행기", "잠자리" },
    deDE = { "Rechtsklick: Pfeilform ändern", "Pfeilform", "Goldpfeil", "Sticker", "Kumpel", "Zuckerstange", "Auto", "Flugzeug", "Libelle" },
    frFR = { "Clic droit : changer la flèche", "Style de flèche", "Flèche dorée", "Autocollant", "Copain", "Sucre d'orge", "Voiture", "Avion", "Libellule" },
    esES = { "Clic derecho: cambiar la flecha", "Estilo de flecha", "Flecha dorada", "Pegatina", "Amiguito", "Caramelo", "Coche", "Avión", "Libélula" },
    ruRU = { "ПКМ: сменить стрелку", "Вид стрелки", "Золотая стрелка", "Наклейка", "Дружок", "Леденец", "Машина", "Самолёт", "Стрекоза" },
    zhCN = { "右键：更换箭头样式", "箭头样式", "金色箭头", "贴纸", "小伙伴", "糖果", "汽车", "飞机", "蜻蜓" },
    zhTW = { "右鍵：更換箭頭樣式", "箭頭樣式", "金色箭頭", "貼紙", "小夥伴", "糖果", "汽車", "飛機", "蜻蜓" },
}
local STYLES = { "classic", "sticker", "buddy", "candy", "car", "plane", "dragonfly" }
local STYLE_FILE = {
    classic = "arrow", sticker = "arrow_sticker", buddy = "arrow_buddy", candy = "arrow_candy",
    car = "arrow_car", plane = "arrow_plane", dragonfly = "arrow_dragonfly",
}
for locale, list in pairs(STYLE_TEXT) do
    local t = TEXT[locale]
    t.styleHint, t.styleTitle = list[1], list[2]
    for i, key in ipairs(STYLES) do t["style_" .. key] = list[i + 2] end
end
TEXT.esMX = TEXT.esES
TEXT.enGB = TEXT.enUS

local function text(key)
    local locale = GetLocale and GetLocale() or "enUS"
    local t = TEXT[locale] or TEXT.enUS
    return t[key] or TEXT.enUS[key]
end

local function isSecret(v) return issecretvalue and issecretvalue(v) or false end

local function num(v)
    if type(v) ~= "number" or isSecret(v) then return nil end
    return v
end

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

-- a position may come as a vector (GetXY) or as a plain { x, y } table
local function xy(v)
    if type(v) ~= "table" then return nil end
    local x, y
    if type(v.GetXY) == "function" then
        local ok, a, b = pcall(v.GetXY, v)
        if ok then x, y = a, b end
    end
    if x == nil or y == nil then x, y = v.x, v.y end
    x, y = num(x), num(y)
    if not x or not y then return nil end
    return x, y
end

local function inInstance()
    if type(IsInInstance) ~= "function" then return false end
    local ok, inside, kind = pcall(IsInInstance)
    if not ok or isSecret(inside) then return false end
    return inside == true and kind ~= "none"
end

local function otherArrowShown()
    for _, name in ipairs(OTHER_ARROWS) do
        local f = _G[name]
        if type(f) == "table" and f.IsShown and f:IsShown() then return true end
    end
    return false
end

-- mapID, x, y (0-1) of the current waypoint, or nil
local function currentWaypoint()
    if not (C_Map and C_Map.HasUserWaypoint and C_Map.GetUserWaypoint) then return nil end
    local okHas, has = call(C_Map.HasUserWaypoint)
    if not okHas or has ~= true then return nil end
    local ok, point = call(C_Map.GetUserWaypoint)
    if not ok or type(point) ~= "table" then return nil end
    local mapID = num(point.uiMapID)
    local x, y = xy(point.position)
    if not (mapID and x and y) then return nil end
    return mapID, x, y
end

local function playerPosition()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local okMap, mapID = call(C_Map.GetBestMapForUnit, "player")
    mapID = okMap and num(mapID)
    if not mapID then return nil end
    local okPos, pos = call(C_Map.GetPlayerMapPosition, mapID, "player")
    if not okPos then return nil end
    local x, y = xy(pos)
    if not x or not y or (x == 0 and y == 0) then return nil end
    return mapID, x, y
end

-- continent and world position of a map point
local function worldPos(mapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, cont, pos = call(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if not ok or not pos then return nil end
    return num(cont), pos
end

-- the waypoint on the player's map: x, y, or nil when it is on another continent
local function targetOnMap(playerMap, tMap, tx, ty)
    if tMap == playerMap then return tx, ty end
    local tCont, tWorld = worldPos(tMap, tx, ty)
    local pCont = worldPos(playerMap, 0.5, 0.5)
    if not tWorld or not tCont or (pCont and pCont ~= tCont) then return nil end
    if not C_Map.GetMapPosFromWorldPos then return nil end
    local ok, _, mapPos = call(C_Map.GetMapPosFromWorldPos, tCont, tWorld, playerMap)
    if not ok then return nil end
    return xy(mapPos)
end

local function mapName(mapID)
    local ok, info = call(C_Map and C_Map.GetMapInfo, mapID)
    local name = ok and type(info) == "table" and info.name
    if type(name) == "string" and not isSecret(name) and name ~= "" then return name end
    return tostring(mapID)
end

-- the window position and look are kept in the saved data all EzWoW addons share
local function savedPosition()
    local share = _G.EzWoW_Share
    if type(share) ~= "table" or type(share.Data) ~= "function" then return nil end
    local ok, data = pcall(share.Data)
    if not ok or type(data) ~= "table" or type(data.settings) ~= "table" then return nil end
    return data.settings
end

local localStyle          -- the look while the shared saved data is not there

function lib.GetStyle()
    local settings = savedPosition()
    local key = (settings and settings.arrowStyle) or localStyle
    if type(key) == "string" and STYLE_FILE[key] then return key end
    return "classic"
end

local function applyStyle()
    local f = lib.frame
    if not f then return end
    if f.arrow:SetTexture(LIB_DIR .. STYLE_FILE[lib.GetStyle()]) == false then f.arrow:SetTexture(ARROW_FALLBACK) end
end

function lib.SetStyle(key)
    if not STYLE_FILE[key] then return end
    localStyle = key
    local settings = savedPosition()
    if settings then settings.arrowStyle = key end
    applyStyle()
    if lib.menu and lib.menu:IsShown() then lib.menu:Hide() end
end

-- a small list of the looks, opened by right-clicking the window
local function buildMenu()
    if lib.menu then return lib.menu end
    local m = CreateFrame("Frame", "EzWoW_WaypointArrowMenu", UIParent, "BackdropTemplate")
    lib.menu = m
    m:Hide()
    m:SetFrameStrata("DIALOG")
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    if m.SetBackdrop then
        m:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        m:SetBackdropColor(0.071, 0.094, 0.122, 0.95)
        m:SetBackdropBorderColor(0.294, 0.784, 0.910, 0.85)
    end
    local ROW = 28
    m:SetSize(170, 26 + #STYLES * ROW + 6)
    m.title = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.title:SetPoint("TOP", 0, -6)
    m.rows = {}
    for i, key in ipairs(STYLES) do
        local row = CreateFrame("Button", nil, m)
        row:SetSize(162, ROW)
        row:SetPoint("TOPLEFT", 4, -22 - (i - 1) * ROW)
        row.key = key
        row.hl = row:CreateTexture(nil, "BACKGROUND")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(0.294, 0.784, 0.910, 0.25)
        row.hl:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 6, 0)
        if row.icon:SetTexture(LIB_DIR .. STYLE_FILE[key]) == false then row.icon:SetTexture(ARROW_FALLBACK) end
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.label:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row:SetScript("OnEnter", function(self) self.hl:Show() end)
        row:SetScript("OnLeave", function(self) if lib.GetStyle() ~= self.key then self.hl:Hide() end end)
        row:SetScript("OnClick", function(self) lib.SetStyle(self.key) end)
        m.rows[i] = row
    end
    m:SetScript("OnShow", function(self)
        self.title:SetText(text("styleTitle"))
        local current = lib.GetStyle()
        for _, row in ipairs(self.rows) do
            row.label:SetText(text("style_" .. row.key))
            if row.key == current then
                row.hl:Show()
                row.label:SetTextColor(1.0, 0.82, 0.0)
            else
                row.hl:Hide()
                row.label:SetTextColor(1, 1, 1)
            end
        end
    end)
    -- a click anywhere else closes it
    m:SetScript("OnEvent", function(self)
        if self:IsShown() and not self:IsMouseOver() then self:Hide() end
    end)
    pcall(m.RegisterEvent, m, "GLOBAL_MOUSE_DOWN")
    return m
end

function lib.ToggleMenu()
    local m = buildMenu()
    if m:IsShown() then m:Hide() return end
    m:ClearAllPoints()
    if lib.frame then
        m:SetPoint("TOP", lib.frame, "BOTTOM", 0, -4)
    else
        m:SetPoint("CENTER")
    end
    m:Show()
end

-- name and source of the waypoint an EzWoW addon set last
local label

-- called right after an addon sets a waypoint: the name is tied to the
-- waypoint the game now holds (a later one set by hand shows the zone name)
function lib.SetLabel(name, source)
    local mapID, x, y = currentWaypoint()
    if type(name) ~= "string" or isSecret(name) or name == "" or not mapID then
        label = nil
    else
        label = { text = name, source = type(source) == "string" and source or nil, mapID = mapID, x = x, y = y }
    end
    if lib.Refresh then pcall(lib.Refresh) end
end

local function labelFor(mapID, x, y)
    if label and label.mapID == mapID and abs(label.x - x) < 0.0005 and abs(label.y - y) < 0.0005 then
        return label.text, label.source
    end
    return mapName(mapID), nil
end

function lib.Update()
    local f = lib.frame
    if not f then return end
    local tMap, tx, ty = currentWaypoint()
    if not tMap then lib.Refresh() return end
    local title, source = labelFor(tMap, tx, ty)
    if f.title:GetText() ~= title then
        f.title:SetText(title)
        -- the window grows with the name so dragging covers all of it
        local okH, h = pcall(f.title.GetStringHeight, f.title)
        h = okH and num(h) or 14
        f:SetHeight(h + 90)
    end
    f.tag:SetText(source or "EzWoW")
    local pMap, px, py = playerPosition()
    if not pMap then
        f.arrow:Hide()
        f.text:SetText(text("noPos"))
        return
    end
    local mx, my = targetOnMap(pMap, tMap, tx, ty)
    if not mx or not my then
        f.arrow:Hide()
        f.text:SetText(string.format(text("other"), mapName(tMap)))
        return
    end
    local okSize, width, height = call(C_Map.GetMapWorldSize, pMap)
    width, height = okSize and num(width), okSize and num(height)
    if not width or not height or width <= 0 or height <= 0 then
        f.arrow:Hide()
        f.text:SetText(text("noPos"))
        return
    end
    local east, south = (mx - px) * width, (my - py) * height
    local dist = sqrt(east * east + south * south)
    if dist < ARRIVE_YARDS then
        f.arrow:Hide()
        f.text:SetText("|cff55ff55" .. text("arrived") .. "|r")
        return
    end
    local okFacing, facing = call(GetPlayerFacing)
    facing = okFacing and num(facing)
    if facing then
        f.arrow:SetRotation(atan2(-east, -south) - facing)
        f.arrow:Show()
    else
        f.arrow:Hide()
    end
    f.text:SetText(string.format(text("yards"), floor(dist + 0.5)))
end

function lib.Create()
    if lib.frame then return lib.frame end
    local f = CreateFrame("Frame", "EzWoW_WaypointArrowFrame", UIParent)
    lib.frame = f
    f:Hide()
    f:SetSize(180, 104)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        local settings = savedPosition()
        if settings then settings.arrowPos = { point, relativePoint, x, y } end
    end)
    local settings = savedPosition()
    local saved = settings and settings.arrowPos
    if type(saved) == "table" and type(saved[1]) == "string" and type(saved[2]) == "string"
        and num(saved[3]) and num(saved[4]) then
        f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        f:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end

    -- no box around it: outlined text stays readable over the world
    local function outline(fs, size)
        local path, height = fs:GetFont()
        if path then fs:SetFont(path, size or height, "OUTLINE") end
    end

    -- what is being tracked; long names wrap onto more lines
    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -2)
    f.title:SetWidth(176)
    if f.title.SetWordWrap then f.title:SetWordWrap(true) end
    if f.title.SetMaxLines then f.title:SetMaxLines(3) end
    outline(f.title)
    f.title:SetTextColor(1.0, 0.82, 0.0)

    f.arrow = f:CreateTexture(nil, "ARTWORK")
    f.arrow:SetSize(48, 48)
    applyStyle()
    f.arrow:SetPoint("TOP", f.title, "BOTTOM", 0, -2)

    f.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.text:SetPoint("TOP", f.arrow, "BOTTOM", 0, -1)
    f.text:SetWidth(176)
    outline(f.text)

    -- which addon set the waypoint
    f.tag = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.tag:SetPoint("TOP", f.text, "BOTTOM", 0, -2)
    outline(f.tag, 9)
    f.tag:SetTextColor(0.6, 0.6, 0.6)
    f.tag:SetText("EzWoW")

    local stop = CreateFrame("Button", nil, f)
    stop:SetSize(16, 16)
    stop:SetPoint("LEFT", f.arrow, "RIGHT", 22, 0)
    local stopLabel = stop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    stopLabel:SetPoint("CENTER")
    outline(stopLabel)
    stopLabel:SetText("X")
    stopLabel:SetTextColor(0.6, 0.6, 0.6)
    stop:SetScript("OnEnter", function(self)
        stopLabel:SetTextColor(1.0, 0.35, 0.35)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text("stop"), 1, 1, 1)
        GameTooltip:Show()
    end)
    stop:SetScript("OnLeave", function()
        stopLabel:SetTextColor(0.6, 0.6, 0.6)
        GameTooltip:Hide()
    end)
    stop:SetScript("OnClick", function()
        label = nil
        if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
        lib.Refresh()
    end)

    -- right-click: the list of arrow looks
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then lib.ToggleMenu() end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(text("styleHint"), 1, 1, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local elapsedAcc = 0
    f:SetScript("OnShow", function() elapsedAcc = TICK end)
    f:SetScript("OnHide", function() if lib.menu then lib.menu:Hide() end end)
    f:SetScript("OnUpdate", function(_, elapsed)
        elapsedAcc = elapsedAcc + (elapsed or 0)
        if elapsedAcc < TICK then return end
        elapsedAcc = 0
        pcall(lib.Update)
    end)
    return f
end

-- show the window while there is a waypoint to point at
function lib.Refresh()
    local want = not inInstance() and not otherArrowShown() and currentWaypoint() ~= nil
    if want then
        lib.Create()
        if not lib.frame:IsShown() then lib.frame:Show() end
    elseif lib.frame and lib.frame:IsShown() then
        lib.frame:Hide()
    end
end

-- events and the ticker are set up once; they call the newest functions
if not lib.events then
    local events = CreateFrame("Frame")
    lib.events = events
    events:SetScript("OnEvent", function() pcall(lib.Refresh) end)
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "USER_WAYPOINT_UPDATED", "SUPER_TRACKING_CHANGED" }) do
        pcall(events.RegisterEvent, events, event)
    end
    -- a waypoint set or cleared without an event still shows up within a second
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(1, function() pcall(lib.Refresh) end)
    end
end
