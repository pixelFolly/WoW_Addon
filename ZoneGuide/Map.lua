-- ZoneGuide map pins: clicking a quest opens the world map on its quest giver and marks the
-- spot until the map is closed. "Map pins" marks every quest giver for the zone you're shown.
local _, ns = ...

local pin, driver, target, hooked

local function canvas()
    if not WorldMapFrame then return nil end
    if WorldMapFrame.GetCanvas then return WorldMapFrame:GetCanvas() end
    return WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function canvasScale()
    local sc = WorldMapFrame.ScrollContainer
    return (sc and sc.GetCanvasScale and sc:GetCanvasScale()) or 1
end

local function clear()
    target = nil
    if pin then pin:Hide() end
    if driver then driver:Hide() end
end

-- Keep the pin on the right spot while the map is open (it can be zoomed or switched).
local function place()
    if not target then return end
    if not WorldMapFrame:IsShown() then clear() return end
    local c = canvas()
    if not c then return end
    if pin:GetParent() ~= c then pin:SetParent(c) end
    if WorldMapFrame:GetMapID() ~= target.map then pin:Hide() return end
    local s = 1 / canvasScale()   -- same size on screen however far you zoom
    pin:SetScale(s)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", c, "TOPLEFT", target.x * c:GetWidth() / s, -target.y * c:GetHeight() / s)
    pin:SetFrameLevel(c:GetFrameLevel() + 2000)
    pin:Show()
end

local function createPin()
    pin = CreateFrame("Frame", nil, UIParent)
    pin:SetSize(24, 24)
    pin.icon = pin:CreateTexture(nil, "OVERLAY")
    pin.icon:SetAllPoints()
    pin.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    pin.ring = pin:CreateTexture(nil, "ARTWORK")
    pin.ring:SetPoint("CENTER")
    pin.ring:SetSize(44, 44)
    pin.ring:SetTexture("Interface\\Minimap\\Ping\\ping5")
    pin.ring:SetBlendMode("ADD")
    pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pin.label:SetPoint("BOTTOM", pin, "TOP", 0, 2)
    pin.sub = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pin.sub:SetPoint("TOP", pin, "BOTTOM", 0, -2)
    pin:Hide()

    driver = CreateFrame("Frame")
    driver:Hide()
    driver:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t > 0.1 then
            self.t = 0
            place()
        end
    end)
end

-- Open the world map on mapID; if x and y (0-100) are given, pin that spot until the map closes.
function ns.ShowOnMap(mapID, x, y, title, sub)
    if not WorldMapFrame or not mapID then
        print("|cffffd100ZoneGuide:|r no map location known for this quest.")
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        print("|cffffd100ZoneGuide:|r can't open the map in combat.")
        return
    end
    if not pin then createPin() end
    if not hooked then
        WorldMapFrame:HookScript("OnHide", clear)
        hooked = true
    end

    if not WorldMapFrame:IsShown() then
        if OpenWorldMap then
            OpenWorldMap(mapID)
        elseif ToggleWorldMap then
            ToggleWorldMap()
        else
            ShowUIPanel(WorldMapFrame)
        end
    end
    WorldMapFrame:SetMapID(mapID)

    if x and y then
        target = { map = mapID, x = x / 100, y = y / 100 }
        pin.label:SetText(title or "")
        pin.sub:SetText(sub or "")
        driver:Show()
        place()
    else
        clear()
    end
end

-- Map pins --------------------------------------------------------------------------------
-- With "Map pins" on, every quest giver for the zone shown in the ZoneGuide window gets a marker on
-- the world map. The window recomputes them whenever your quests change, so a marker goes away
-- once you've accepted its quests (or turn the pins off).

local markers, markerPins, markerDriver, lastKey = {}, {}, nil, nil

local function markerTooltip(self)
    local m = self.marker
    if not m then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(m.giver or "Quest giver", 1, 0.82, 0)
    for _, name in ipairs(m.names) do GameTooltip:AddLine(name, 1, 1, 1) end
    GameTooltip:AddLine("ZoneGuide map pin", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function markerPin(i)
    if markerPins[i] then return markerPins[i] end
    local p = CreateFrame("Frame", nil, UIParent)
    p:SetSize(18, 18)
    p.icon = p:CreateTexture(nil, "OVERLAY")
    p.icon:SetAllPoints()
    p.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    p:EnableMouse(true)
    if p.SetMouseClickEnabled then p:SetMouseClickEnabled(false) end  -- don't get in the way of dragging the map
    p:SetScript("OnEnter", markerTooltip)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p:Hide()
    markerPins[i] = p
    return p
end

-- Put the markers for the map being viewed on the canvas (again, when it's zoomed or switched).
local function placeMarkers(force)
    if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    local c = canvas()
    if not c then return end
    local mapID = WorldMapFrame:GetMapID()
    local w, h, scale = c:GetWidth(), c:GetHeight(), canvasScale()
    local key = string.format("%s:%s:%s:%s", tostring(mapID), w, h, scale)
    if key == lastKey and not force then return end
    lastKey = key
    local s, n = 1 / scale, 0
    for _, m in ipairs(markers) do
        if m.map == mapID then
            n = n + 1
            local p = markerPin(n)
            p.marker = m
            if p:GetParent() ~= c then p:SetParent(c) end
            p:SetScale(s)
            p:ClearAllPoints()
            p:SetPoint("CENTER", c, "TOPLEFT", m.x * w / s, -m.y * h / s)
            p:SetFrameLevel(c:GetFrameLevel() + 1900)
            p:Show()
        end
    end
    for i = n + 1, #markerPins do markerPins[i]:Hide() end
end

local function watchMap()
    if markerDriver or not WorldMapFrame then return end
    markerDriver = CreateFrame("Frame")
    markerDriver:Hide()
    markerDriver:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t > 0.1 then
            self.t = 0
            placeMarkers()
        end
    end)
    WorldMapFrame:HookScript("OnShow", function() lastKey = nil; markerDriver:Show() end)
    WorldMapFrame:HookScript("OnHide", function() markerDriver:Hide() end)
    if WorldMapFrame:IsShown() then markerDriver:Show() end
end

-- list: { { map = uiMapID, x = 0..1, y = 0..1, giver = name, names = { quest, ... } }, ... }.
-- An empty list removes every marker.
function ns.SetMarkers(list)
    markers = list or {}
    watchMap()
    if #markers == 0 then
        for _, p in ipairs(markerPins) do p:Hide() end
    end
    placeMarkers(true)
end

-- Where a quest is picked up: map, x, y (any can be nil).
function ns.QuestLocation(q, fallbackMap)
    local x, y
    if q.at then
        x, y = q.at[1], q.at[2]
        if type(x) == "string" then x, y = q.at[2], q.at[3] end
    end
    return q.m or fallbackMap, x, y
end
