#!/usr/bin/env python3
"""Load ZoneGuide in Lua 5.1 with a fake WoW API.

python3 -I test_addon.py <addon dir>          spot checks for several characters
python3 -I test_addon.py <addon dir> sim      simulate leveling 12 -> 60 following the addon
"""
import os, sys
from lupa.lua51 import LuaRuntime

XP_TO_LEVEL = [0, 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400,
               16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300,
               47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300,
               111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800,
               187900, 195000, 202300, 209800]

MOCK = r'''
P = { level = 1, class = "WARRIOR", race = "Human", faction = "Alliance", map = 0 }
completed, onquest, XPMAX = {}, {}, {}
function UnitLevel() return P.level end
function UnitXPMax() return XPMAX[P.level] or 209800 end
function UnitXP() return P.xp or 0 end
function UnitClass() return "x", P.class end
function UnitRace() return "x", P.race end
function UnitFactionGroup() return P.faction end
function GetRealZoneText() return "" end
C_QuestLog = { IsQuestFlaggedCompleted = function(id) return completed[id] or false end,
               IsOnQuest = function(id) return onquest[id] or false end,
               RequestLoadQuestByID = function(id) REQUESTED[id] = true end }
MAPCONT = {}
C_Map = { GetBestMapForUnit = function() return P.map end,
          GetMapInfo = function(id) return { parentMapID = MAPCONT[id] or 0 } end }
-- Short timers run at once; longer ones wait for RunLater() (the addon retries quest data after 2s).
LATER = {}
C_Timer = { After = function(d, fn) if (d or 0) >= 1 then table.insert(LATER, fn) else fn() end end }
function RunLater() local fns = LATER; LATER = {}; for _, fn in ipairs(fns) do fn() end end
-- Quest rewards: made-up amounts. UNLOADED quests aren't in the game's cache until requested and loaded.
UNLOADED, REQUESTED = {}, {}
function HaveQuestData(id) return not UNLOADED[id] end
function GetQuestLogRewardMoney(id) if UNLOADED[id] then return 0 end return 25 + (id % 9) * 75 end
function GetBuildInfo() return "1.15.8", "60000", "Nov 1 2026", 11508 end
-- Reward items, made up too: every third quest lets you pick one of three items (the third a stack
-- of 5), every fifth gives you two of one item. Items sell for (item id % 7) * 30 copper each.
-- UNLOADED_ITEMS aren't in the game's cache until requested and loaded.
UNLOADED_ITEMS, REQUESTED_ITEMS = {}, {}
function GetNumQuestLogChoices(id) if UNLOADED[id] then return 0 end return id % 3 == 0 and 3 or 0 end
function GetQuestLogChoiceInfo(i, id) local item = id * 10 + i; return "Item " .. item, 0, i == 3 and 5 or 1, 2, true, item end
function GetNumQuestLogRewards(id) if UNLOADED[id] then return 0 end return id % 5 == 0 and 1 or 0 end
function GetQuestLogRewardInfo(i, id) local item = id * 10 + 5; return "Item " .. item, 0, 2, 1, true, item end
function GetItemInfo(item)
  if UNLOADED_ITEMS[item] then return nil end
  return "Item " .. item, "", 2, 10, 5, "Armor", "Mail", 1, "", 0, (item % 7) * 30
end
C_Item = { RequestLoadItemDataByID = function(item) REQUESTED_ITEMS[item] = true end }
SlashCmdList = {}
GameTooltip = setmetatable({}, { __index = function() return function() end end })
MAPLOG = {}
local mapShown, mapID = false, nil
local canvasObj = setmetatable({}, { __index = function(t, k)
  if k == "GetWidth" then return function() return 1000 end end
  if k == "GetHeight" then return function() return 667 end end
  if k == "GetFrameLevel" then return function() return 10 end end
  return function() end end })
WorldMapFrame = {
  IsShown = function() return mapShown end,
  SetMapID = function(_, id) mapID = id; table.insert(MAPLOG, "SetMapID " .. id) end,
  GetMapID = function() return mapID end,
  HookScript = function(_, ev, fn)
    local old = WorldMapFrame["__" .. ev]
    WorldMapFrame["__" .. ev] = old and function(...) old(...); fn(...) end or fn
  end,
  GetCanvas = function() return canvasObj end,
  ScrollContainer = { GetCanvasScale = function() return 1 end },
}
function OpenWorldMap(id) mapShown = true; table.insert(MAPLOG, "OpenWorldMap " .. id); if WorldMapFrame.__OnShow then WorldMapFrame.__OnShow() end end
function CloseMapForTest() mapShown = false; if WorldMapFrame.__OnHide then WorldMapFrame.__OnHide() end end
function InCombatLockdown() return false end
UIParent = {}
local function obj()
  local o = {}
  setmetatable(o, { __index = function(t, k)
    if k == "GetStringWidth" then return function() return 80 end end
    if k == "GetStringHeight" then return function() return 12 end end
    if k == "GetHeight" then return function() return MOCK_H or 400 end end
    if k == "GetWidth" then return function() return 340 end end
    if k == "sizing" then return nil end
    if k == "IsShown" then return function() return t.__shown ~= false end end
    if k == "SetShown" then return function(self, v) self.__shown = v end end
    if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
    if k == "CreateFontString" or k == "CreateTexture" then
      return function() local f = obj(); f.SetText = function(s, v) s.__text = v end; return f end
    end
    return function() end
  end })
  return o
end
function CreateFrame()
  local f = obj()
  f.SetScript = function(self, ev, fn) self["__" .. ev] = fn end
  __frames = __frames or {}
  table.insert(__frames, f)
  return f
end
'''


def load(addon):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    G = lua.globals()
    for i, v in enumerate(XP_TO_LEVEL):
        G.XPMAX[i] = v
    ns = lua.table()
    toc = [l.strip() for l in open(os.path.join(addon, "ZoneGuide.toc")) if l.strip() and not l.startswith("#")]
    loader = lua.eval("function(src, name) return assert(loadstring(src, name)) end")
    for f in toc:
        loader(open(os.path.join(addon, f), encoding="utf-8").read(), f)("ZoneGuide", ns)
    for i in range(1, len(ns.zones) + 1):
        z = ns.zones[i]
        G.MAPCONT[z.map] = 1414 if z.cont == "K" else 1415
    G.ZoneGuideDB = lua.table()
    ev = G.__frames[1]
    ev["__OnEvent"](ev, "PLAYER_LOGIN")
    return lua, G, ns


def plan_of(ns):
    if ns.Invalidate: ns.Invalidate()  # the tests change the character directly, without game events
    r = ns.GetPlan()
    return r if isinstance(r, tuple) else (r, None)


def spot(addon):
    lua, G, ns = load(addon)
    P = G.P
    zmap = {ns.zones[i].name: ns.zones[i].map for i in range(1, len(ns.zones) + 1)}
    cases = [("Human", "WARRIOR", 1, ""), ("Human", "PALADIN", 8, ""), ("NightElf", "HUNTER", 9, ""),
             ("Skyborne", "DRUID", 11, ""), ("Human", "MAGE", 13, "Elwynn Forest"),
             ("NightElf", "HUNTER", 13, "Teldrassil"), ("Dwarf", "PRIEST", 16, "Loch Modan"),
             ("Human", "ROGUE", 22, "Westfall"), ("NightElf", "DRUID", 27, "Ashenvale"),
             ("Dwarf", "HUNTER", 33, ""), ("Gnome", "MAGE", 44, "Tanaris"), ("Human", "PRIEST", 53, "Un'Goro Crater"),
             ("Dwarf", "PALADIN", 59, "Eastern Plaguelands"), ("Orc", "WARRIOR", 20, "")]
    for race, cls, lvl, zone in cases:
        P.race, P.level = race, lvl
        P["class"] = cls
        P.faction = "Horde" if race == "Orc" else "Alliance"
        P.map = zmap.get(zone, 0)
        ns.Refresh()
        plan, msg = plan_of(ns)
        if not plan:
            print(f"--- {race} {cls} {lvl} in {zone or '?'}: {msg}")
            continue
        here = plan.here.name if plan.here else "-"
        print(f"--- {race} {cls} {lvl} in {zone or '?'}: {plan.verdict} -> {plan.best.name}  (here: {here})")
        for i in range(1, min(len(plan.ranked), 4) + 1):
            e = plan.ranked[i]
            print(f"     {e.name:<22} {e.value:4.1f} lv  ({len(e.quests)} quests)")


def sim(addon, race="Human", cls="WARRIOR"):
    lua, G, ns = load(addon)
    P = G.P
    P.race, P.level = race, 12
    P["class"] = cls
    zmap = {ns.zones[i].name: ns.zones[i].map for i in range(1, len(ns.zones) + 1)}
    P.map = zmap["Westfall"]
    xp, last, steps, quests_done, grind = 0, None, 0, 0, 0
    visits = []
    mult = lambda d: 1 if d <= 5 else {6: .8, 7: .6, 8: .4, 9: .2}.get(d, .1)
    while P.level < 60 and steps < 5000:
        steps += 1
        P.xp = int(xp)
        plan, msg = plan_of(ns)
        if not plan:
            print("stopped:", msg)
            break
        if plan.verdict in ("move", "go"):
            P.map = plan.best.map
            continue
        zone = plan.here
        if zone.name != last:
            print(f"  level {P.level:>2}: {zone.name:<22} ({zone.value:.1f} lv of quests there)")
            last = zone.name
            visits.append(zone.name)
        pick = None
        for i in range(1, len(zone.quests) + 1):
            it = zone.quests[i]
            if zone.route:  # starting-zone route: plain quest rows, done in order
                pick = lua.table(q=it)
                break
            if it.blocker is None and it.worth > 0:
                pick = it
                break
        if pick:
            q = pick.q
            G.completed[q.id] = True
            gain = q.xp * mult(P.level - q.lvl) * 1.8  # quest XP plus roughly as much again from kills
            quests_done += 1
        else:
            gain = XP_TO_LEVEL[P.level] * 0.05  # nothing to pick up: grind a bit
            grind += 1
        xp += gain
        while P.level < 60 and xp >= XP_TO_LEVEL[P.level]:
            xp -= XP_TO_LEVEL[P.level]
            P.level += 1
    pingpong = sum(1 for i in range(2, len(visits)) if visits[i] == visits[i - 2])
    print(f"  reached level {P.level} after {quests_done} quests, {len(visits) - 1} moves "
          f"({pingpong} straight back to the previous zone), {grind} grind stops")


def clicks(addon):
    """Click quest rows and chain steps; check the map opens with a pin."""
    lua, G, ns = load(addon)
    P = G.P
    P.race, P.level, P.map = "Human", 20, 1431
    P["class"] = "WARRIOR"
    G.ZoneGuideDB.showGroup = True
    ns.Invalidate()  # the character changed without game events
    ns.Refresh()
    # Click the first visible row of a kind, scrolling down the list until one shows up.
    click = lua.eval("""function(kind, button)
      local main = __frames[2]  -- the ZoneGuide window (frame 1 is the event frame)
      for _ = 1, 60 do
        for _, f in ipairs(__frames) do
          local e = rawget(f, "entry")
          if type(e) == "table" and e.kind == kind and (kind ~= "quest" or button ~= "RightButton" or e.item.chain) then
            f.__OnClick(f, button or "LeftButton")
            return (e.item and (e.item.q or e.item).name) or (e.step and e.step.q.name)
          end
        end
        main.__OnMouseWheel(main, -1)
      end
    end""")
    print("left-click quest:", click("quest"), list(G.MAPLOG.values()))
    print("right-click chain quest:", click("quest", "RightButton"))
    print("left-click chain step:", click("step"), list(G.MAPLOG.values())[-1])
    G.CloseMapForTest()
    print("map closed, pin cleared")
    # Every row's text and tooltip renders for a few characters, including stars and class quests.
    G.ZoneGuideDB.showClass = True
    show = lua.eval("""function()
      local n, stars = 0, 0
      for _, f in ipairs(__frames) do
        local e = rawget(f, "entry")
        if type(e) == "table" and f.__OnEnter then
          f.__OnEnter(f); n = n + 1
          if e.kind == "quest" and e.item.star then stars = stars + 1 end
        end
      end
      return n, stars
    end""")
    for race, cls, lvl, zone in [("Human", "WARRIOR", 14, 1436), ("Gnome", "MAGE", 43, 1446), ("Dwarf", "HUNTER", 47, 1427)]:
        P.race, P.level, P.map = race, lvl, zone
        P["class"] = cls
        ns.Invalidate()
        ns.Refresh()
        rows, stars = show()
        print(f"{race} {cls} {lvl}: {rows} rows with tooltips, {stars} starred on screen")


def chains(addon):
    """Show what expanding a few locked chain quests would list."""
    lua, G, ns = load(addon)
    P = G.P
    zmap = {ns.zones[i].name: ns.zones[i].map for i in range(1, len(ns.zones) + 1)}
    for race, cls, lvl, zone in [("Human", "WARRIOR", 25, "Duskwood"), ("NightElf", "DRUID", 38, "Dustwallow Marsh"),
                                 ("Dwarf", "PALADIN", 45, "Feralas")]:
        P.race, P.level, P.map = race, lvl, zmap[zone]
        P["class"] = cls
        plan, _ = plan_of(ns)
        print(f"--- {race} {cls} {lvl} in {zone}: {plan.verdict} {plan.best.name}")
        z = plan.here
        shown = 0
        for src in (z.quests, ns.DungeonQuests()):
            for i in range(1, len(src) + 1):
                it = src[i]
                if it.blocker == "needs an earlier quest":
                    steps = ns.ChainSteps(it.q)
                    if len(steps) and shown < 4:
                        shown += 1
                        print(f"   [{it.q.lvl}] {it.q.name} ({it.q.dungeon or z.name}) needs:")
                        for j in range(1, len(steps) + 1):
                            q = steps[j].q
                            print(f"        {j}. [{q.lvl}] {q.name} - {q.giver}, {q.where or ''} {tuple(q.at.values()) if q.at else ''}")
        G.ZoneGuideDB.showGroup = True
        ns.Refresh()
        G.ZoneGuideDB.sort = "xp"
        ns.Refresh()


def render(addon, race, cls, lvl, zone, done_below=0):
    """Print what the window shows (tall window, all sections open). Quests below done_below are done."""
    import re
    lua, G, ns = load(addon)
    P = G.P
    zmap = {ns.zones[i].name: ns.zones[i].map for i in range(1, len(ns.zones) + 1)}
    P.race, P.level, P.map = race, int(lvl), zmap.get(zone, 0)
    P["class"] = cls
    for src in [ns.zones[i].quests for i in range(1, len(ns.zones) + 1)] + [ns.dungeonQuests, ns.classQuests]:
        for j in range(1, len(src) + 1):
            if src[j].lvl < int(done_below):
                G.completed[src[j].id] = True
    G.ZoneGuideDB.showGroup = True
    G.ZoneGuideDB.showClass = True
    G.MOCK_H = 3000
    ns.Invalidate()
    ns.Refresh()
    clean = lambda t: re.sub(r"\|T[^|]*\|t", "*", re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", t or ""))
    texts = [f.text.__text for f in G.__frames.values() if lua.eval("rawget")(f, "entry") is not None and f.text]
    plan, msg = ns.GetPlan(), None
    for f in G.__frames.values():
        pass
    print("\n".join(clean(t) for t in texts))


def classes(addon):
    """Print the class-quest section for characters whose races have their own versions of class quests."""
    cases = [("Human", "WARRIOR", 12), ("Dwarf", "WARRIOR", 12), ("NightElf", "WARRIOR", 12), ("Skyborne", "WARRIOR", 12),
             ("Human", "WARRIOR", 30), ("Human", "ROGUE", 16), ("Dwarf", "ROGUE", 12), ("Gnome", "WARLOCK", 12),
             ("Human", "WARLOCK", 20), ("NightElf", "PRIEST", 12), ("Human", "PRIEST", 12), ("Gnome", "MAGE", 16),
             ("Human", "MAGE", 38), ("Dwarf", "HUNTER", 12), ("Dwarf", "PALADIN", 12)]
    for race, cls, lvl in cases:
        lua, G, ns = load(addon)
        P = G.P
        P.race, P.level, P.map = race, lvl, 0
        P["class"] = cls
        ns.Invalidate()
        ns.UpdatePlayer()
        items = ns.ClassQuests()
        shown = [items[i] for i in range(1, len(items) + 1) if not items[i].mid]
        print(f"== {race} {cls} {lvl}: {len(shown)} shown ({len(items)} before chain folding)")
        for it in shown:
            q = it.q
            steps = it.steps
            chain = ""
            if steps and len(steps) > 0:
                chain = "  <- " + " > ".join(f"{steps[j].q.name} ({steps[j].zone or '?'})" for j in range(1, len(steps) + 1))
            print(f"   [{q.lvl}] {q.name} - {q.where or '?'}{'  [' + it.blocker + ']' if it.blocker else ''}{chain}")


def checks(addon):
    """Starting route by location, map pins, dungeon section and the stay rule."""
    lua, G, ns = load(addon)
    P = G.P
    zmap = {ns.zones[i].name: ns.zones[i].map for i in range(1, len(ns.zones) + 1)}

    def plan_for(race, cls, lvl, zone):
        P.race, P.level, P.map = race, lvl, zmap.get(zone, 0)
        P["class"] = cls
        return plan_of(ns)[0]

    print("-- starting route follows where you are")
    for race, lvl, zone in [("Dwarf", 3, "Elwynn Forest"), ("Human", 3, "Dun Morogh"), ("Dwarf", 3, "?"),
                            ("NightElf", 8, "Elwynn Forest"), ("Gnome", 8, "Teldrassil"), ("Dwarf", 12, "Elwynn Forest")]:
        pl = plan_for(race, "WARRIOR", lvl, zone)
        names = [pl.here.quests[i].name for i in range(1, min(4, len(pl.here.quests)) + 1)] if pl.verdict == "start" else []
        print(f"   {race} {lvl} in {zone}: {pl.verdict} {pl.here.name if pl.here else pl.best.name} {names}")
    # Human-only quests stay off a dwarf's Elwynn route.
    pl = plan_for("Dwarf", "WARRIOR", 8, "Elwynn Forest")
    human_only = [pl.here.quests[i].name for i in range(1, len(pl.here.quests) + 1) if pl.here.quests[i].races == 1]
    print("   Human-only quests on a dwarf's Elwynn route:", human_only or "none")

    print("-- map pins")
    got = {}
    real = ns.SetMarkers
    def spy(lst):
        got["list"] = lst
        return real(lst)
    ns.SetMarkers = spy
    G.ZoneGuideDB.markAll = True
    pl = plan_for("Human", "WARRIOR", 14, "Westfall")
    ns.Refresh()
    lst = got["list"]
    n = len(lst)
    quests = sum(len(lst[i].names) for i in range(1, n + 1))
    print(f"   Human 14 in Westfall: {n} pins for {quests} quests, e.g. {lst[1].giver}: {list(lst[1].names.values())}")
    first = lst[1].names[1]
    qid = None
    for i in range(1, len(pl.here.quests) + 1):
        it = pl.here.quests[i]
        if first.endswith("] " + it.q.name):
            qid = it.q.id
    G.onquest[qid] = True
    ev = G.__frames[1]
    ev["__OnEvent"](ev, "QUEST_ACCEPTED", qid)
    lst2 = got["list"]
    quests2 = sum(len(lst2[i].names) for i in range(1, len(lst2) + 1))
    print(f"   after accepting {first}: {quests2} quests pinned ({quests - quests2} fewer)")
    G.OpenWorldMap(zmap["Westfall"]); G.WorldMapFrame.SetMapID(None, zmap["Westfall"])
    ns.SetMarkers(lst2)
    G.ZoneGuideDB.markAll = False
    ns.Refresh()
    print(f"   pins off: {len(got['list'])} pins")
    G.onquest[qid] = None
    ns.SetMarkers = real

    print("-- dungeon section")
    for race, cls, lvl in [("Human", "WARRIOR", 18), ("Dwarf", "PALADIN", 34)]:
        P.race, P.level, P.map = race, lvl, 0
        P["class"] = cls
        ns.Invalidate(); ns.UpdatePlayer()
        items = ns.DungeonQuests()
        by = {}
        for i in range(1, len(items) + 1):
            it = items[i]
            if it.mid:
                continue
            by.setdefault(it.q.dungeon, []).append(f"[{it.q.lvl}] {it.q.name}{' (' + it.blocker + ')' if it.blocker else ''}")
        print(f"   {race} {cls} {lvl}:")
        for d, qs in by.items():
            print(f"      {d}: {len(qs)} - " + "; ".join(qs[:6]) + (" ..." if len(qs) > 6 else ""))

    print("-- working through a zone until only a couple of quests are left")
    P.race, P["class"] = "Human", "WARRIOR"
    for zone, lvl in [("Duskwood", 26), ("Wetlands", 25), ("Stranglethorn Vale", 33)]:
        P.level, P.map = lvl, zmap[zone]
        done, trail = [], []
        for _ in range(200):
            pl = plan_of(ns)[0]
            here = pl.here
            trail.append(f"{here.left}:{pl.verdict}")
            if pl.verdict != "stay":
                break
            pick = None
            for i in range(1, len(here.quests) + 1):
                it = here.quests[i]
                if it.blocker is None and it.worth > 0:
                    pick = it.q.id
                    break
            if pick is None:
                break
            G.completed[pick] = True
            done.append(pick)
        print(f"   {zone} at {lvl}: did {len(done)} quests; quests left:verdict at the end -> {' '.join(trail[-5:])}; then go to {pl.best.name}")
        for qid in done:
            G.completed[qid] = None

    print("-- quest gold next to the level estimate")
    import re
    plain = lambda t: re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", t or "")
    get = lua.eval("""function(fn, name) for i = 1, 200 do local n, v = debug.getupvalue(fn, i)
        if not n then return nil end if n == name then return v end end end""")
    G.ZoneGuideDB.markAll = False
    P.race, P["class"], P.level, P.map = "Human", "WARRIOR", 14, zmap["Westfall"]

    def rows(note):
        ns.Invalidate()
        ns.Refresh()
        zr, sub = get(ns.Refresh, "zoneRows"), get(ns.Refresh, "subText")
        shown = [f"{plain(zr[i].name.__text)}: {zr[i].value.__text} {plain(zr[i].gold.__text)}"
                 for i in range(1, len(zr) + 1) if zr[i].__shown is not False and zr[i].name.__text]
        print(f"   {note}: " + " | ".join(shown))
        print(f"      {plain(sub.__text)}")

    rows("Human 14 in Westfall")
    plan = plan_of(ns)[0]
    w = plan.here
    counted = [w.quests[i].q.id for i in range(1, len(w.quests) + 1)
               if w.quests[i].worth and w.quests[i].worth > 0 and not w.quests[i].away]
    # A fresh login where the game hasn't loaded three of those quests yet.
    lua, G, ns = load(addon)
    P = G.P
    get = lua.eval("""function(fn, name) for i = 1, 200 do local n, v = debug.getupvalue(fn, i)
        if not n then return nil end if n == name then return v end end end""")
    G.ZoneGuideDB.markAll = False
    P.race, P["class"], P.level, P.map = "Human", "WARRIOR", 14, zmap["Westfall"]
    for qid in counted[:3]:
        G.UNLOADED[qid] = True
    rows("fresh login, three Westfall quests not loaded yet")
    print(f"      asked the game for: {sorted(k for k in G.REQUESTED.keys())} (of {counted[:3]})")
    for qid in counted[:3]:
        G.UNLOADED[qid] = None
        ev = G.__frames[1]
        ev["__OnEvent"](ev, "QUEST_DATA_LOAD_RESULT", qid, True)
    G.RunLater()
    rows("after they load")

    print("-- selling reward items: every item a quest gives, but only the best one you pick from")
    price = lambda item: (item % 7) * 30
    def expect(qid):
        money = 25 + (qid % 9) * 75
        pick = max(price(qid * 10 + i) * (5 if i == 3 else 1) for i in (1, 2, 3)) if qid % 3 == 0 else 0
        given = price(qid * 10 + 5) * 2 if qid % 5 == 0 else 0
        return money, pick, given
    here = plan_of(ns)[0].here
    names = {here.quests[i].q.id: here.quests[i].q for i in range(1, len(here.quests) + 1)}
    picks = []
    for want in ("both", "pick", "given", "neither"):
        ok = {"both": lambda q: q % 15 == 0, "pick": lambda q: q % 3 == 0 and q % 5,
              "given": lambda q: q % 5 == 0 and q % 3, "neither": lambda q: q % 3 and q % 5}[want]
        qid = next((q for q in counted if ok(q)), next(q for q in range(1, 100) if ok(q)))
        picks.append(qid)
        money, pick, given = expect(qid)
        total, partial, vendor = ns.QuestMoney(qid)
        print(f"   {want:7} quest {qid}: gold {money} + best pick {pick} + given {given} = {money + pick + given}c;"
              f" addon says {total}c ({vendor}c from items){' MISMATCH' if total != money + pick + given else ''}")
    tip = lua.eval("""function(q)
      local lines = {}
      GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
      for _, f in ipairs(__frames) do
        local e = rawget(f, "entry")
        if type(e) == "table" and e.kind == "quest" and f.__OnEnter then
          f.entry = { kind = "quest", item = { q = q } }
          f.__OnEnter(f)
          f.entry = e
          break
        end
      end
      GameTooltip.AddLine = nil
      return lines
    end""")
    ztip = lua.eval("""function()
      local lines = {}
      GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
      for _, f in ipairs(__frames) do
        local e = rawget(f, "entry")
        if type(e) == "table" and e.money and f.__OnEnter then f.__OnEnter(f); break end
      end
      GameTooltip.AddLine = nil
      return lines
    end""")
    for qid in picks[:3]:
        q = names.get(qid)
        if q:
            lines = [plain(x) for x in tip(q).values()]
            print(f"   tooltip of {q.name}: " + next((x for x in lines if x.startswith("Gold")), "(no gold line)"))
    print("   zone tooltip: " + " / ".join(plain(x) for x in ztip().values()))
    # A fresh login where the game has the quests but not the items of one you pick from.
    lua, G, ns = load(addon)
    P = G.P
    get = lua.eval("""function(fn, name) for i = 1, 200 do local n, v = debug.getupvalue(fn, i)
        if not n then return nil end if n == name then return v end end end""")
    G.ZoneGuideDB.markAll = False
    P.race, P["class"], P.level, P.map = "Human", "WARRIOR", 14, zmap["Westfall"]
    qid = next(q for q in counted if q % 3 == 0)
    items = [qid * 10 + i for i in (1, 2, 3)]
    for item in items:
        G.UNLOADED_ITEMS[item] = True
    rows(f"fresh login, the items of quest {qid} not loaded yet")
    print(f"      asked the game for items: {sorted(k for k in G.REQUESTED_ITEMS.keys())} (of {items})")
    for item in items:
        G.UNLOADED_ITEMS[item] = None
        ev = G.__frames[1]
        ev["__OnEvent"](ev, "ITEM_DATA_LOAD_RESULT", item, True)
    G.RunLater()
    rows("after they load")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "render":
        render(sys.argv[1], *sys.argv[3:8])
        sys.exit()
    if len(sys.argv) > 2 and sys.argv[2] == "clicks":
        clicks(sys.argv[1])
        sys.exit()
    if len(sys.argv) > 2 and sys.argv[2] == "checks":
        checks(sys.argv[1])
        sys.exit()
    if len(sys.argv) > 2 and sys.argv[2] == "classes":
        classes(sys.argv[1])
        sys.exit()
    if len(sys.argv) > 2 and sys.argv[2] == "chains":
        chains(sys.argv[1])
        sys.exit()
    if len(sys.argv) > 2 and sys.argv[2] == "sim":
        sim(sys.argv[1], *(sys.argv[3:5]))
    else:
        spot(sys.argv[1])
