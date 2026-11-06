# Gear Sources (RS3 plugin)

Inspect another player, hover an item they are wearing, and a tooltip shows:

- **To wear**: the skill levels the game itself stores on the item (`WEAR_REQUIRES_STATn` params). These and the
  recipe's skill levels are green when your own level (`Player.GetLevelCapped`, boosts not counted) meets them and red
  when it does not.
- **Quest to wear**: quests needed to wield it (dragon weapons: Monkey Madness, Lost City, Regicide...), from the item
  params `WEAR_REQUIRES_QUESTn`, which hold a quest's `QUEST_ID` param; green when you have finished the quest
  (`QuestType.hasFinishedQuest`), red when not.
- **Dropped by**: monsters that drop it, best chance first, with combat/Slayer levels (RuneScape Wiki).
- **Also from**: caskets, crackers and other reward containers.
- **How it's made**: the wiki recipe (skills, facility, materials). Materials that are made themselves show their own
  recipe's requirements under them, two levels deep (Rune platebody -> Rune bar: 50 Smithing at Furnace -> ores).
  Divination transmutation recipes are skipped in that tree, so ores and logs stay plain materials. Trivial materials
  (runes, essence, water, vials, thread, coins: `TRIVIAL_NAMES` / `TRIVIAL_PATTERNS` in `core.lua`) are listed with
  nothing about how to get them, and are never looked up. A material with a usual source (a combat or skilling source,
  not a reward container, no rarer than 1/100: Magical thread from the runecrafting altars) shows that source, and its
  recipe only as a grey "or made:" alternative, so a recipe nobody needs (110 Runecrafting) is not shown as required. If nothing drops
  the item itself, each material shows the monster that drops it (Ascension crossbow -> signets from the Legiones).
- **Sold by**: shops and prices.

Augmented items are looked up as their base item. The tooltip says what an item *can* be obtained from; the game
does not record how that player got theirs.

## Install and run

1. Set `contactEmailAddress` in `plugin/gear_sources/plugin.json` to your own address.
2. Copy `plugin/gear_sources` to `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\gear_sources`.
3. In the client console: `prf` (refresh), `plist` (should list `gear_sources`), `pon gear_sources`, then
   `ppe gear_sources httpAccess` and `prl gear_sources` (reload; the grant took effect only after a reload for Drop
   Tracker). Wiki lookups need httpAccess; without it only the wear requirements show. The console prints
   `[GearSources] ready: ...` when the permission is in place, or `ready, but httpAccess is not granted`.
4. Inspect a player and hover their gear.

## Layout

| File | What it does |
|---|---|
| `plugin/gear_sources/main.lua` | Entry point; loads the modules and starts the adapter |
| `plugin/gear_sources/adapter.lua` | Client binding: finds the gear slots, checks hover, reads item params, HTTP |
| `plugin/gear_sources/lookup.lua` | Wiki lookups per item (page, drops, recipes, stores, material drops), cached per session |
| `plugin/gear_sources/core.lua` | Pure logic: requirements, bucket queries, parsing, tooltip text |
| `plugin/gear_sources/tooltip.lua` | Draws the box on the plugin build layer |
| `plugin/gear_sources/json.lua` | Small JSON decoder |
| `test/run.lua` | Tests: `lua test/run.lua` (uses recorded wiki replies in `test/fixtures`) |
| `tools/record_fixtures.py` | Records wiki replies the tests are missing |
| `tools/probes/inspect_probe` | The probe that found the inspect screen layout |

## Known gaps

- Verified in game (2026-10-23): the inspect screen layout (interface 1558, static 8), hover via `isMouseOver`, the
  wear-requirement params (two-skill items too), quest-to-wield requirements and their green/red completion, HTTPS requests to runescape.wiki, and the tooltip drawn beside the
  game's own item tooltip (interface 1486), which covers anything on the plugin layer underneath it.
- The plugin keeps its last 80 log lines in PersistentDB key `log` (readable from `PluginData.db`).
- Requirements that are not item params (max cape: all skills at 99; achievement or quest locks) are not shown.
- Lookups are cached for the session only.
