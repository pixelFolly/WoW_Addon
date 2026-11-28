-- SessionStats: time, XP and gold since login, with a reset button.
-- Counts restart on each new login. A /reload keeps them.

local ADDON = ...
local f = CreateFrame("Frame", "SessionStatsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)

local db            -- SessionStatsDB (per character)
local lastXP, lastMax, lastLevel, lastMoney

-- Helpers -------------------------------------------------------------------

local function FormatTime(sec)
  sec = math.max(0, math.floor(sec))
  return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

local function FormatMoney(copper)
  copper = math.floor(copper or 0)
  local g = math.floor(copper / 10000)
  local s = math.floor(copper / 100) % 100
  local c = copper % 100
  if g > 0 then
    return string.format("%d|cffffd700g|r %d|cffc7c7cfs|r %d|cffeda55fc|r", g, s, c)
  elseif s > 0 then
    return string.format("%d|cffc7c7cfs|r %d|cffeda55fc|r", s, c)
  end
  return string.format("%d|cffeda55fc|r", c)
end

local function FormatNumber(n)
  local s = tostring(math.floor(n))
  local out
  repeat
    s, out = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until out == 0
  return s
end

local function Elapsed()
  return time() - (db.start or time())
end

local function PerHour(amount)
  local e = Elapsed()
  if e < 60 then return 0 end
  return amount * 3600 / e
end

local function Snapshot()
  lastXP, lastMax, lastLevel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
  lastMoney = GetMoney()
end

local function Reset()
  db.start = time()
  db.xp = 0
  db.gold = 0
  Snapshot()
end

-- Window --------------------------------------------------------------------

f:SetSize(190, 96)
f:SetFrameStrata("MEDIUM")
f:SetClampedToScreen(true)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
if f.SetBackdrop then
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  f:SetBackdropColor(0, 0, 0, 0.75)
end

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -8)
title:SetText("Session")

local function Line(y)
  local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", 10, y)
  local value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  value:SetPoint("TOPRIGHT", -10, y)
  value:SetJustifyH("RIGHT")
  return label, value
end

local timeLabel, timeText = Line(-28)
local xpLabel, xpText     = Line(-44)
local goldLabel, goldText = Line(-60)
timeLabel:SetText("Time")
xpLabel:SetText("XP")
goldLabel:SetText("Gold")

local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
resetBtn:SetSize(52, 18)
resetBtn:SetPoint("TOPRIGHT", -6, -5)
resetBtn:SetText("Reset")
resetBtn:SetScript("OnClick", function() Reset(); f:Refresh() end)

-- Hover for per-hour rates
f:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("SessionStats")
  GameTooltip:AddDoubleLine("XP per hour", FormatNumber(PerHour(db.xp)), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Gold per hour", FormatMoney(PerHour(db.gold)), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddLine("Drag to move. /sstats to show or hide.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end)
f:SetScript("OnLeave", function() GameTooltip:Hide() end)

f:SetScript("OnDragStart", function(self) self:StartMoving() end)
f:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, relPoint, x, y = self:GetPoint()
  db.pos = { point, relPoint, x, y }
end)

function f:Refresh()
  if not db then return end
  timeText:SetText(FormatTime(Elapsed()))
  xpText:SetText(FormatNumber(db.xp))
  goldText:SetText(FormatMoney(db.gold))
end

local tick = 0
f:SetScript("OnUpdate", function(self, elapsed)
  tick = tick + elapsed
  if tick >= 1 then
    tick = 0
    self:Refresh()
  end
end)

-- Tracking ------------------------------------------------------------------

local function OnXP()
  local xp, max, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
  if level > lastLevel then
    -- Finished the old level, then gained some of the new one.
    db.xp = db.xp + (lastMax - lastXP) + xp
  elseif level == lastLevel and xp > lastXP then
    db.xp = db.xp + (xp - lastXP)
  end
  lastXP, lastMax, lastLevel = xp, max, level
end

local function OnMoney()
  local money = GetMoney()
  if money > lastMoney then
    db.gold = db.gold + (money - lastMoney)  -- only money coming in; spending isn't subtracted
  end
  lastMoney = money
end

f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("PLAYER_MONEY")
f:SetScript("OnEvent", function(self, event, isInitialLogin, isReloadingUi)
  if event == "PLAYER_ENTERING_WORLD" then
    local first = not db
    SessionStatsDB = SessionStatsDB or {}
    db = SessionStatsDB
    if first then
      -- New login (or no saved session): start fresh. A /reload keeps the counts.
      if isInitialLogin or not db.start then
        Reset()
      else
        Snapshot()
      end
      self:ClearAllPoints()
      if db.pos then
        self:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
      else
        self:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -200)
      end
      if db.hidden then self:Hide() else self:Show() end
    end
    self:Refresh()
  elseif not db then
    return
  elseif event == "PLAYER_XP_UPDATE" then
    OnXP()
    self:Refresh()
  elseif event == "PLAYER_MONEY" then
    OnMoney()
    self:Refresh()
  end
end)

-- Slash command -------------------------------------------------------------

SLASH_SESSIONSTATS1 = "/sstats"
SLASH_SESSIONSTATS2 = "/sessionstats"
SlashCmdList.SESSIONSTATS = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if not db then return end
  if msg == "reset" then
    Reset(); f:Refresh()
    print("|cff33ff99SessionStats|r: reset.")
  elseif f:IsShown() then
    f:Hide(); db.hidden = true
  else
    f:Show(); db.hidden = false; f:Refresh()
  end
end
