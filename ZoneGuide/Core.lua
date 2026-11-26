-- ZoneGuide core: scores zones for this character and decides "stay" or "time to move".
local _, ns = ...

-- Tuning ------------------------------------------------------------------------------
-- Zone value is measured in "levels": how far the XP from that zone's solo quests would take you
-- from where you are now. A quest only counts once you'd be within MAX_ABOVE levels of it, so
-- quests further up count only when the easier quests there would level you close enough.
ns.FINISH_ZONE = true    -- true: stay until your zone is done. false: leave as soon as another zone is clearly better
ns.DONE_VALUE = 0.15     -- your zone is "done" when nothing is left to pick up, or less than this many levels of XP
ns.MIN_OPEN_BEST = 3     -- only send you to a zone with at least this many quests you can pick up now
ns.MIN_OPEN = 3          -- (FINISH_ZONE = false only) leave once fewer quests than this are left to pick up
ns.MIN_OPEN_STAY = 3     -- only say "stay" while your zone has at least this many quests left (counting later chain steps)
ns.MAX_ABOVE = 2         -- a quest counts towards a zone only from the level where it's at most this far above you
ns.SWITCH_COST = 0.3     -- levels of value another zone must beat yours by before moving is worth it
ns.TRAVEL_PENALTY = 0.3  -- extra margin when that zone is on the other continent
ns.ALMOST_LEVEL = 0.85   -- this far into a level, stay if your zone has quests that unlock at the next level
ns.LOW_XP_DIFF = 7       -- quests this many levels below you give 60% XP or less: listed after the rest
ns.GREY_DIFF = 10        -- quests this many levels below you give 10% XP: left off the list
ns.STAR_QUESTS = 3       -- a greyed-out quest is "worth unlocking" when it and the quests before it give this many
                         -- normal quests' worth of XP (and at least one normal quest's worth per step)
ns.STAR_MAX_STEPS = 10   -- ...through no more than this many earlier quests
ns.BAR_FULL = 3          -- a full bar means 3 or more levels of quests left

local CLASS_BITS = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16,
    SHAMAN = 64, MAGE = 128, WARLOCK = 256, DRUID = 1024,
}
local RACE_BITS = { Human = 1, Dwarf = 4, NightElf = 8, Gnome = 64, Skyborne = 4294967296 }
local CONTINENT = { [1414] = "K", [1415] = "EK" }
-- Each race's starting zone and capital. Class trainers there hand out that race's own version of
-- many low-level class quests.
local HOME = {
    Human = { ["Elwynn Forest"] = true, ["Stormwind City"] = true },
    Dwarf = { ["Dun Morogh"] = true, ["Ironforge"] = true },
    Gnome = { ["Dun Morogh"] = true, ["Ironforge"] = true },
    NightElf = { ["Teldrassil"] = true, ["Darnassus"] = true },
    Skyborne = { ["Zephras Isle"] = true, ["Stormwind City"] = true },
}
local ANY_HOME = {}
for _, areas in pairs(HOME) do
    for area in pairs(areas) do ANY_HOME[area] = true end
end
local RACE_VARIANT_LEVEL = 20  -- up to here, a class quest from another race's home has a version at yours
-- Reputations that start below Neutral until you meet them.
local BELOW_NEUTRAL = { [87] = true, [576] = true, [910] = true }
local STANDINGS = { { 42000, "Exalted" }, { 21000, "Revered" }, { 9000, "Honored" }, { 3000, "Friendly" },
                    { 0, "Neutral" }, { -3000, "Unfriendly" }, { -6000, "Hostile" } }

-- Tokens in guide filters that are about the game version rather than the player.
local ALWAYS_TRUE = { CLASSIC = true, FOREVER = true, ERA = true }

ns.player = {}
ns.turnedIn = {}
ns.factions = ns.factions or {}

function ns.UpdatePlayer()
    local p = ns.player
    p.level = UnitLevel("player") or 1
    p.class = select(2, UnitClass("player"))
    p.race = select(2, UnitRace("player"))
    p.faction = UnitFactionGroup("player")
    p.xpMax = (UnitXPMax and UnitXPMax("player")) or 0
    if p.xpMax <= 0 then p.xpMax = 1000 end
    p.xp = (UnitXP and UnitXP("player")) or 0
end

-- Quest state -----------------------------------------------------------------------

local IsFlagged = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted

function ns.IsCompleted(id)
    return ns.turnedIn[id] or (IsFlagged and IsFlagged(id)) or false
end

function ns.IsOnQuest(id)
    if C_QuestLog and C_QuestLog.IsOnQuest then
        return C_QuestLog.IsOnQuest(id) and true or false
    end
    return GetQuestLogIndexByID and (GetQuestLogIndexByID(id) or 0) > 0
end

local function hasBit(mask, bit)
    return bit and (mask % (bit * 2)) >= bit
end

-- A required earlier quest: an id, or a list of ids where any one will do.
local function doneAny(p)
    if type(p) == "table" then
        for _, id in ipairs(p) do
            if ns.IsCompleted(id) then return true end
        end
        return false
    end
    return ns.IsCompleted(p)
end

-- Reputation -----------------------------------------------------------------------

local repCache = {}
local function reputation(faction)
    if repCache[faction] == nil then
        local value
        if C_Reputation and C_Reputation.GetFactionDataByID then
            local d = C_Reputation.GetFactionDataByID(faction)
            value = d and d.name and d.currentStanding
        elseif GetFactionInfoByID then
            local name, _, _, _, _, barValue = GetFactionInfoByID(faction)
            value = name and barValue
        end
        repCache[faction] = value or (BELOW_NEUTRAL[faction] and -36000 or 0)
    end
    return repCache[faction]
end

local function standingName(value)
    for _, s in ipairs(STANDINGS) do
        if value >= s[1] then return s[2] end
    end
    return "Hated"
end

-- Guide filters: "A B/C !D" means (A and B) or (C and not D); "x && y" means both.
local function tokenMatches(tok)
    local p = ns.player
    local level = tonumber(tok)
    if level then return p.level >= level end
    local up = tok:upper()
    if ALWAYS_TRUE[up] then return true end
    return up == p.class or tok == p.race or tok == p.faction
end

local function evalSimple(expr)
    for group in expr:gmatch("[^/]+") do
        local ok = true
        for tok in group:gmatch("!?[%w]+") do
            local negate = tok:sub(1, 1) == "!"
            local name = negate and tok:sub(2) or tok
            if tokenMatches(name) == negate then ok = false break end
        end
        if ok then return true end
    end
    return false
end

local cache = {}
function ns.Applies(expr)
    if not expr then return true end
    local p = ns.player
    local key = expr .. "|" .. (p.level or 0) .. (p.race or "") .. (p.class or "")
    if cache[key] == nil then
        local ok = true
        for part in (expr .. "&&"):gmatch("(.-)&&") do
            if part:find("%S") and not evalSimple(part) then ok = false break end
        end
        cache[key] = ok
    end
    return cache[key]
end

-- Quest value -----------------------------------------------------------------------

-- Quest XP in Classic drops once you out-level a quest by more than 5.
local function levelMultiplier(diff)
    if diff <= 5 then return 1 elseif diff == 6 then return 0.8 elseif diff == 7 then return 0.6
    elseif diff == 8 then return 0.4 elseif diff == 9 then return 0.2 end
    return 0.1
end

-- What a quest's XP is worth to you at your level, whether or not you can take it yet.
local function potential(q)
    return (q.xp or 0) * levelMultiplier(ns.player.level - (q.lvl or ns.player.level))
end

-- XP from each level to the next (Classic). Only the ratios are used, scaled to what the game
-- says your current level needs.
local XP_CURVE = { 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900,
    14400, 16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400,
    44300, 47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000,
    106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900,
    180800, 187900, 195000, 202300, 209800 }

local function xpToNext(lvl)
    local p = ns.player
    if not XP_CURVE[lvl] or not XP_CURVE[p.level] then return p.xpMax end
    return p.xpMax * XP_CURVE[lvl] / XP_CURVE[p.level]
end

-- How many levels of quest XP these quests ({ {from = level, xp = }, ... }) would give you, how
-- many of them you'd get to, and the level you'd reach. Each one counts only from the level where
-- you'd be close enough to do it, so the easier quests have to get you there first; quests that
-- stay out of reach count for nothing. Only quest XP counts: what mobs give varies too much (drop
-- rates aren't known) to predict.
local function reachable(quests)
    table.sort(quests, function(a, b) return a.from < b.from end)
    local p = ns.player
    local lvl, have, n = p.level, p.xp, 0
    for _, c in ipairs(quests) do
        if c.from > lvl then break end
        have, n = have + c.xp, n + 1
        while lvl < 60 and have >= xpToNext(lvl) do
            have, lvl = have - xpToNext(lvl), lvl + 1
        end
    end
    local after = lvl >= 60 and 60 or lvl + have / xpToNext(lvl)
    return math.max(0, after - (p.level + p.xp / p.xpMax)), n, lvl
end

-- Gold from turning in the first n of these quests (anything with an id): the copper known so far,
-- and the quests whose gold the game hasn't loaded yet. nil when the game can't tell.
local function goldOf(quests, n)
    if not ns.QuestMoney then return nil end
    local copper, missing = 0, {}
    for i = 1, n do
        local id = quests[i].id
        local m = ns.QuestMoney(id)
        if m then copper = copper + m else missing[#missing + 1] = id end
    end
    return copper, missing
end

local function anyDone(list)
    for _, id in ipairs(list) do
        if ns.IsCompleted(id) or ns.IsOnQuest(id) then return true end
    end
    return false
end

-- Could this character still do this quest at some point?
local function stillOpen(q)
    if ns.IsCompleted(q.id) then return false end
    if q.cls and not hasBit(q.cls, CLASS_BITS[ns.player.class]) then return false end
    if q.races and not hasBit(q.races, RACE_BITS[ns.player.race]) then return false end
    if q.excl and anyDone(q.excl) then return false end
    if q.maxLvl and ns.player.level > q.maxLvl then return false end
    if q.untilDone and ns.IsCompleted(q.untilDone) then return false end
    if q.parent and ns.IsCompleted(q.parent) and not ns.IsOnQuest(q.id) then return false end
    if q.repMax and reputation(q.repMax[1]) >= q.repMax[2] then return false end
    return true
end

-- What's stopping you from picking it up right now (nil = nothing). With anyLevel, what would
-- still stop you once you're high enough level.
function ns.Blocker(q, anyLevel)
    local L = ns.player.level
    if ns.IsOnQuest(q.id) then return nil end
    if not anyLevel and (q.req or 0) > L then return "level " .. q.req end
    if q.giver == "(item)" then return "starts from a drop" end
    if not q.giver or q.giver == "" then return "start unknown" end
    if q.pre then
        local ok = false
        for _, id in ipairs(q.pre) do if ns.IsCompleted(id) then ok = true break end end
        if not ok then return "needs an earlier quest" end
    end
    if q.preAll then
        for _, p in ipairs(q.preAll) do
            if not doneAny(p) then return "needs an earlier quest" end
        end
    end
    if q.startWith and not (ns.IsCompleted(q.startWith) or ns.IsOnQuest(q.startWith)) then
        return "needs an earlier quest"
    end
    if q.parent and not ns.IsOnQuest(q.parent) then return "comes with another quest" end
    if q.rep and reputation(q.rep[1]) < q.rep[2] then
        return "needs " .. standingName(q.rep[2]) .. " with " .. (ns.factions[q.rep[1]] or "a faction")
    end
    if q.disabledBy and ns.IsOnQuest(q.disabledBy) then return "after your current quest" end
    return nil
end

-- Could you pick this quest up (or have you), level aside?
local function obtainable(q)
    if ns.IsOnQuest(q.id) then return true end
    if q.giver == "(item)" or not q.giver or q.giver == "" then return false end  -- random drop, or start unknown
    if q.parent and not ns.IsOnQuest(q.parent) then return false end           -- part of a quest you don't have
    if q.rep and reputation(q.rep[1]) < q.rep[2] then return false end         -- reputation you don't have
    return true
end

-- XP this quest is worth to you now: nothing while it's more than MAX_ABOVE levels above you.
function ns.Worth(q)
    local L = ns.player.level
    if q.tag or q.req > L + 2 or q.lvl > L + ns.MAX_ABOVE or not obtainable(q) then return 0 end
    local mult = levelMultiplier(L - q.lvl)
    if q.req > L then mult = mult * 0.5 end        -- not unlocked yet
    return (q.xp or 0) * mult
end

-- Chains ---------------------------------------------------------------------------------

local index, zoneOf, mapOf
local function info(id)
    if not index then
        index, zoneOf, mapOf = {}, {}, {}
        for _, z in ipairs(ns.zones) do
            for _, q in ipairs(z.quests) do index[q.id] = q; zoneOf[q.id] = z.name; mapOf[q.id] = z.map end
        end
        for _, q in ipairs(ns.dungeonQuests) do index[q.id] = q end
        for _, q in ipairs(ns.classQuests or {}) do index[q.id] = q end
    end
    return index[id] or ns.chain[id]
end

local function suitable(q)
    if q.cls and not hasBit(q.cls, CLASS_BITS[ns.player.class]) then return false end
    if q.races and not hasBit(q.races, RACE_BITS[ns.player.race]) then return false end
    return true
end

local function atHome(area)
    local home = HOME[ns.player.race]
    return (home and area and home[area]) or false
end

-- Some class quests are handed out by the class trainer in each capital: show the one in your
-- race's home (the data lists the others under alt).
local localizedFor
local function localizePickups()
    if localizedFor == ns.player.race then return end
    localizedFor = ns.player.race
    local function pick(q)
        if not q.alt then return end
        q.first = q.first or { g = q.giver, w = q.where, at = q.at, m = q.m }
        local best = q.first
        if not atHome(best.w) then
            for _, a in ipairs(q.alt) do
                if atHome(a.w) then best = a break end
            end
        end
        q.giver, q.where, q.at, q.m = best.g, best.w, best.at, best.m
    end
    for _, q in ipairs(ns.classQuests or {}) do pick(q) end
    for _, q in pairs(ns.chain or {}) do pick(q) end
end

local function addSteps(id, steps, seen, depth)
    if seen[id] or depth > 30 or ns.IsCompleted(id) then return end
    seen[id] = true
    local q = info(id)
    if not q then return end
    ns.AddPrereqSteps(q, steps, seen, depth + 1)
    steps[#steps + 1] = { id = id, q = q, inLog = ns.IsOnQuest(id), zone = q.where or zoneOf[id], map = q.m or mapOf[id] }
end

function ns.AddPrereqSteps(q, steps, seen, depth)
    if q.preAll then
        for _, p in ipairs(q.preAll) do
            if not doneAny(p) then addSteps(type(p) == "table" and p[1] or p, steps, seen, depth) end
        end
    end
    if q.startWith and not ns.IsOnQuest(q.startWith) then addSteps(q.startWith, steps, seen, depth) end
    if q.pre then
        for _, p in ipairs(q.pre) do
            if ns.IsCompleted(p) then return end
        end
        -- Any one of these unlocks it: the one in your log, else one that fits your class and race,
        -- picked up in your race's home if there is one.
        for _, p in ipairs(q.pre) do
            if ns.IsOnQuest(p) then addSteps(p, steps, seen, depth) return end
        end
        local first
        for _, p in ipairs(q.pre) do
            local pq = info(p)
            if pq and suitable(pq) then
                if atHome(pq.where or zoneOf[p]) then addSteps(p, steps, seen, depth) return end
                first = first or p
            end
        end
        if first then addSteps(first, steps, seen, depth) end
    end
end

-- A starting-route quest: can you pick it up now, as far as the quest data knows?
function ns.CanPickUp(q)
    local rec = info(q.id)
    return not rec or ns.Blocker(rec) == nil
end

-- The unfinished quests you need before this one, earliest first.
function ns.ChainSteps(q)
    local steps = {}
    ns.AddPrereqSteps(q, steps, { [q.id] = true }, 0)
    return steps
end

-- Does unlocking this quest mean going somewhere else (or doing a group quest, or finding a drop)?
-- Steps picked up where the quest itself is picked up don't count as going somewhere else.
local function leavesZone(steps, zoneName, pickup)
    if #steps == 0 then return true end  -- the quests before it aren't known
    for _, s in ipairs(steps) do
        local q = s.q
        if not s.inLog and (q.tag or q.giver == "(item)" or (s.zone and s.zone ~= zoneName and s.zone ~= pickup)) then
            return true
        end
    end
    return false
end

-- A greyed-out quest is "worth unlocking" when it and the quests you still need before it add up
-- to at least STAR_QUESTS normal quests' worth of XP at your level, and the chain gives at least a
-- normal quest's XP per step (so it beats ordinary questing). Long chains and chains through
-- several group quests don't count: that's raid prep, not levelling.
local function markStar(item)
    local q, b, L = item.q, item.blocker, ns.player.level
    if not b or (q.lvl or 0) > L + 4 then return end
    local total, n, group = potential(q), 0, 0
    if b == "needs an earlier quest" then
        item.steps = item.steps or ns.ChainSteps(q)
        if #item.steps == 0 then return end
        for _, s in ipairs(item.steps) do
            if (s.q.req or 0) > L + 2 then return end  -- the chain needs a higher level first
            total = total + potential(s.q)
            n = n + 1
            if s.q.tag then group = group + 1 end
        end
    elseif b == "starts from a drop" then
        -- worth keeping the item if it drops
    elseif not (b:find("^level ") and q.req <= L + 2) then
        return
    end
    item.chainXP, item.chainLen = total, n
    local normal = (ns.typicalXP and ns.typicalXP[math.min(L, 60)]) or 0
    item.star = normal > 0 and total >= ns.STAR_QUESTS * normal and total >= normal * (n + 1)
        and n <= ns.STAR_MAX_STEPS and group <= 1 or nil
    item.groupSteps = group
end

-- A locked quest that is itself a step towards another locked quest in the same list is shown
-- inside that quest's chain instead of on its own line, and doesn't get its own star (the later
-- quest counts its XP already).
local function chainEnds(items)
    local isStep = {}
    for _, item in ipairs(items) do
        for _, s in ipairs(item.steps or {}) do isStep[s.id] = true end
    end
    for _, item in ipairs(items) do
        if item.blocker and isStep[item.q.id] then
            item.mid, item.star = true, nil
        end
    end
    return items
end

-- Where am I? ---------------------------------------------------------------------------

local function currentLocation()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil, nil, GetRealZoneText and GetRealZoneText() end
    local id = C_Map.GetBestMapForUnit("player")
    local zoneMap, cont
    local guard = 0
    while id and guard < 6 do
        guard = guard + 1
        for _, z in ipairs(ns.zones) do
            if z.map == id and not zoneMap then zoneMap = id end
        end
        if CONTINENT[id] then cont = CONTINENT[id] break end
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
        id = info and info.parentMapID
        if id == 0 then id = nil end
    end
    return zoneMap, cont, GetRealZoneText and GetRealZoneText()
end

-- The plan ------------------------------------------------------------------------------

local function routeEntry(s)
    local list, xp = {}, 0
    local mine = RACE_BITS[ns.player.race]
    for _, q in ipairs(s.quests) do
        if ns.Applies(q.cond) and (not q.races or hasBit(q.races, mine)) and not ns.IsCompleted(q.id) then
            list[#list + 1] = q
            xp = xp + (q.xp or 0)
        end
    end
    if #list > 0 then
        local money, moneyMissing = goldOf(list, #list)
        return { name = s.zone, value = xp / ns.player.xpMax, quests = list, route = true,
                 money = money, moneyMissing = moneyMissing }
    end
end

-- The map a starting-route section is on: the one most of its quest givers are on.
local function sectionMap(s)
    if s.map == nil then
        local count, best, top = {}, false, 0
        for _, q in ipairs(s.quests) do
            if q.m then
                count[q.m] = (count[q.m] or 0) + 1
                if count[q.m] > top then best, top = q.m, count[q.m] end
            end
        end
        s.map = best
    end
    return s.map
end

-- Every map you're on: your zone, and the maps it sits in.
local function mapsHere()
    local maps = {}
    if C_Map and C_Map.GetBestMapForUnit then
        local id, guard = C_Map.GetBestMapForUnit("player"), 0
        while id and id ~= 0 and guard < 6 do
            maps[id] = true
            local mi = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
            id = mi and mi.parentMapID
            guard = guard + 1
        end
    end
    return maps
end

-- The starting-zone route for the starting zone you're in, whatever your race (a dwarf can
-- start out in Elwynn Forest). Anywhere else, your own race's route.
local function starterSection()
    local L = ns.player.level
    local here, inStartZone = mapsHere(), false
    for _, s in ipairs(ns.route) do
        if here[sectionMap(s)] and ns.Applies(s.cond) then
            inStartZone = true
            if L >= s.min and L < s.max then
                local e = routeEntry(s)
                if e then return e end
            end
        end
    end
    -- In a starting zone whose route you've finished (or outgrown): the zones are scored as usual.
    if inStartZone then return nil end
    for _, s in ipairs(ns.route) do
        if L >= s.min and L < s.max and ns.Applies(s.races) and ns.Applies(s.cond) then
            local e = routeEntry(s)
            if e then return e end
        end
    end
end

-- Not counted towards a zone's value, but shown in their own sections.
local function groupItem(q, below, above)
    local L = ns.player.level
    if not stillOpen(q) then return nil end
    local inLog = ns.IsOnQuest(q.id)
    if inLog or (q.req <= L + 2 and q.lvl >= L - (below or 3) and q.lvl <= L + (above or 5)) then
        local item = { q = q, worth = 0, blocker = ns.Blocker(q), inLog = inLog }
        markStar(item)
        return item
    end
end

local function scoreZone(z)
    local L = ns.player.level
    local counted, list, group, open, soon, soonN = {}, {}, {}, 0, 0, 0
    -- The level from which a quest counts: once you can pick it up, and it's no more than
    -- MAX_ABOVE levels above you.
    local function from(q, inLog)
        return math.max(inLog and 0 or q.req, q.lvl - ns.MAX_ABOVE)
    end
    for _, q in ipairs(z.quests) do
        if q.tag then
            group[#group + 1] = groupItem(q)
        elseif stillOpen(q) then
            local inLog = ns.IsOnQuest(q.id)
            local w = ns.Worth(q)
            -- Quests you've out-levelled so far that they give 10% XP aren't worth listing.
            if inLog or (w > 0 and L - q.lvl < ns.GREY_DIFF) then
                local item = { q = q, worth = w, blocker = ns.Blocker(q), inLog = inLog }
                if item.blocker == "needs an earlier quest" then
                    item.steps = ns.ChainSteps(q)
                    -- A chain that starts in another zone (or a dungeon) isn't part of this zone's value.
                    item.away = leavesZone(item.steps, z.name, q.where)
                end
                markStar(item)
                if not item.away and (w > 0 or inLog) then
                    counted[#counted + 1] = { id = q.id, from = from(q, inLog), xp = potential(q) }
                end
                -- "Open" = in your log, or something you can pick up right now that still gives most of its XP.
                if inLog or (w > 0 and item.blocker == nil and L - q.lvl <= 6) then open = open + 1 end
                -- Quests that open up at your next level (and need nothing else).
                if from(q, inLog) == L + 1 and not item.inLog and ns.Blocker(q, true) == nil then
                    soon, soonN = soon + potential(q), soonN + 1
                end
                list[#list + 1] = item
            elseif (q.lvl > L + ns.MAX_ABOVE or q.req > L + 2) and obtainable(q) then
                -- Too far above you for now: it counts once the quests below it get you close enough.
                local b = ns.Blocker(q, true)
                if b == nil or (b == "needs an earlier quest" and not leavesZone(ns.ChainSteps(q), z.name, q.where)) then
                    counted[#counted + 1] = { id = q.id, from = from(q), xp = q.xp or 0 }
                    if b == nil and from(q) == L + 1 then soon, soonN = soon + (q.xp or 0), soonN + 1 end
                end
            end
        end
    end
    local value, left, reached = reachable(counted)
    -- The next quests here that are still out of reach: the level they open up at, and how much
    -- opens up then (or the level after).
    local nextAt, nextXP = counted[left + 1] and counted[left + 1].from, 0
    for i = left + 1, #counted do
        if counted[i].from > nextAt + 1 then break end
        nextXP = nextXP + counted[i].xp
    end
    local money, moneyMissing = goldOf(counted, left)
    return { name = z.name, map = z.map, cont = z.cont, value = value, left = left, reached = reached,
             nextAt = nextAt, nextValue = nextXP / ns.player.xpMax, money = money, moneyMissing = moneyMissing,
             quests = chainEnds(list), group = group, open = open, soon = soon / ns.player.xpMax, soonN = soonN }
end

-- Dungeon quests, wherever they're picked up. A dungeon suits your level when one of its quests
-- does; then all of its quests you can pick up within 2 levels are listed (with their chains), so
-- you can collect them before you go in.
function ns.DungeonQuests()
    local L = ns.player.level
    local function key(q) return (q.dungeon and q.dungeon ~= "Dungeon") and q.dungeon or q.id end
    local active = {}
    for _, q in ipairs(ns.dungeonQuests) do
        if groupItem(q) then active[key(q)] = true end
    end
    local list = {}
    for _, q in ipairs(ns.dungeonQuests) do
        if active[key(q)] then list[#list + 1] = groupItem(q, ns.GREY_DIFF - 1, 60) end
    end
    return chainEnds(list)
end

-- Class quests that suit your level. Many low-level class quests come in one version per race,
-- each picked up in that race's starting zone or capital; you're shown your own race's version.
function ns.ClassQuests()
    localizePickups()
    local list = {}
    for _, q in ipairs(ns.classQuests or {}) do
        local item = groupItem(q, 6)
        if item then
            if item.blocker == "needs an earlier quest" then item.steps = item.steps or ns.ChainSteps(q) end
            item.home = atHome(q.where)
            list[#list + 1] = item
        end
    end
    -- Your home's class quests: their levels, and the quests they lead to.
    local homeLvl, leadsTo = {}, {}
    for _, item in ipairs(list) do
        if item.home then
            homeLvl[item.q.lvl] = true
            for _, id in ipairs(item.q.excl or {}) do leadsTo[id] = true end
        end
    end
    local function foreign(area) return area and ANY_HOME[area] and not atHome(area) end
    local function anotherRacesVersion(item)
        local q = item.q
        if q.races or q.lvl > RACE_VARIANT_LEVEL then return false end
        if not (homeLvl[q.lvl - 1] or homeLvl[q.lvl] or homeLvl[q.lvl + 1]) then return false end
        local origin = item.steps and item.steps[1] and item.steps[1].zone
        if not (foreign(q.where) or foreign(origin)) then return false end
        -- ...unless one of your home's quests sends you there.
        if leadsTo[q.id] then return false end
        for _, s in ipairs(item.steps or {}) do
            if leadsTo[s.id] and not atHome(s.zone) then return false end
        end
        return true
    end
    -- Home quests first, so that of two versions of the same quest, yours is the one kept.
    table.sort(list, function(a, b)
        if a.home ~= b.home then return a.home end
        return a.q.lvl < b.q.lvl or (a.q.lvl == b.q.lvl and a.q.id < b.q.id)
    end)
    local mine = RACE_BITS[ns.player.race]
    local function forOthers(q) return q.forRaces and not hasBit(q.forRaces, mine) end
    local kept, keptOpen = {}, {}
    for _, item in ipairs(list) do
        local q, hide = item.q, false
        if not item.inLog then
            if not item.blocker or item.blocker == "start unknown" then
                -- Another version of a quest you're already shown (they rule each other out).
                for _, id in ipairs(q.excl or {}) do
                    if keptOpen[id] then hide = true end
                end
            end
            -- A quest only other races are sent to, or a chain through one.
            if forOthers(q) then hide = true end
            for _, s in ipairs(item.steps or {}) do
                if not s.inLog and forOthers(s.q) then hide = true end
            end
            if not item.home then hide = hide or anotherRacesVersion(item) end
        end
        if not hide then
            kept[#kept + 1] = item
            if not item.blocker then keptOpen[q.id] = true end
        end
    end
    return chainEnds(kept)
end

-- Returns { verdict = "start"|"stay"|"move"|"go"|"grind", reason = nil|"soon"|"grind", here = entry|nil,
-- best = entry, ranked = {...}, dungeons = {...}, classes = {...} } or nil plus a message. With reason
-- "grind", best is where to level up until its next quests open up (at best.nextAt).
local function buildPlan()
    ns.UpdatePlayer()
    if ns.player.faction ~= "Alliance" then
        return nil, "ZoneGuide only has Alliance zones so far."
    end
    localizePickups()

    local start = starterSection()
    if start then
        return { verdict = "start", here = start, best = start, ranked = { start } }
    end

    local hereMap, cont = currentLocation()
    local all, ranked, here = {}, {}, nil
    for _, z in ipairs(ns.zones) do
        local e = scoreZone(z)
        e.adjusted = e.value
        if z.map == hereMap then
            here = e
        elseif hereMap then
            -- Moving costs time: only worth it if the other zone is clearly better.
            e.adjusted = e.value - ns.SWITCH_COST
            if cont and e.cont ~= cont then e.adjusted = e.adjusted - ns.TRAVEL_PENALTY end
        elseif cont and e.cont ~= cont then
            e.adjusted = e.value - ns.TRAVEL_PENALTY
        end
        all[#all + 1] = e
        if e.value > 0.05 then ranked[#ranked + 1] = e end
    end
    table.sort(ranked, function(a, b) return a.adjusted > b.adjusted end)
    -- Only send you somewhere with enough quests to pick up right now; failing that, somewhere
    -- with at least one. A zone whose quests all need a higher level is no use yet.
    local best
    for _, need in ipairs({ ns.MIN_OPEN_BEST, 1 }) do
        for _, e in ipairs(ranked) do
            if e.open >= need then best = e break end
        end
        if best then break end
    end
    best = best or ranked[1]

    -- Another zone is only worth the trip if it gives you more than the trip costs. When nowhere
    -- is and nothing's left here either, level up where the next quests open up soonest.
    local function worthTrip(e) return e and (not here or e == here or e.adjusted > 0) end
    if not worthTrip(best) and not (here and here.open >= 1 and here.value > 0.05) then
        local function sooner(a, b)
            if a.nextAt ~= b.nextAt then return a.nextAt < b.nextAt end
            local aHere, bHere = a == here and a.nextValue >= ns.DONE_VALUE, b == here and b.nextValue >= ns.DONE_VALUE
            if aHere ~= bHere then return aHere end
            return a.value + a.nextValue > b.value + b.nextValue
        end
        local target
        for _, e in ipairs(all) do
            if e.nextAt and (not target or sooner(e, target)) then target = e end
        end
        if not target then
            return nil, "No more solo quests found for level " .. ns.player.level .. "."
        end
        local listed = false
        for _, e in ipairs(ranked) do listed = listed or e == target end
        if not listed then table.insert(ranked, 1, target) end
        return { verdict = target == here and "grind" or (here and "move" or "go"), reason = "grind",
                 here = here, best = target, ranked = ranked,
                 dungeons = ns.DungeonQuests(), classes = ns.ClassQuests() }
    end

    -- Stay while there's still a decent amount to do here and nowhere is clearly better.
    local verdict, reason
    local p = ns.player
    if not here then
        verdict = "go"
    elseif here == best or not worthTrip(best) then
        verdict = "stay"
    elseif ns.FINISH_ZONE and here.open >= 1 and here.left >= ns.MIN_OPEN_STAY
            and (here.value >= ns.DONE_VALUE or here.value >= best.adjusted) then
        -- Travelling back and forth costs more than it gains: finish this zone first. Even with only
        -- a little left, finish it unless the other zone is better by more than the trip costs.
        -- A zone you're passing through with only a quest or two left isn't worth stopping for.
        verdict = "stay"
    elseif not ns.FINISH_ZONE and here.open >= ns.MIN_OPEN and here.adjusted >= best.adjusted then
        verdict = "stay"
    elseif here.soon >= ns.DONE_VALUE and here.open + here.soonN >= ns.MIN_OPEN_STAY
            and p.xp >= ns.ALMOST_LEVEL * p.xpMax then
        -- Nearly the next level, and more quests open here then: don't leave for the last few kills.
        verdict, reason = "stay", "soon"
    else
        verdict = "move"
    end
    return { verdict = verdict, reason = reason, here = here, best = best, ranked = ranked,
             dungeons = ns.DungeonQuests(), classes = ns.ClassQuests() }
end

-- Scoring every zone takes a moment, so the plan is kept until something changes.
local plan, planMessage
function ns.Invalidate()
    plan, planMessage = nil, nil
end

function ns.GetPlan()
    if not plan and not planMessage then
        plan, planMessage = buildPlan()
        planMessage = planMessage or (not plan and "") or nil
    end
    return plan, planMessage
end

-- Events --------------------------------------------------------------------------------

local pending = false
local function queueRefresh(delay)
    if pending then return end
    pending = true
    C_Timer.After(delay or 0.3, function()
        pending = false
        ns.Invalidate()
        ns.Refresh()
    end)
end

-- Quest gold -----------------------------------------------------------------------------
-- What a quest pays when you turn it in, in copper. The quest databases don't have it, but the
-- game does once it has loaded the quest: the ones it hasn't are asked for, and count as missing
-- until they arrive. Known amounts are kept between sessions, and dropped when the game is patched.
local GetRewardMoney = GetQuestLogRewardMoney
local moneyOf, asked, moneyDB = {}, {}, nil

if GetRewardMoney then
    function ns.QuestMoney(id)
        local m = moneyOf[id] or (moneyDB and moneyDB[id])
        if m then return m end
        if not HaveQuestData then return GetRewardMoney(id) or 0 end  -- can't tell: take what it says
        if not HaveQuestData(id) then return nil end
        m = GetRewardMoney(id) or 0
        moneyOf[id] = m
        if moneyDB then moneyDB[id] = m end
        return m
    end

    -- Ask the game for quests whose gold isn't known yet, a few at a time.
    function ns.RequestMoney(ids)
        local n = 0
        for _, id in ipairs(ids or {}) do
            if not asked[id] then
                asked[id] = true
                if C_QuestLog and C_QuestLog.RequestLoadQuestByID then
                    C_QuestLog.RequestLoadQuestByID(id)
                elseif C_QuestLog and C_QuestLog.GetQuestObjectives then
                    C_QuestLog.GetQuestObjectives(id)
                end
                n = n + 1
                if n >= 30 then break end
            end
        end
        if n > 0 then queueRefresh(2) end  -- in case the game doesn't say when they've loaded
    end
end

local function loadMoneyDB()
    local build = GetBuildInfo and select(2, GetBuildInfo()) or ""
    if ZoneGuideDB.moneyBuild ~= build or type(ZoneGuideDB.money) ~= "table" then
        ZoneGuideDB.money, ZoneGuideDB.moneyBuild = {}, build
    end
    moneyDB = ZoneGuideDB.money
end

local wasAlmost
local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "QUEST_TURNED_IN",
                     "QUEST_ACCEPTED", "QUEST_REMOVED", "ZONE_CHANGED_NEW_AREA", "PLAYER_XP_UPDATE",
                     "UPDATE_FACTION" }) do
    f:RegisterEvent(e)
end
pcall(f.RegisterEvent, f, "QUEST_DATA_LOAD_RESULT")  -- not in every client
f:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        ZoneGuideDB = ZoneGuideDB or { shown = true }
        loadMoneyDB()
        ns.CreateUI()
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        if not asked[arg1] then return end
        if arg2 == false then moneyOf[arg1] = 0 end  -- the game doesn't have this quest: count it as nothing
    elseif event == "QUEST_TURNED_IN" and arg1 then
        ns.turnedIn[arg1] = true
    elseif event == "UPDATE_FACTION" then
        for k in pairs(repCache) do repCache[k] = nil end
    elseif event == "PLAYER_XP_UPDATE" then
        -- XP only matters when you cross the "nearly the next level" mark.
        local max = UnitXPMax and UnitXPMax("player") or 0
        local almost = max > 0 and (UnitXP("player") or 0) >= ns.ALMOST_LEVEL * max
        if almost == wasAlmost then return end
        wasAlmost = almost
    end
    if event == "PLAYER_LEVEL_UP" or event == "ZONE_CHANGED_NEW_AREA" then
        ns.picked = nil  -- go back to following the recommendation
    end
    ns.Invalidate()
    -- UnitLevel can lag a moment behind PLAYER_LEVEL_UP.
    queueRefresh(event == "PLAYER_LEVEL_UP" and 0.6 or 0.3)
end)

SLASH_ZONEGUIDE1 = "/zg"
SLASH_ZONEGUIDE2 = "/zoneguide"
SlashCmdList.ZONEGUIDE = function(msg)
    msg = (msg or ""):lower()
    if msg == "reset" then
        ZoneGuideDB.point = nil
        ns.ResetPosition()
    else
        ns.Toggle()
    end
end
