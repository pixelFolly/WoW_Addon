-- ZoneGuide window: a verdict ("stay" / "time to move"), the best zones with how much
-- quest XP each still holds for you, and a scrolling list of quests for the chosen zone.
-- Locked chain quests expand to show where the chain starts, and the ones worth unlocking
-- get a star. The window can be resized.
local _, ns = ...

local STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"
local LINE_H, MAX_ZONES = 14, 5
local MIN_W, MIN_H, MAX_W, MAX_H = 260, 200, 800, 1000
local frame, verdictText, subText, sortButton, pinsButton, grip, zoneRows, rows, footer
local scroll = 0          -- first visible list entry
local expanded = {}       -- quest id -> true when its chain is shown
local display = {}        -- flattened list of what the quest list shows

-- Layout helpers --------------------------------------------------------------------------

local function savePosition()
    local point, _, rel, x, y = frame:GetPoint()
    ZoneGuideDB.point = { point, rel, x, y }
    ZoneGuideDB.size = { frame:GetWidth(), frame:GetHeight() }
end

function ns.ResetPosition()
    frame:ClearAllPoints()
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 80)
    frame:SetSize(340, 400)
    savePosition()
end

function ns.Toggle()
    ZoneGuideDB.shown = not frame:IsShown()
    frame:SetShown(ZoneGuideDB.shown)
    if ZoneGuideDB.shown then ns.Refresh() end
end

local function sortMode()
    return ZoneGuideDB.sort == "xp" and "xp" or "level"
end

-- Text for one quest -------------------------------------------------------------------------

local function location(q)
    if not q.at then return q.where or "" end
    local x, y = q.at[1], q.at[2]
    if type(x) == "string" then x, y = q.at[2], q.at[3] end -- starting-route format {zone, x, y}
    return string.format("%s%.0f,%.0f", q.where and (q.where .. " ") or "", x, y)
end

-- Available, but so far below your level that it gives 60% XP or less.
local function lowXP(item)
    local q = item.q or item
    return not item.inLog and not item.blocker and q.lvl and ns.player.level - q.lvl >= ns.LOW_XP_DIFF
end

local function questText(item, noTag)
    local q = item.q or item
    local lvl = (q.lvl and q.lvl > 0) and string.format("|cffffd100[%d]|r ", q.lvl) or ""
    local color, suffix = "ffffff", ""
    if item.inLog or ns.IsOnQuest(q.id) then
        color, suffix = "40ff40", " (in log)"
    elseif item.blocker then
        color, suffix = "808080", " (" .. item.blocker .. ")"
    elseif lowXP(item) then
        color, suffix = "c0c0c0", " (low XP)"
    end
    local tag = ""
    if noTag then tag = ""
    elseif q.dungeon then tag = "|cffff8040" .. q.dungeon .. ":|r "
    elseif q.tag == "elite" then tag = "|cffff8040Elite:|r " end
    local marker = ""
    if item.chain then marker = expanded[q.id] and "|cff9999ff[-]|r " or "|cff9999ff[+]|r " end
    if item.star then marker = marker .. STAR .. " " end
    local xp = q.xp and string.format("  |cff9999ff%dxp|r", (item.worth and item.worth > 0) and item.worth or q.xp) or ""
    return string.format("%s%s%s|cff%s%s%s|r%s  |cff999999%s|r", marker, lvl, tag, color, q.name, suffix, xp, location(q))
end

local function stepText(n, step)
    local q = step.q
    local label = n == 1 and "|cffffd100Start:|r " or string.format("%d. ", n)
    local giver = (q.giver and q.giver ~= "") and (q.giver .. ", ") or ""
    local color = step.inLog and "40ff40" or "c0c0ff"
    local where = location(q)
    if not q.where and step.zone then where = step.zone .. " " .. where end
    return string.format("      %s|cff%s[%d] %s|r  |cff999999%s%s|r", label, color, q.lvl or 0, q.name, giver, where)
end

-- Building the list ----------------------------------------------------------------------

-- Quests in your log first, then ones you can pick up now (low-XP ones last), then locked
-- ones worth unlocking, then the other locked ones.
local function group(item)
    if item.inLog then return 1 end
    if not item.blocker then return lowXP(item) and 3 or 2 end
    return item.star and 4 or 5
end

local function sorted(list)
    local out = {}
    for i, item in ipairs(list) do out[i] = item end
    local byXP = sortMode() == "xp"
    table.sort(out, function(a, b)
        local ga, gb = group(a), group(b)
        if ga ~= gb then return ga < gb end
        local qa, qb = a.q, b.q
        if byXP then
            local xa = (a.worth or 0) > 0 and a.worth or qa.xp or 0
            local xb = (b.worth or 0) > 0 and b.worth or qb.xp or 0
            if xa ~= xb then return xa > xb end
        else
            if qa.lvl ~= qb.lvl then return qa.lvl < qb.lvl end
        end
        return qa.id < qb.id
    end)
    return out
end

local function addQuest(item, zoneMap, noTag)
    local q = item.q or item
    item.map = q.m or zoneMap
    -- Locked behind earlier quests: offer to expand the chain.
    if item.blocker == "needs an earlier quest" then
        local steps = item.steps or ns.ChainSteps(q)
        if #steps > 0 then item.chain = steps end
    end
    display[#display + 1] = { kind = "quest", item = item, noTag = noTag }
    if item.chain and expanded[q.id] then
        for n, step in ipairs(item.chain) do
            display[#display + 1] = { kind = "step", n = n, step = step }
        end
    end
end

-- A collapsible section; the header says how many quests in it are worth unlocking.
-- Locked quests that are steps towards a later locked quest show up in that quest's chain instead.
local function shown(list)
    local out = {}
    for _, item in ipairs(list) do
        if not item.mid then out[#out + 1] = item end
    end
    return out
end

local function addSection(items, toggle, title, zoneMap)
    items = shown(items)
    if #items == 0 then return end
    local stars = 0
    for _, item in ipairs(items) do if item.star then stars = stars + 1 end end
    local open = ZoneGuideDB[toggle]
    display[#display + 1] = {
        kind = "header", toggle = toggle,
        text = string.format("%s |cffff8040%s (%d)|r%s", open and "[-]" or "[+]", title, #items,
            stars > 0 and string.format("  %s%d", STAR, stars) or ""),
    }
    if not open then return end
    if toggle ~= "showGroup" then
        for _, item in ipairs(sorted(items)) do addQuest(item) end
        return
    end
    -- Elite quests of this zone first, then each dungeon under its own name, lowest level first,
    -- so you can collect everything for a dungeon before you go in.
    local byDungeon, order, low = {}, {}, {}
    for _, item in ipairs(items) do
        local q = item.q or item
        local d = q.dungeon or ""
        if not byDungeon[d] then byDungeon[d], order[#order + 1] = {}, d end
        table.insert(byDungeon[d], item)
        low[d] = math.min(low[d] or 999, q.lvl or 0)
    end
    table.sort(order, function(a, b)
        if (a == "") ~= (b == "") then return a == "" end
        if (a == "Dungeon") ~= (b == "Dungeon") then return b == "Dungeon" end
        if low[a] ~= low[b] then return low[a] < low[b] end
        return a < b
    end)
    for _, d in ipairs(order) do
        if d ~= "" then
            local name = d == "Dungeon" and "Other dungeon quests" or d
            display[#display + 1] = { kind = "label", text = string.format("  |cffff8040%s|r", name) }
        end
        for _, item in ipairs(sorted(byDungeon[d])) do
            -- Elite quests belong to this zone; dungeon quests carry their own map.
            addQuest(item, d == "" and zoneMap or nil, d ~= "" and d ~= "Dungeon")
        end
    end
end

local function buildDisplay(plan, selected, route)
    for i = #display, 1, -1 do display[i] = nil end
    if route then
        for _, q in ipairs(selected.quests) do addQuest({ q = q, inLog = ns.IsOnQuest(q.id) }) end
        return
    end
    for _, item in ipairs(sorted(shown(selected.quests))) do addQuest(item, selected.map) end

    local group = {}
    for _, item in ipairs(selected.group or {}) do group[#group + 1] = item end
    for _, item in ipairs(plan.dungeons or {}) do group[#group + 1] = item end
    addSection(group, "showGroup", "Elite and dungeon quests for your level", selected.map)
    addSection(plan.classes or {}, "showClass", "Class quests for your level")
end

-- Rows -------------------------------------------------------------------------------------------

local function showTooltip(row)
    local entry = row.entry
    if not entry or entry.kind == "header" or entry.kind == "label" then return end
    local q = entry.kind == "step" and entry.step.q or (entry.item.q or entry.item)
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:AddLine(q.name, 1, 0.82, 0)
    GameTooltip:AddLine(string.format("Level %d (can start at %d)", q.lvl or 0, q.req or 0), 1, 1, 1)
    if q.xp then GameTooltip:AddLine(q.xp .. " XP", 0.6, 0.6, 1) end
    if q.giver and q.giver ~= "" then GameTooltip:AddLine("From: " .. q.giver, 1, 1, 1) end
    local loc = location(q)
    if loc ~= "" then GameTooltip:AddLine("Where: " .. loc, 1, 1, 1) end
    local item = entry.kind == "quest" and entry.item
    if item and item.blocker then GameTooltip:AddLine("Locked: " .. item.blocker, 0.6, 0.6, 0.6) end
    if item and item.chainXP then
        local pct = math.floor(100 * item.chainXP / ns.player.xpMax + 0.5)
        local text
        if (item.chainLen or 0) > 0 then
            text = string.format("With the %d quest%s before it: about %d XP (%d%% of a level).",
                item.chainLen, item.chainLen == 1 and "" or "s", item.chainXP, pct)
        else
            text = string.format("About %d XP (%d%% of a level).", item.chainXP, pct)
        end
        GameTooltip:AddLine(text, 1, 1, 1, true)
        if item.star then
            local why = item.blocker == "starts from a drop" and "Keep the item if it drops: this one is worth doing."
                or item.blocker and item.blocker:find("^level ") and "Worth coming back for when you reach that level."
                or "Worth unlocking: start the chain."
            GameTooltip:AddLine(STAR .. " " .. why, 1, 0.82, 0, true)
        end
        if item.away then GameTooltip:AddLine("The chain starts outside this zone.", 0.6, 0.6, 0.6) end
    end
    if lowXP(item or {}) then GameTooltip:AddLine("You've out-levelled it: reduced XP.", 0.6, 0.6, 0.6) end
    GameTooltip:AddLine("Click to show the quest giver on your map.", 0.6, 0.6, 1)
    if item and item.chain then
        GameTooltip:AddLine("Click [+] (or right-click) to see the quests that unlock it.", 0.6, 0.6, 1)
    end
    GameTooltip:Show()
end

local function getRow(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(LINE_H)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetAllPoints()
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnEnter", showTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local function toggleChain(e)
        local id = (e.item.q or e.item).id
        expanded[id] = not expanded[id]
        ns.Refresh()
    end
    row:SetScript("OnClick", function(self, button)
        local e = self.entry
        if not e or e.kind == "label" then return end
        if e.kind == "header" then
            ZoneGuideDB[e.toggle] = not ZoneGuideDB[e.toggle]
            ns.Refresh()
        elseif e.kind == "quest" and e.item.chain and button == "RightButton" then
            toggleChain(e)
        elseif e.kind == "quest" or e.kind == "step" then
            local q = e.kind == "step" and e.step.q or (e.item.q or e.item)
            local map, x, y = ns.QuestLocation(q, e.kind == "step" and e.step.map or e.item.map)
            ns.ShowOnMap(map, x, y, q.name, q.giver ~= "(item)" and q.giver or nil)
        end
    end)
    -- The [+] / [-] at the start of a chain quest expands it instead of opening the map.
    row.expand = CreateFrame("Button", nil, row)
    row.expand:SetPoint("TOPLEFT")
    row.expand:SetPoint("BOTTOMLEFT")
    row.expand:SetWidth(20)
    row.expand:SetScript("OnClick", function() if row.entry then toggleChain(row.entry) end end)
    row.expand:SetScript("OnEnter", function() showTooltip(row) end)
    row.expand:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = row
    return row
end

local function newZoneRow()
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(LINE_H + 2)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT")
    row.name:SetJustifyH("LEFT")
    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.value:SetPoint("RIGHT")
    row.value:SetJustifyH("RIGHT")
    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetSize(80, 8)
    row.bar:SetPoint("RIGHT", -44, 0)
    row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.bar:SetMinMaxValues(0, ns.BAR_FULL)
    row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.bar.bg:SetAllPoints()
    row.bar.bg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
    row:SetScript("OnClick", function(self)
        ns.picked = self.zone
        scroll = 0
        ns.Refresh()
    end)
    return row
end

-- Window -------------------------------------------------------------------------------------------

function ns.CreateUI()
    frame = CreateFrame("Frame", "ZoneGuideFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetFrameStrata("MEDIUM")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    elseif frame.SetMinResize then
        frame:SetMinResize(MIN_W, MIN_H)
        frame:SetMaxResize(MAX_W, MAX_H)
    end
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() savePosition() end)
    frame:SetScript("OnMouseWheel", function(_, delta)
        scroll = scroll - delta * 3
        ns.Refresh()
    end)
    frame:SetScript("OnSizeChanged", function() if frame.sizing then ns.Refresh() end end)

    local p, size = ZoneGuideDB.point, ZoneGuideDB.size
    frame:SetSize(size and size[1] or 340, size and size[2] or 400)
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        ns.ResetPosition()
    end

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScale(0.8)
    close:SetScript("OnClick", function() ns.Toggle() end)

    sortButton = CreateFrame("Button", nil, frame)
    sortButton:SetSize(70, 16)
    sortButton:SetPoint("TOPRIGHT", -26, -8)
    sortButton.text = sortButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sortButton.text:SetAllPoints()
    sortButton.text:SetJustifyH("RIGHT")
    sortButton:SetScript("OnClick", function()
        ZoneGuideDB.sort = sortMode() == "xp" and "level" or "xp"
        ns.Refresh()
    end)
    sortButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Click to sort quests by " .. (sortMode() == "xp" and "level" or "XP"))
        GameTooltip:Show()
    end)
    sortButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    verdictText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    verdictText:SetPoint("TOPLEFT", 10, -10)
    verdictText:SetPoint("RIGHT", sortButton, "LEFT", -4, 0)
    verdictText:SetJustifyH("LEFT")
    verdictText:SetWordWrap(false)

    subText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subText:SetPoint("TOPLEFT", verdictText, "BOTTOMLEFT", 0, -3)
    subText:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    subText:SetJustifyH("LEFT")

    zoneRows = {}
    for i = 1, MAX_ZONES do zoneRows[i] = newZoneRow() end
    rows = {}

    pinsButton = CreateFrame("Button", nil, frame)
    pinsButton:SetSize(78, 14)
    pinsButton:SetPoint("BOTTOMLEFT", 8, 6)
    pinsButton.text = pinsButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pinsButton.text:SetAllPoints()
    pinsButton.text:SetJustifyH("LEFT")
    pinsButton:SetScript("OnClick", function()
        ZoneGuideDB.markAll = not ZoneGuideDB.markAll
        ns.Refresh()
    end)
    pinsButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Map pins: " .. (ZoneGuideDB.markAll and "on" or "off"))
        GameTooltip:AddLine("Marks every quest giver for the zone shown here on your world map, with the quests "
            .. "they give. A pin goes away once you've accepted its quests. Click to turn "
            .. (ZoneGuideDB.markAll and "off." or "on."), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pinsButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", pinsButton, "BOTTOMRIGHT", 4, 2)
    footer:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
    footer:SetJustifyH("LEFT")
    footer:SetWordWrap(false)

    grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        frame.sizing = true
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        frame.sizing = false
        savePosition()
        ns.Refresh()
    end)

    frame:SetShown(ZoneGuideDB.shown ~= false)
end

local VERDICT = {
    start = "|cff40ff40Starting zone:|r %s",
    stay = "|cff40ff40Stay in|r %s",
    move = "|cffff8040Time to move:|r go to %s",
    go = "|cffffd100Go to|r %s",
    grind = "|cffffd100Level up in|r %s",
}

local function levels(v)
    return string.format("%.1f lv", v)
end

-- The zones listed in the window (the best few, plus where you are) and the one whose quests are
-- shown: the recommended zone, unless you clicked another.
local function zonesFor(plan, route)
    local target = (plan.verdict == "stay" or route) and plan.here or plan.best
    local zones = {}
    for i = 1, math.min(#plan.ranked, MAX_ZONES) do zones[#zones + 1] = plan.ranked[i] end
    if plan.here and not route then
        local found = false
        for _, e in ipairs(zones) do if e == plan.here then found = true end end
        if not found then
            if #zones == MAX_ZONES then zones[MAX_ZONES] = plan.here else zones[#zones + 1] = plan.here end
        end
    end
    local selected = target
    for _, e in ipairs(zones) do if e.name == ns.picked then selected = e end end
    return zones, selected, target
end

-- Map pins: a marker on each quest giver with something you can pick up now in the zone shown.
local function updateMarkers(plan, selected, route)
    if not ns.SetMarkers then return end
    if not (ZoneGuideDB and ZoneGuideDB.markAll and plan and selected) then
        ns.SetMarkers({})
        return
    end
    local byKey, list = {}, {}
    local function add(q, zoneMap)
        local map, x, y = ns.QuestLocation(q, zoneMap)
        if not (map and x and y) then return end
        local key = string.format("%d:%.0f:%.0f", map, x, y)
        local m = byKey[key]
        if not m then
            m = { map = map, x = x / 100, y = y / 100, names = {},
                  giver = (q.giver and q.giver ~= "" and q.giver ~= "(item)") and q.giver or nil }
            byKey[key], list[#list + 1] = m, m
        end
        m.names[#m.names + 1] = string.format("[%d] %s", q.lvl or 0, q.name)
    end
    if route then
        for _, q in ipairs(selected.quests) do
            if not ns.IsOnQuest(q.id) and ns.CanPickUp(q) then add(q) end
        end
    else
        for _, item in ipairs(selected.quests) do
            if not item.inLog and not item.blocker and not item.mid and not lowXP(item) then add(item.q, selected.map) end
        end
    end
    ns.SetMarkers(list)
end

function ns.Refresh()
    if not frame then return end
    if not frame:IsShown() then
        -- Hidden window: keep the map pins up to date anyway.
        if ZoneGuideDB.markAll then
            local plan = ns.GetPlan()
            local route = plan and plan.verdict == "start"
            local selected = plan and select(2, zonesFor(plan, route))
            updateMarkers(plan, selected, route)
        end
        return
    end
    local plan, message = ns.GetPlan()
    for _, r in ipairs(zoneRows) do r:Hide() end
    for _, r in ipairs(rows) do r:Hide(); r.entry = nil; r.expand:Hide() end

    pinsButton.text:SetText(ZoneGuideDB.markAll and "Map pins: |cff40ff40on|r" or "Map pins: off")
    if not plan then
        verdictText:SetText("ZoneGuide")
        subText:SetText(message or "")
        footer:SetText("")
        sortButton:Hide()
        updateMarkers(nil)
        return
    end

    local route = plan.verdict == "start"
    sortButton:SetShown(not route)
    sortButton.text:SetText(sortMode() == "xp" and "Sort: XP" or "Sort: Level")

    local zones, selected, target = zonesFor(plan, route)
    verdictText:SetText(string.format(VERDICT[plan.verdict], target.name))
    if route then
        local xpNote = target.value >= 0.05 and string.format(" (about %s of XP)", levels(target.value)) or ""
        subText:SetText(string.format("Level %d. %d route quests left here%s.", ns.player.level, #target.quests, xpNote))
    elseif plan.reason == "grind" then
        local here = plan.verdict == "grind"
        subText:SetText(string.format("No quests within %d levels of you are worth the trip right now. Kill mobs (or run a "
            .. "dungeon) %s until level %d: then about %s of quests open up %s.",
            ns.MAX_ABOVE, here and "here" or ("in " .. plan.best.name), plan.best.nextAt,
            levels(plan.best.nextValue), here and "here" or "there"))
    elseif plan.reason == "soon" then
        subText:SetText(string.format("Almost level %d: about %s of quests here open up then. Finish the level here. Then: %s.",
            ns.player.level + 1, levels(plan.here.soon), plan.best.name))
    elseif plan.verdict == "stay" then
        local nextUp = ""
        if plan.best ~= plan.here then nextUp = string.format(" Then: %s.", plan.best.name) end
        subText:SetText(string.format("Finish here first: about %s of quests left, %d to pick up now.%s",
            levels(plan.here.value), plan.here.open, nextUp))
    elseif plan.verdict == "move" and plan.here.left < ns.MIN_OPEN_STAY and plan.here.left > 0 then
        subText:SetText(string.format("%s only has %d quest%s left: not worth stopping for. %s has about %s.",
            plan.here.name, plan.here.left, plan.here.left == 1 and "" or "s", plan.best.name, levels(plan.best.value)))
    elseif plan.verdict == "move" then
        subText:SetText(string.format("%s only has about %s left. %s has about %s.",
            plan.here.name, levels(plan.here.value), plan.best.name, levels(plan.best.value)))
    else
        subText:SetText(string.format("Best zone for level %d: about %s of quests.", ns.player.level, levels(plan.best.value)))
    end

    updateMarkers(plan, selected, route)

    -- Zone rows: the best few, plus where you are if it isn't among them.
    local y = -14 - (verdictText:GetStringHeight() or 14) - (subText:GetStringHeight() or 12) - 8
    for i, e in ipairs(zones) do
        local r = zoneRows[i]
        r.zone = e.name
        local label = e.name
        if e == plan.here then label = label .. " |cff999999(here)|r" end
        if e == selected then label = "|cffffffff> " .. label .. "|r" end
        r.name:SetText(label)
        r.bar:SetValue(math.min(e.value, ns.BAR_FULL))
        local frac = math.min(e.value / ns.BAR_FULL, 1)
        r.bar:SetStatusBarColor(1 - frac, 0.4 + 0.6 * frac, 0.2)
        r.value:SetText(levels(e.value))
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 10, y)
        r:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
        r:Show()
        y = y - LINE_H - 2
    end
    y = y - 6

    -- Scrolling quest list between the zone rows and the footer.
    buildDisplay(plan, selected, route)
    local visible = math.max(1, math.floor((frame:GetHeight() + y - 26) / LINE_H))
    local maxScroll = math.max(0, #display - visible)
    if scroll > maxScroll then scroll = maxScroll end
    if scroll < 0 then scroll = 0 end

    if #display == 0 then
        local r = getRow(1)
        r.text:SetText("No quests worth doing left here.")
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 10, y)
        r:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
        r:Show()
    end
    for i = 1, math.min(visible, #display - scroll) do
        local e = display[scroll + i]
        local r = getRow(i)
        r.entry = e
        if e.kind == "header" or e.kind == "label" then
            r.text:SetText(e.text)
        elseif e.kind == "step" then
            r.text:SetText(stepText(e.n, e.step))
        else
            r.text:SetText(questText(e.item, e.noTag))
        end
        r.expand:SetShown(e.kind == "quest" and e.item.chain ~= nil)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 10, y - (i - 1) * LINE_H)
        r:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
        r:Show()
    end

    local notes = {}
    if #display > visible then
        notes[#notes + 1] = string.format("%d-%d of %d, scroll for more", scroll + 1, math.min(scroll + visible, #display), #display)
    end
    for _, e in ipairs(display) do
        if e.kind == "quest" and e.item.star then
            notes[#notes + 1] = STAR .. " worth unlocking"
            break
        end
    end
    notes[#notes + 1] = "/zg to hide"
    footer:SetText(table.concat(notes, "  |  "))
end
