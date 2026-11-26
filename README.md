# ZoneGuide

A small World of Warcraft addon for the Forever realms. It tells you the best zone to level in right now, when it's time to move on, and which quests in that zone are worth your time. It does nothing automatically: no auto-accept, no arrows, no vendoring.

Alliance only for now.

## Install

Copy the inner `ZoneGuide` folder (the one with `ZoneGuide.toc`) into
`World of Warcraft\_forever_\Interface\AddOns\`.

In game:
- `/zg` shows or hides the window. `/zg reset` puts it back to its default size and position.
- Drag the window to move it. Drag the bottom-right corner to resize it. Scroll with the mouse wheel when the list is longer than the window.
- The top line is the verdict: **Starting zone**, **Stay in X**, **Time to move: go to Y**, or **Go to Y**.
- Below it are the best zones for you. Each has a bar and a number showing how many levels' worth of quest XP is still waiting there, and next to it the gold you'd get from turning in those same quests and selling their reward items. Click a zone to see its quests.
- The gold is the money those quests pay plus what their reward items sell for at a vendor. When a quest gives you several items at once, they all count (times the stack). When you pick one of several items, only the one that sells for most counts. Hover a zone to see how much is quest gold and how much is from selling items, and hover a quest to see which items count.
- The gold and the item prices come from the game itself, since the quest databases don't have quest rewards. The game only knows a quest's reward once it has loaded that quest and its items, so ZoneGuide asks it for the ones on screen. Until they arrive the amount ends in **+**, meaning at least that much. Known amounts are remembered between sessions, and forgotten when the game is patched.
- **Sort: Level / Sort: XP** (top right) switches the quest order. Either way, your current quests come first (green), then ones you can pick up now, then ones you've out-levelled (marked **(low XP)**), then locked ones (grey, with the reason). Quests 10 or more levels below you give 10% XP and aren't listed.
- A **star** on a locked quest means it's **worth unlocking**: it and the quests you still need before it add up to at least 3 normal quests' worth of XP at your level, at least one normal quest's worth per step, through no more than 10 earlier quests and at most one group quest. Hover it to see the total XP and what to do ("start the chain", "come back at level N", or "keep the item if it drops"). Section headers show how many starred quests they hold.
- **Click any quest** (or any step of an expanded chain) to open the world map on its quest giver, marked with a pin. The pin disappears when you close the map. This doesn't work in combat.
- **Map pins** (bottom left) marks every quest giver in the zone shown (the recommended zone, or the one you clicked) on your world map. Hover a pin to see the giver and their quests. A giver's pin goes away once you've accepted their quests, and clicking **Map pins** again clears them all. The setting is kept between sessions. It's off at first.
- A locked quest marked **[+]** needs earlier quests first. Click the **[+]** (or right-click the quest) to see the chain from the start: each step's quest giver, zone and coordinates. Hover any quest for details.
- **Elite and dungeon quests for your level** sit in a collapsed section at the bottom. The zone's elite quests come first. Then every dungeon that suits your level gets its own heading with all of its quests you can still do, wherever they're picked up and whatever their level, so you can collect them all (and the chains leading to them) before you go in. Raids and battlegrounds aren't listed. These quests can be expanded the same way. They don't count towards a zone's score.
- **Class quests for your level** sit in another collapsed section. Where every race has its own version of a class quest (most level 10 to 20 class quests), you see your race's version, picked up in your starting zone or capital.

## How it decides

1. **Levels 1 to about 12:** you follow the RestedXP starting-zone route (from their free guides) for the starting zone you're standing in, whatever your race, so a dwarf who runs to Northshire gets the Northshire quests. Anywhere else, you get your own race's route. Quests only one race can take are left out for everyone else.
2. **After that:** every zone is scored for your character. The score is how many levels the quest XP from the solo quests you haven't done there would take you, from where you are now:
   - A quest only counts from the level where it's at most 2 levels above you (and you can pick it up). A harder quest counts only if the quest XP of the easier ones in that zone would level you up far enough to reach it; otherwise it doesn't count.
   - Only quest XP counts. The XP from mobs you kill on the way isn't predicted, because it varies too much (how many kills an item takes depends on drop rates, which aren't in the data). So you'll usually level a bit faster than the numbers say, and more quests open up than the score expects.
   - Quests you've out-levelled are worth less, using Classic's quest XP penalty.
   - Quests you can't actually take don't count: other classes' and races' quests, finished quests, quests that a done or active quest rules out, quests you've grown past the maximum level for, quests that need a reputation you don't have yet, quests that only start from a dropped item, and quests whose chain starts in another zone or in a dungeon (those are listed, but not counted).
   - The list only shows quests at most 2 levels above you. More appear as you level.
3. **Stay or move:** once you're in a zone, you're told to **finish it first**. It says stay while the zone has at least 3 quests left (counting later steps of chains you can start) and something you can pick up now or have in your log, and either at least 0.15 levels of quest XP left, or more than any other zone would give you after travel. Bouncing between zones costs more in travel than it gains. A zone with only 1 or 2 quests left isn't worth stopping for, so if you pass through one on your way somewhere better, it tells you to keep going. If you're 85% of the way to your next level and enough quests in your zone open up at that level, it says to finish the level there. When the zone is done, it sends you to the best zone, counting a travel cost of 0.3 levels plus 0.3 more for the other continent. That zone must have at least 3 quests you can pick up straight away (or at least 1, if no zone has 3), and give you more than the trip costs.
4. **Nothing worth the trip:** if no zone has enough within 2 levels of you to be worth travelling for, it says to finish what's left where you are. When that's done too, it says **Level up in X**: kill mobs (or run a dungeon) in the zone where the next quests open up soonest, and tells you the level they open at.

The settings are at the top of `Core.lua`. `FINISH_ZONE = false` switches back to leaving as soon as another zone is clearly better. `MAX_ABOVE` is how far above you a quest can be and still count. `MIN_OPEN_STAY`, `DONE_VALUE`, `SWITCH_COST`, `TRAVEL_PENALTY` and `ALMOST_LEVEL` tune the stay or move thresholds. `STAR_QUESTS` and `STAR_MAX_STEPS` tune the star.

Simulated 12 to 60 runs that follow the addon's advice (a human warrior and a night elf druid, doing only quests within 2 levels and getting 80% extra XP from kills) do about 775 quests with 33 to 37 zone moves. A few moves (3 to 6) go back to the zone before, but only once its quests within reach are done and its next ones have opened up. The route is Westfall, Darkshore (14 to 20), Ashenvale, Redridge, Wetlands, Duskwood, Desolace and Stranglethorn, then Riverglades for most of 36 to 42, and Mount Hyjal for most of 55 to 59. From 45 to 52 every zone runs thin: the run has to kill mobs for about 3.5 levels in total there, which is where the dungeon quests help most. Run `python3 tools/test_addon.py ZoneGuide sim Human WARRIOR` to see it.

## Where the data comes from

| What | Source |
|---|---|
| Starting-zone routes (1 to ~12, including Skyborne) | RestedXP's free Forever guides |
| Quests, levels, prerequisites, quest givers | QuestieDB's Forever data, with all of its corrections applied (what QuestieDB itself ships to players) |
| Quest XP | QuestieDB's Forever XP observed in game, falling back to its Classic XP table |
| Quest gold, reward items and what they sell for | The game itself, once it has loaded the quest and its items |
| Elite/dungeon tags, removed quests | Questie corrections |
| Which zones get scored | `tools/zones_alliance.json` (ours), including the Forever zones Riverglades, Shen'dralas and Mount Hyjal |

Quests added for Forever that nobody has been seen getting XP from yet (riding quests, leftovers from Season of Discovery) are left out. Quests in cities, Moonglade and Blackrock Mountain aren't scored as zones.

## Rebuilding the data

```
git clone https://github.com/RestedXP/RXPGuides
git clone https://github.com/Questie/QuestieDB
git clone https://github.com/Questie/Questie
pip install lupa
python3 tools/build_data.py RXPGuides QuestieDB Questie ZoneGuide
python3 tools/test_addon.py ZoneGuide            # spot checks with a fake game API (Lua 5.1)
python3 tools/test_addon.py ZoneGuide sim        # simulated 12 -> 60 run
python3 tools/test_addon.py ZoneGuide clicks     # map clicks and tooltips
python3 tools/test_addon.py ZoneGuide classes    # class quest section for several race and class pairs
python3 tools/test_addon.py ZoneGuide checks     # starting route by location, map pins, dungeon section, stay rule, quest gold
```

## Licences and credit

- `Data_StartRoute.lua` is adapted from RestedXP Guides (https://github.com/RestedXP/RXPGuides), © RestedXP, licensed CC BY-NC-SA 4.0. Because of that, ZoneGuide must stay free and non-commercial, and that data is shared under the same licence.
- Quest data comes from QuestieDB (https://github.com/Questie/QuestieDB) and Questie (https://github.com/Questie/Questie), GPLv3.
- No content from RestedXP's paid guides is used.
