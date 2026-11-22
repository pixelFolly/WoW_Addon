#!/usr/bin/env python3
"""Build ZoneGuide/Data_*.lua.

python3 -I build_data.py <RXPGuides dir> <QuestieDB dir> <Questie dir> <addon out dir>

Inputs:
  - RestedXP free Forever guides (CC BY-NC-SA 4.0)  -> starting-zone routes (levels 1 to ~12)
  - QuestieDB Forever data (GPLv3), loaded through QuestieDB's own generator so that its Forever
    corrections are applied: Forever-only quests and zones, fixes learned from player traces,
    and hand-written fixes. The raw data file alone is missing about 1,200 Alliance quests.
  - QuestieDB quest XP: what players actually got on Forever (xpDB-traces), Classic values otherwise
  - Questie blacklist + quest tag corrections (GPLv3) -> drop quests not in the game, flag elite/dungeon
  - tools/zones_alliance.json (ours)                 -> which zones get scored
"""
import collections, json, os, re, statistics, sys
from lupa.lua51 import LuaRuntime, lua_type

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import extract_rxp  # noqa: E402

ALLIANCE_MASK = 1 | 4 | 8 | 64
# Instances in QuestieDB's dungeon list that aren't levelling dungeons.
RAIDS_AND_BATTLEGROUNDS = {"Molten Core", "Onyxia's Lair", "Blackwing Lair", "Zul'Gurub", "Ruins of Ahn'Qiraj",
                           "Temple of Ahn'Qiraj", "Naxxramas", "Warsong Gulch", "Arathi Basin", "Alterac Valley"}
SKYBORNE_A = 1 << 32
JUNK = re.compile(r"\[DEPRECATED\]|<UNUSED>|<NYI>|^zz|\bTEST\b|\[PH\]|<TXT>|UNUSED", re.I)
TAGS = {1: "elite", 81: "dungeon", 62: "raid", 41: "pvp", 88: "raid", 89: "raid", 85: "dungeon"}
# Quest sort ids for class quests -> class bit (as in UnitClass order used by the addon).
CLASS_SORTS = {-81: 1, -141: 2, -261: 4, -162: 8, -262: 16, -82: 64, -161: 128, -61: 256, -263: 1024}
# Reputations that start below Neutral: even a Neutral requirement is a real gate (as in Questie).
BELOW_NEUTRAL = {87, 576, 910}
FACTIONS = {
    21: "Booty Bay", 47: "Ironforge", 54: "Gnomeregan", 59: "Thorium Brotherhood", 69: "Darnassus",
    72: "Stormwind", 87: "Bloodsail Buccaneers", 92: "Gelkis Clan Centaur", 93: "Magram Clan Centaur",
    270: "Zandalar Tribe", 349: "Ravenholdt", 369: "Gadgetzan", 470: "Ratchet", 509: "League of Arathor",
    529: "Argent Dawn", 576: "Timbermaw Hold", 577: "Everlook", 589: "Wintersaber Trainers",
    609: "Cenarion Circle", 730: "Stormpike Guard", 749: "Hydraxian Waterlords", 890: "Silverwing Sentinels",
    909: "Darkmoon Faire", 910: "Brood of Nozdormu",
}

SOURCE_RACES = {
    "RestedXP-Skyborne.lua": "Skyborne",
    "Alliance-1-10_NightElf.lua": "NightElf",
    "Alliance-1-13_Human.lua": "Human",
    "Alliance-1-14_DwarfGnome.lua": "Dwarf/Gnome",
    "Alliance-11-20.lua": None,
}


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_list(xs):
    return "{" + ",".join(str(x) for x in xs) + "}"


def to_py(v):
    if lua_type(v) != "table":
        return int(v) if isinstance(v, float) and v.is_integer() else v
    return {(int(k) if isinstance(k, float) and k.is_integer() else k): to_py(x) for k, x in v.items()}


def arr(t):
    """Lua array (now a dict 1..n, maybe with holes) -> python list in order."""
    if not t:
        return []
    if not isinstance(t, dict):
        return [t]
    return [t[k] for k in sorted(k for k in t if isinstance(k, int))]


LOAD_CORRECTED = r'''
local config = dofile("src/config.lua")
local flavorLoader = dofile("generator/flavor.lua")
local loaded = flavorLoader.load(config.flavorByName.Forever, {Quest=true, Npc=true, Object=true}, true)
-- Keep only what the build needs (one spawn point per zone), so the hand-over to python is quick.
local function firstSpawns(spawns)
  if type(spawns) ~= "table" then return nil end
  local out = {}
  for zone, coords in pairs(spawns) do
    if type(coords) == "table" and type(coords[1]) == "table" then out[zone] = { coords[1][1], coords[1][2] } end
  end
  return out
end
local quests, npcs, objects = {}, {}, {}
for id, t in pairs(loaded.Quest.entities) do
  local r = {}
  for i = 1, 36 do
    if i ~= 8 and i ~= 9 and i ~= 10 and i ~= 29 then r[i] = t[i] end
  end
  quests[id] = r
end
for id, t in pairs(loaded.Npc.entities) do
  npcs[id] = { [1] = t[1], [7] = firstSpawns(t[7]), [9] = t[9], [13] = t[13] }
end
for id, t in pairs(loaded.Object.entities) do
  objects[id] = { [1] = t[1], [4] = firstSpawns(t[4]), [5] = t[5] }
end
return quests, npcs, objects
'''


def load_questiedb(qdb_dir):
    """Quests, NPCs and objects for Forever with QuestieDB's static corrections applied."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    cwd = os.getcwd()
    os.chdir(qdb_dir)  # the generator loads its files by relative path
    try:
        lua.execute("arg = {}")
        quests, npcs, objects = lua.execute(LOAD_CORRECTED)
    finally:
        os.chdir(cwd)
    return to_py(quests), to_py(npcs), to_py(objects)


def load_raw_ids(qdb_dir):
    """Quest ids in QuestieDB's uncorrected Forever data (the Classic quests Forever started from)."""
    text = open(os.path.join(qdb_dir, "data/Forever/foreverQuestDB.lua"), encoding="utf-8").read()
    return {int(x) for x in re.findall(r"^\s*\[(\d+)\]\s*=\s*\{", text, re.M)}


def load_blacklist(questie_dir):
    path = os.path.join(questie_dir, "Database/Corrections/QuestieQuestBlacklist.lua")
    text = open(path, encoding="utf-8").read()
    return {int(m.group(1)) for m in re.finditer(r"^\s*\[(\d+)\]\s*=\s*true\s*,", text, re.M)}


def load_tags(questie_dir):
    """Elite/dungeon/raid tags that apply to Classic Era (which Forever is built on)."""
    path = os.path.join(questie_dir, "Database/Corrections/questTagInfoCorrections.lua")
    tags = {}
    for m in re.finditer(r"^\s*\[(\d+)\]\s*=\s*(.*?)\{(\d+),", open(path, encoding="utf-8").read(), re.M):
        cond = m.group(2).strip()
        if cond and not (re.search(r"==\s*Expansions\.Era", cond) or re.search(r"<=?\s*Expansions\.", cond)):
            continue
        tag = TAGS.get(int(m.group(3)))
        if tag:
            tags[int(m.group(1))] = tag
    return tags


AREA_MAP = {}   # area id -> uiMapID of the map its coordinates are on
NAME_MAP = {}   # zone name -> uiMapID
PARENT = {}     # sub-area id -> parent area id


def load_areas(qdb_dir):
    """Area id -> zone name (parent zone for sub-areas), and dungeon area id -> (name, parent area)."""
    names = {}
    zones = os.path.join(qdb_dir, "support/Forever/Zones")
    for a, m, label in re.findall(r"^\s*\[(\d+)\]\s*=\s*(\d+),\s*--\s*(.+?)\s*$",
                                  open(os.path.join(zones, "areaIdToUiMapId.lua"), encoding="utf-8").read(), re.M):
        # Labels look like "Sub-area -> Zone"; some carry a note after a colon.
        names[int(a)] = "" if label.startswith("Synthetic") else label.split("->")[-1].split(":")[0].strip()
        AREA_MAP[int(a)] = int(m)
        if "->" not in label:
            NAME_MAP.setdefault(label.strip(), int(m))
    text = open(os.path.join(zones, "subZoneToParentZone.lua"), encoding="utf-8").read()
    override = text[:text.index("ZoneDB.private.subZoneToParentZone =")]
    for chunk in (text[len(override):], override):  # the override table wins
        for a, p in re.findall(r"^\s*\[(\d+)\]\s*=\s*(\d+),", chunk, re.M):
            if int(a) != int(p):
                PARENT[int(a)] = int(p)
    dungeons = {}
    path = os.path.join(zones, "dungeons.lua")
    for a, name, alts, parent in re.findall(r'^\s*\[(\d+)\]\s*=\s*\{"([^"]+)",(nil|\{[\d,]*\}),(\d+)', open(path, encoding="utf-8").read(), re.M):
        entry = (name, int(parent))
        dungeons[int(a)] = entry
        if alts != "nil":
            for x in re.findall(r"\d+", alts):
                dungeons[int(x)] = entry
    # Instance areas are only labelled "Referenced dungeon area": name them after their dungeon.
    for a, name in names.items():
        if name.startswith("Referenced"):
            names[a] = dungeons[a][0] if a in dungeons else ""
    return names, dungeons


def load_xp(qdb_dir):
    """Quest id -> (quest level, xp). What players got on Forever wins over the Classic value."""
    xp = {}
    for name in ("xpDB-classic.lua", "xpDB-traces.lua"):
        path = os.path.join(qdb_dir, "support/Forever/QuestXP", name)
        for a, b, c in re.findall(r"\[(\d+)\]\s*=\s*\{(\d+),\s*(\d+)\}", open(path, encoding="utf-8").read()):
            xp[int(a)] = (int(b), int(c))
    return xp


def main(rxp_dir, qdb_dir, questie_dir, out_dir):
    quests, npcs, objects = load_questiedb(qdb_dir)
    raw_ids = load_raw_ids(qdb_dir)
    blacklist, tags, xpdb = load_blacklist(questie_dir), load_tags(questie_dir), load_xp(qdb_dir)
    area_names, dungeons = load_areas(qdb_dir)
    cfg = json.load(open(os.path.join(HERE, "zones_alliance.json")))
    area_to_zone = {z[1]: z for z in cfg["zones"]}

    # Breadcrumbs: the quests that send you to each quest.
    led_by = collections.defaultdict(set)
    for qid, t in quests.items():
        if t.get(27):
            led_by[int(t[27])].add(qid)
        for b in arr(t.get(28)):
            led_by[qid].add(int(b))

    def ally_mask(t):
        """The Alliance races a quest is limited to, or 0 when every Alliance race can take it."""
        races = (t or {}).get(6) or 0
        ally = races & (ALLIANCE_MASK | SKYBORNE_A)
        return ally if races and ally not in (ALLIANCE_MASK | SKYBORNE_A, ALLIANCE_MASK) else 0

    def meant_for(qid, t):
        """Races a class quest is meant for when anyone may take it but only some races are sent
        to it (the level 30 warrior armour quests, for example): 0 when that isn't the case."""
        if ally_mask(t) or not led_by.get(qid):
            return 0
        masks = [ally_mask(quests.get(b)) for b in led_by[qid]]
        if not all(masks):
            return 0
        union = 0
        for m in masks:
            union |= m
        return union if union not in (ALLIANCE_MASK | SKYBORNE_A, ALLIANCE_MASK) else 0

    def zone_of_area(a):
        """The scored zone an area belongs to (walking up from sub-areas), or None."""
        guard = 0
        while a and guard < 6:
            if a in area_to_zone:
                return area_to_zone[a]
            a = PARENT.get(a)
            guard += 1
        return None

    # Typical XP per quest level, for the few quests with no XP data.
    by_lvl = {}
    for qid, (lvl, xp) in xpdb.items():
        by_lvl.setdefault(lvl, []).append(xp)
    typical_xp = {lvl: int(statistics.median(v)) for lvl, v in by_lvl.items()}

    def spot(area, spawns):
        """(area, (x, y)) for an NPC or object: its home area if it spawns there, else a scored zone."""
        # -1,-1 means "somewhere inside an instance": no point on the map.
        spawns = {a: c for a, c in (spawns or {}).items() if min(arr(c)[:2] or [-1]) >= 0}
        if area in spawns:
            return area, tuple(arr(spawns[area])[:2])
        for a in spawns:
            if zone_of_area(a):
                return a, tuple(arr(spawns[a])[:2])
        for a in spawns:
            return a, tuple(arr(spawns[a])[:2])
        return area, None

    def giver_of(t):
        """(giver name, area id where you pick it up, (x, y)) for a quest row, or None if only
        enemies of the Alliance hand it out."""
        starts = t.get(2) or {}
        best, hostile = None, False
        for nid in arr(starts.get(1)):
            npc = npcs.get(nid)
            if not npc:
                continue
            if npc.get(13) and "A" not in npc[13]:
                hostile = True  # quest giver hostile to Alliance
                continue
            area, at = spot(npc.get(9), npc.get(7))
            g = (npc.get(1) or "", area, at or None)
            if g[2] and zone_of_area(area):
                return g
            if best is None or (not best[2] and g[2]):
                best = g
        if best:
            return best
        for oid in arr(starts.get(2)):
            obj = objects.get(oid)
            if obj:
                area, at = spot(obj.get(5), obj.get(4))
                return obj.get(1) or "", area, at or None
        if arr(starts.get(3)):
            return "(item)", None, None
        return None if hostile else ("", None, None)

    def other_givers(t, g):
        """Friendly quest givers for the same quest in other places (class trainers in each capital),
        as (name, area id, (x, y)). The addon picks the one in the player's own starting area or capital."""
        out, seen = [], {g[1]} if g else set()
        for nid in arr((t.get(2) or {}).get(1)):
            npc = npcs.get(nid)
            if not npc or (npc.get(13) and "A" not in npc[13]):
                continue
            area, at = spot(npc.get(9), npc.get(7))
            if at and area not in seen and AREA_MAP.get(area):
                seen.add(area)
                out.append((npc.get(1) or "", area, at))
        return out

    def usable(qid, t):
        if qid in blacklist or not t.get(1) or JUNK.search(t[1]):
            return False
        if qid not in raw_ids and qid not in xpdb:
            # Added for Forever but nobody has been seen getting XP from it (riding quests, Season of
            # Discovery leftovers, quests not in the game yet): don't send anyone after it.
            return False
        races = t.get(6) or 0
        if races and not (races & (ALLIANCE_MASK | SKYBORNE_A)):
            return False
        # Special flag 1 = repeatable. Flag 2 only means an objective is completed by exploring or a
        # script (The Master's Glaive, Bashal'Aran...), so those stay; world event quests have their
        # own (negative) quest sorts and are never scored.
        if (t.get(24) or 0) & 1 or t.get(18) or t.get(30) or t.get(31) or t.get(35):
            return False  # repeatable / profession / spell-gated
        return tags.get(qid) not in ("raid", "pvp")

    def level_of(qid, t):
        return int(t.get(5) or xpdb.get(qid, (0, 0))[0] or 0)

    def rep_of(v):
        if not v or not v.get(1):
            return None
        faction, value = int(v[1]), int(v.get(2) or 0)
        if value > 0 or faction in BELOW_NEUTRAL:
            return faction, value
        return None

    missing_xp = [0]
    used_factions = set()

    def record(qid, t, g):
        races = t.get(6) or 0
        ally = races & (ALLIANCE_MASK | SKYBORNE_A)
        race_mask = ally if races and ally != (ALLIANCE_MASK | SKYBORNE_A) and ally != ALLIANCE_MASK else 0
        qlvl = level_of(qid, t)
        xp = xpdb.get(qid, (0, 0))[1]
        if not xp:
            missing_xp[0] += 1
            xp = typical_xp.get(qlvl, 0)
        # Quests that stop being available once another is done or in progress.
        excl = arr(t.get(16)) + ([int(t[22])] if t.get(22) else []) + ([int(t[27])] if t.get(27) else [])
        excl = [x for i, x in enumerate(excl) if x != qid and x not in excl[:i]]
        pre_all = []
        for p in arr(t.get(12)):
            # A negative id must be done itself; otherwise doing one of its alternatives also counts.
            alts = [] if p < 0 else [x for x in arr((quests.get(p) or {}).get(16)) if x != p]
            pre_all.append([abs(p)] + alts if alts else abs(p))
        d = dict(id=qid, name=t.get(1) or "", lvl=qlvl, req=int(t.get(4) or 0), xp=xp, cls=int(t.get(7) or 0),
                 races=race_mask, pre=arr(t.get(13)), preAll=pre_all, excl=excl, tag=tags.get(qid),
                 giver=g[0] if g else None, at=g[2] if g else None, area=g[1] if g else None,
                 maxLvl=int(t.get(32) or 0), parent=int(t.get(25) or 0), untilDone=int(t.get(33) or 0),
                 disabledBy=int(t.get(36) or 0), startWith=int(t.get(34) or 0),
                 rep=rep_of(t.get(19)), repMax=rep_of(t.get(20)))
        for r in (d["rep"], d["repMax"]):
            if r:
                used_factions.add(r[0])
        return d

    # ---- Every scored zone, plus dungeon and class quests ---------------------------------
    by_zone = {z[0]: [] for z in cfg["zones"]}
    dungeon_quests, class_quests = [], []
    unscored = collections.Counter()

    for qid, t in quests.items():
        if not usable(qid, t):
            continue
        qlvl = level_of(qid, t)
        if qlvl <= 0 or qlvl > 63:
            continue
        g = giver_of(t)
        if g is None:
            continue
        sort = int(t.get(17) or 0)
        dungeon = dungeons.get(sort)
        if dungeon and dungeon[0] in RAIDS_AND_BATTLEGROUNDS:
            continue
        if dungeon or tags.get(qid) == "dungeon":
            # Dungeon quests are listed by level, not by zone: you pick them up all over the place.
            d = record(qid, t, g)
            d["tag"] = "dungeon"
            d["dungeon"] = dungeon[0] if dungeon else "Dungeon"
            d["where"] = area_names.get(g[1]) or ""
            dungeon_quests.append(d)
            continue
        if sort in CLASS_SORTS:
            d = record(qid, t, g)
            d["cls"] = d["cls"] or CLASS_SORTS[sort]
            d["where"] = area_names.get(g[1]) or ""
            d["alt"] = other_givers(t, g)
            d["forRaces"] = meant_for(qid, t)
            class_quests.append(d)
            continue
        # Quests with no category yet (many Forever-only ones) belong where you pick them up, and so do
        # city quests handed out in a zone (The Missing Diplomat in Duskwood, for example).
        area = sort if sort > 0 else (g[1] if sort == 0 else None)
        zone = zone_of_area(area) or (zone_of_area(g[1]) if sort > 0 else None)
        if not zone:
            if sort >= 0 and (xpdb.get(qid) or (0, 0))[1]:
                unscored[area_names.get(area) or ("area %s" % area)] += xpdb[qid][1]
            continue
        d = record(qid, t, g)
        giver_zone = zone_of_area(g[1])
        if g[1] and giver_zone is not zone:
            d["where"] = area_names.get(g[1]) or ""  # picked up somewhere else (often a city)
        by_zone[zone[0]].append(d)

    # Many Forever-only quests have no minimum level on record: use what similar quests there need.
    gaps = collections.Counter()
    for lst in list(by_zone.values()) + [dungeon_quests, class_quests]:
        known = {}
        for d in lst:
            if d["req"] and d["lvl"] >= 10:
                known.setdefault(d["lvl"], []).append(d["req"])
                gaps[d["lvl"] - d["req"]] += 1
        for d in lst:
            if not d["req"] and d["lvl"] >= 10:
                d["req"] = min(known[d["lvl"]]) if d["lvl"] in known else max(1, d["lvl"] - 5)
                d["reqGuess"] = True

    # ---- Starting zones from RestedXP ----------------------------------------------
    starters = set(cfg["starterZones"])
    rxp = []
    for f in extract_rxp.FILES:
        text = open(os.path.join(rxp_dir, "Guides/forever", f), encoding="utf-8").read()
        for blk in extract_rxp.BLOCK.findall(text):
            g = extract_rxp.parse_block(blk)
            if g and g["zone"] in starters:
                g["races"] = SOURCE_RACES[f]
                rxp.append(g)

    lines = ["-- AUTO GENERATED by tools/build_data.py. Do not edit by hand.",
             "-- Starting-zone routes derived from RestedXP Forever guides, https://github.com/RestedXP/RXPGuides",
             "-- (c) RestedXP, CC BY-NC-SA 4.0. Quest names and XP checked against QuestieDB (GPLv3).",
             "local _, ns = ...",
             "ns.route = {"]
    for g in rxp:
        lines.append("  { min=%d, max=%d, zone=%s, races=%s, cond=%s, quests={" % (
            g["min"], g["max"], lua_str(g["zone"]),
            lua_str(g["races"]) if g["races"] else "nil",
            lua_str(g["guideCond"]) if g["guideCond"] else "nil"))
        for x in g["quests"]:
            qd = quests.get(x["id"])
            name = (qd.get(1) if qd else None) or x["name"] or ("Quest %d" % x["id"])
            lvl = level_of(x["id"], qd) if qd else 0
            parts = ["id=%d" % x["id"], "name=%s" % lua_str(name), "lvl=%d" % lvl]
            xp = xpdb.get(x["id"], (0, 0))[1]
            if xp:
                parts.append("xp=%d" % xp)
            if x.get("cond"):
                parts.append("cond=%s" % lua_str(x["cond"]))
            if qd and ally_mask(qd):
                parts.append("races=%d" % ally_mask(qd))  # only some races can take it
            gv = giver_of(qd) if qd else None
            if gv and gv[2] and AREA_MAP.get(gv[1]):
                # Prefer QuestieDB's quest giver location (map percentages).
                parts.append("giver=%s" % lua_str(gv[0]))
                parts.append("at={%s,%.1f,%.1f}" % (lua_str(area_names.get(gv[1], "")), gv[2][0], gv[2][1]))
                parts.append("m=%d" % AREA_MAP[gv[1]])
            elif x.get("start"):
                z, xx, yy = x["start"]
                parts.append("at={%s,%.1f,%.1f}" % (lua_str(z), xx, yy))
                if NAME_MAP.get(z):
                    parts.append("m=%d" % NAME_MAP[z])
            lines.append("    {%s}," % ", ".join(parts))
        lines.append("  }},")
    lines.append("}")
    open(os.path.join(out_dir, "Data_StartRoute.lua"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    old = os.path.join(out_dir, "Data_Route1to21.lua")
    if os.path.exists(old):
        os.remove(old)

    # ---- Chains: every earlier quest that a listed quest needs ---------------------------
    def flat(pre_all):
        return [p[0] if isinstance(p, list) else p for p in pre_all]

    listed = [d for z in by_zone.values() for d in z] + dungeon_quests + class_quests
    chain, todo = {}, [i for d in listed for i in d["pre"] + flat(d["preAll"])]
    while todo:
        qid = todo.pop()
        if qid in chain:
            continue
        t = quests.get(qid)
        if t is None:
            continue
        g = giver_of(t) or ("", None, None)
        d = record(qid, t, g)
        if not d["req"] and d["lvl"] >= 10:
            d["req"] = max(1, d["lvl"] - 5)
        sort = int(t.get(17) or 0)
        d["where"] = area_names.get(g[1]) or area_names.get(sort) or ""
        if dungeons.get(sort):
            d["tag"] = "dungeon"
        if sort in CLASS_SORTS:
            d["alt"] = other_givers(t, g)
            d["forRaces"] = meant_for(qid, t)
        chain[qid] = d
        todo += d["pre"] + flat(d["preAll"])

    def pre_all_lua(pre_all):
        return "{" + ",".join(lua_list(p) if isinstance(p, list) else str(p) for p in pre_all) + "}"

    def common_parts(d):
        parts = []
        for key in ("cls", "races", "forRaces", "maxLvl", "parent", "untilDone", "disabledBy", "startWith"):
            if d.get(key):
                parts.append("%s=%d" % (key, d[key]))
        if d["pre"]:
            parts.append("pre=%s" % lua_list(d["pre"]))
        if d["preAll"]:
            parts.append("preAll=%s" % pre_all_lua(d["preAll"]))
        for key in ("rep", "repMax"):
            if d.get(key):
                parts.append("%s={%d,%d}" % ((key,) + tuple(d[key])))
        return parts

    def alt_lua(d):
        """Other places to pick the quest up: {{g=giver, w=area, at={x,y}, m=map}, ...}"""
        return "alt={%s}" % ",".join("{g=%s, w=%s, at={%.1f,%.1f}, m=%d}" % (
            lua_str(n), lua_str(area_names.get(a) or ""), at[0], at[1], AREA_MAP[a]) for n, a, at in d["alt"])

    def quest_line(d, zone_map=None):
        parts = ["id=%d" % d["id"], "name=%s" % lua_str(d["name"]), "lvl=%d" % d["lvl"],
                 "req=%d" % d["req"], "xp=%d" % d["xp"]] + common_parts(d)
        if d["excl"]:
            parts.append("excl=%s" % lua_list(d["excl"]))
        for key in ("tag", "dungeon", "giver", "where"):
            if d.get(key):
                parts.append("%s=%s" % (key, lua_str(d[key])))
        if d["at"]:
            parts.append("at={%.1f,%.1f}" % d["at"])
            m = AREA_MAP.get(d.get("area"))
            if m and m != zone_map:
                parts.append("m=%d" % m)  # giver is on another map than the zone
        if d.get("alt"):
            parts.append(alt_lua(d))
        return "    {%s}," % ", ".join(parts)

    lines = ["-- AUTO GENERATED by tools/build_data.py. Do not edit by hand.",
             "-- Quest data: QuestieDB (https://github.com/Questie/QuestieDB) with its Forever corrections,",
             "-- and Questie corrections, GPLv3.",
             "local _, ns = ...",
             "ns.zones = {"]
    total = 0
    for zname, area, uimap, cont in cfg["zones"]:
        lst = sorted(by_zone[zname], key=lambda d: (d["lvl"], d["id"]))
        total += len(lst)
        lines.append("  { name=%s, map=%d, cont=%s, quests={" % (lua_str(zname), uimap, lua_str(cont)))
        for d in lst:
            lines.append(quest_line(d, uimap))
        lines.append("  }},")
    lines.append("}")
    lines.append("ns.dungeonQuests = {")
    for d in sorted(dungeon_quests, key=lambda d: (d["lvl"], d["dungeon"], d["id"])):
        lines.append(quest_line(d))
    lines.append("}")
    lines.append("ns.classQuests = {")
    for d in sorted(class_quests, key=lambda d: (d["lvl"], d["id"])):
        lines.append(quest_line(d))
    lines.append("}")
    lines.append("-- Earlier quests in chains: where each one starts.")
    lines.append("ns.chain = {")
    for qid in sorted(chain):
        d = chain[qid]
        parts = ["name=%s" % lua_str(d["name"] or ""), "lvl=%d" % d["lvl"], "req=%d" % d["req"],
                 "xp=%d" % d["xp"]] + common_parts(d)
        for key in ("tag", "giver", "where"):
            if d.get(key):
                parts.append("%s=%s" % (key, lua_str(d[key])))
        if d["at"]:
            parts.append("at={%.1f,%.1f}" % d["at"])
            if AREA_MAP.get(d.get("area")):
                parts.append("m=%d" % AREA_MAP[d["area"]])
        if d.get("alt"):
            parts.append(alt_lua(d))
        lines.append("  [%d] = {%s}," % (qid, ", ".join(parts)))
    lines.append("}")
    # What a normal quest of each level gives, to judge whether a chain is worth unlocking.
    solo = collections.defaultdict(list)
    for lst in by_zone.values():
        for d in lst:
            if not d["tag"] and d["xp"] and d["id"] in xpdb:
                solo[d["lvl"]].append(d["xp"])
    p75 = {lvl: sorted(v)[int(len(v) * 0.75)] for lvl, v in solo.items() if v}  # a full quest, not a "go talk to" one
    typical, top = {}, 0
    for lvl in range(1, 61):
        near = [p75[x] for x in range(lvl - 2, lvl + 3) if x in p75]
        if near:
            top = max(top, int(statistics.median(near)))
        typical[lvl] = top
    lines.append("-- XP of a normal full quest of each level (smoothed 75th percentile).")
    lines.append("ns.typicalXP = {%s}" % ", ".join("[%d]=%d" % (lvl, typical[lvl]) for lvl in sorted(typical) if typical[lvl]))
    lines.append("ns.factions = {")
    for f in sorted(used_factions):
        lines.append("  [%d] = %s," % (f, lua_str(FACTIONS.get(f, "faction %d" % f))))
    lines.append("}")
    open(os.path.join(out_dir, "Data_Zones.lua"), "w", encoding="utf-8").write("\n".join(lines) + "\n")

    print("starter sections:", len(rxp), " zone quests:", total, " dungeon:", len(dungeon_quests),
          " class:", len(class_quests), " chain quests:", len(chain), " estimated xp:", missing_xp[0],
          " guessed min level:", sum(1 for z in by_zone.values() for d in z if d.get("reqGuess")),
          " tagged:", sum(1 for z in by_zone.values() for d in z if d["tag"]))
    for zname, *_ in cfg["zones"]:
        lst = by_zone[zname]
        solo = [d for d in lst if not d["tag"]]
        lv = sorted(d["lvl"] for d in solo) or [0]
        print(f"  {zname:<24}{len(lst):>4} quests  lvl {lv[len(lv)//10]}-{lv[-1 - len(lv)//10]}  solo xp {sum(d['xp'] for d in solo):>7}")
    print("not scored (Alliance quest XP by area):",
          ", ".join(f"{a} {x}" for a, x in unscored.most_common(12)))
    unknown = [f for f in used_factions if f not in FACTIONS]
    if unknown:
        print("factions without a name:", unknown)


if __name__ == "__main__":
    main(*sys.argv[1:5])
