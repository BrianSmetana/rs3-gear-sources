-- Tests for Gear Sources under stock Lua 5.4: lua test/run.lua (from the rs3-gear-sources folder).
-- Wiki replies come from test/fixtures (real replies recorded by tools/record_fixtures.py); a request without a
-- fixture is written to test/fixtures/missing.txt and fails, so run the recorder and then the tests again.

local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local root = here .. "/.."
package.path = root .. "/plugin/gear_sources/?.lua;" .. package.path

local json = require("json")
local core = require("core")
local lookup = require("lookup")
local tooltip = require("tooltip")
local adapter = require("adapter")

local passed, failed = 0, 0
local function test(name, f)
  local ok, err = pcall(f)
  if ok then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, what)
  if a ~= b then error((what or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function has(lines, needle)
  for _, l in ipairs(lines) do if l:find(needle, 1, true) then return true end end
  error("no line contains '" .. needle .. "' in:\n  " .. table.concat(lines, "\n  "), 2)
end

-- ---------------------------------------------------------------- fixtures

local fixtures_dir = root .. "/test/fixtures"
local fixtures, missing = {}, {}
do
  local f = io.open(fixtures_dir .. "/index.tsv", "r")
  if f then
    for line in f:lines() do
      local path, file = line:match("^(.-)\t(.+)$")
      if path then fixtures[path] = file end
    end
    f:close()
  end
end

local function fixture_http(path, cb)
  local file = fixtures[path]
  if not file then
    missing[#missing + 1] = path
    return cb(false, "no fixture")
  end
  local f = assert(io.open(fixtures_dir .. "/" .. file, "rb"))
  local body = f:read("a")
  f:close()
  cb(true, body)
end

-- ---------------------------------------------------------------- json

test("json decodes nested values, escapes and null", function()
  local v = assert(json.decode('{"a":[1,2.5,-3e2],"b":"x\\"y\\u00e9\\n","c":null,"d":true,"e":{}}'))
  eq(v.a[3], -300, "exponent")
  eq(v.b, 'x"y\195\169\n', "escapes")
  eq(v.c, json.null, "null")
  eq(v.d, true, "true")
end)

test("json reports errors instead of raising", function()
  local v, err = json.decode('{"a":')
  eq(v, nil)
  assert(err and err:find("json"), tostring(err))
end)

-- ---------------------------------------------------------------- core

test("wear requirements pair stat and level params (values seen in game)", function()
  local r = core.wear_requirements({ { name = "WEAR_REQUIRES_STAT1", value = 4 }, { name = "WEAR_REQUIRES_STAT_LEVEL1", value = 90 },
                                     { name = "MELEE_STRENGTH", value = 6720 } })
  eq(#r, 1)
  eq(r[1].skill, "Ranged")
  eq(r[1].level, 90)
  eq(core.wear_requirements({ { name = "WEAR_REQUIRES_STAT1", value = 1 }, { name = "WEAR_REQUIRES_STAT_LEVEL1", value = 37 } })[1].skill, "Defence")
  eq(#core.wear_requirements({}), 0)
end)

test("rarity text becomes a chance", function()
  eq(core.rarity_chance("1/1,024"), 1 / 1024)
  eq(core.rarity_chance("3/128"), 3 / 128)
  eq(core.rarity_chance("Always"), 1)
  eq(core.rarity_chance("Rare"), 1 / 128)
  eq(core.rarity_chance("Varies"), 0)
end)

test("thousands and wrap", function()
  eq(core.thousands(41680), "41,680")
  eq(core.thousands(2871000), "2,871,000")
  eq(core.thousands(999), "999")
  local lines = core.wrap(string.rep("word ", 30), 20)
  for _, l in ipairs(lines) do assert(#l <= 20, l) end
end)

test("the wiki's 9999 placeholder level is not shown", function()
  local row = { page_name = "Amascut, the Devourer", item_name = "Boots of Tumeken's resplendence",
    drop_json = '{"Dropped from":"Amascut, the Devourer","Dropped item":"Boots of Tumeken\'s resplendence",' ..
                '"Rarity":"3/500","Drop type":["combat"],"Drop level":[[9999]]}' }
  local d = core.drops_from_rows({ row })[1]
  eq(d.levels, "", "levels")
  eq(d.rarity, "3/500")
end)

test("requirements are green when met, red when not, plain when the level is unknown", function()
  local levels = { Magic = 99, Defence = 80 }
  local function level_of(s) return levels[s] end
  eq(core.requirement(95, "Magic", level_of), "<col=7fe08f>95</col> <col=7fe08f>Magic</col>")
  eq(core.requirement(95, "Defence", level_of), "<col=ff6b6b>95</col> <col=ff6b6b>Defence</col>")
  eq(core.requirement(95, "Smithing", level_of), "95 Smithing")
  eq(core.requirement(95, "Magic", nil), "95 Magic")
  local lines = core.tooltip_lines({ name = "Boots", reqs = { { skill = "Defence", level = 95 }, { skill = "Magic", level = 95 } },
    recipes = { { skills = { { name = "Smithing", level = 50 } }, materials = {} } }, level_of = level_of })
  has(lines, "To wear: <col=ff6b6b>95</col> <col=ff6b6b>Defence</col>, <col=7fe08f>95</col> <col=7fe08f>Magic</col>")
  has(lines, "Needs 50 Smithing")
end)

test("quests to wear: green when finished, red when not, and they replace the empty-requirement line", function()
  eq(core.quest_requirement("Monkey Madness", true), "<col=7fe08f>Monkey</col> <col=7fe08f>Madness</col>")
  eq(core.quest_requirement("Monkey Madness", false), "<col=ff6b6b>Monkey</col> <col=ff6b6b>Madness</col>")
  eq(core.quest_requirement("Monkey Madness", nil), "Monkey Madness")
  local lines = core.tooltip_lines({ name = "Dragon scimitar", reqs = {}, quests = { { name = "Monkey Madness", done = true } },
                                     status = "loading" })
  has(lines, "Quest to wear: <col=7fe08f>Monkey</col>")
  for _, l in ipairs(lines) do assert(not l:find("no requirement", 1, true), l) end
end)

test("wrapping ignores colour tags when counting", function()
  local coloured = string.rep("<col=7fe08f>word</col> ", 10)
  eq(#core.wrap(coloured, 60), 1, "50 visible characters fit on one line")
end)

test("queries quote apostrophes", function()
  local q = core.query_recipes("Ahrim's hood")
  assert(q:find("'Ahrim\\'s hood'", 1, true), q)
end)

test("tooltip lays out to the right, or left near the screen edge", function()
  local lines = { "short", "a much longer line of text" }
  local x = tooltip.layout(lines, { x = 100, y = 100, w = 36, h = 32 }, 1920, 1080)
  eq(x, 144, "right of slot")
  local x2, y2, w2 = tooltip.layout(lines, { x = 1880, y = 1070, w = 36, h = 32 }, 1920, 1080)
  assert(x2 + w2 <= 1880, "flipped left")
  assert(y2 < 1070, "moved up")
end)

-- ---------------------------------------------------------------- lookups against recorded wiki replies

local function look(id, name)
  local updates = 0
  local w = lookup.new(fixture_http, function() updates = updates + 1 end)
  local entry = w.get(id, name)
  return entry, updates
end

local samples = {} -- tooltips printed at the end, to eyeball

test("Abyssal whip: dropped by abyssal demons", function()
  local e = look(4151, "Abyssal whip")
  eq(e.status, nil, "status")
  eq(e.page, "Abyssal whip")
  assert(#e.drops > 0, "drops")
  local found = false
  for _, d in ipairs(e.drops) do if d.monster == "Abyssal demon" then found = true end end
  assert(found, "abyssal demon listed")
  local lines = core.tooltip_lines({ name = "Abyssal whip", reqs = { { skill = "Attack", level = 70 } }, page = e.page,
                                     drops = e.drops, recipes = e.recipes, stores = e.stores })
  has(lines, "To wear: 70 Attack")
  has(lines, "Dropped by")
  samples[#samples + 1] = lines
end)

test("Rune platebody: smithing recipe and shops", function()
  local e = look(1127, "Rune platebody")
  eq(e.status, nil, "status")
  assert(e.recipes[1], "recipe")
  local lines = core.tooltip_lines({ name = "Rune platebody", reqs = {}, page = e.page, drops = e.drops,
                                     recipes = e.recipes, stores = e.stores })
  has(lines, "Smithing")
  has(lines, "Rune bar")
  has(lines, "Sold by")
  has(lines, "Also from: Casket") -- caskets and crackers are not listed as monsters
  has(lines, "5 x Rune bar: 50 Smithing at Furnace") -- the bar's own recipe, under it
  for _, l in ipairs(lines) do assert(not l:find("Divination", 1, true), "transmutation shown: " .. l) end
  for _, l in ipairs(lines) do assert(not l:find("historical", 1, true), "historical source shown: " .. l) end
  samples[#samples + 1] = lines
end)

test("Ascension crossbow: recipe materials name the Legiones that drop them", function()
  local e = look(28437, "Ascension crossbow")
  eq(e.status, nil, "status")
  assert(e.recipes[1], "recipe")
  local lines = core.tooltip_lines({ name = "Augmented ascension crossbow", base_name = "Ascension crossbow",
                                     reqs = { { skill = "Ranged", level = 90 } }, page = e.page, drops = e.drops,
                                     recipes = e.recipes, stores = e.stores })
  has(lines, "Legio")
  samples[#samples + 1] = lines
end)

test("Elysian spirit shield: the materials' own recipes show under them", function()
  local e = look(13742, "Elysian spirit shield")
  eq(e.status, nil, "status")
  local levels = { Smithing = 99, Prayer = 80 }
  local lines = core.tooltip_lines({ name = "Elysian spirit shield", reqs = {}, page = e.page, drops = e.drops,
                                     recipes = e.recipes, stores = e.stores,
                                     level_of = function(s) return levels[s] end })
  has(lines, "Needs quest: Completed Summer's End") -- wiki link markup removed
  has(lines, "1 x Blessed spirit shield:")            -- level 1 has its own recipe ...
  local blessed, deeper
  for i, l in ipairs(lines) do
    if l:find("1 x Blessed spirit shield:", 1, true) then blessed = i end
    if blessed and i > blessed and l:match("^    %S") then deeper = l end -- ... and its materials sit under it
  end
  assert(deeper, "a level-2 material under the blessed spirit shield:\n" .. table.concat(lines, "\n"))
  has(lines, "<col=ff6b6b>Prayer</col>") -- 80 Prayer is short of the recipes' Prayer levels
  samples[#samples + 1] = lines
end)

test("trivial materials are listed without how to get them", function()
  assert(core.is_trivial("Fire rune") and core.is_trivial("cosmic rune") and core.is_trivial("Pure essence"))
  assert(not core.is_trivial("Rune bar") and not core.is_trivial("Runite ore") and not core.is_trivial("Shard of Genesis Essence"))
  local e = look(39812, "Luck of the Dwarves")
  eq(e.status, nil, "status")
  local lines = core.tooltip_lines({ name = "Luck of the Dwarves", reqs = {}, page = e.page, drops = e.drops,
                                     recipes = e.recipes, stores = e.stores })
  local runes = 0
  for _, l in ipairs(lines) do
    if l:find(" rune", 1, true) and l:find(" x ", 1, true) then
      runes = runes + 1
      assert(l:match(" x %a+ rune$"), "a rune line with more after it: " .. l)
    end
    assert(not l:find("Runecrafting", 1, true), "rune requirement shown: " .. l)
  end
  assert(runes > 0, "runes still listed:\n" .. table.concat(lines, "\n"))
  samples[#samples + 1] = lines
end)

test("Grasping rune pouch: Magical thread comes from the altars, its 110 Runecrafting recipe is only an alternative", function()
  local e = look(52235, "Grasping rune pouch (purple)")
  eq(e.status, nil, "status")
  local lines = core.tooltip_lines({ name = "Grasping rune pouch (purple)", reqs = {}, page = e.page, drops = e.drops,
                                     recipes = e.recipes, stores = e.stores,
                                     level_of = function() return 99 end })
  local thread
  for i, l in ipairs(lines) do
    if l:find("x Magical thread - from", 1, true) then thread = i end
    if l:find("110", 1, true) then
      assert(l:find("or made:", 1, true) and l:find("^<col=b8b8b8>"), "110 Runecrafting shown as required: " .. l)
    end
  end
  assert(thread, "magical thread has a source:\n" .. table.concat(lines, "\n"))
  samples[#samples + 1] = lines
end)

test("a recipe loop does not hang the tooltip", function()
  local a = { skills = {}, materials = {}, outputs = { "A" } }
  local b = { skills = {}, materials = { { name = "A", quantity = "1", recipe = a } }, outputs = { "B" } }
  a.materials[1] = { name = "B", quantity = "1", recipe = b }
  local lines = core.tooltip_lines({ name = "A", reqs = {}, recipes = { a } })
  assert(#lines < 20, "bounded")
end)

test("Hooded max cape: no crash whatever the wiki has", function()
  local e = look(32151, "Hooded max cape")
  eq(e.status, nil, "status")
  samples[#samples + 1] = core.tooltip_lines({ name = "Hooded max cape", reqs = {}, page = e.page, drops = e.drops,
                                               recipes = e.recipes, stores = e.stores })
end)

test("a failed request shows in the entry and can be retried", function()
  local calls = 0
  local w = lookup.new(function(_, cb) calls = calls + 1 cb(false, "HTTP 503") end)
  local e = w.get(4151, "Abyssal whip")
  eq(e.status, "HTTP 503")
  w.retry_failed()
  w.get(4151, "Abyssal whip")
  eq(calls, 2, "retried")
end)

-- ---------------------------------------------------------------- adapter with a mock client

local function mock_client(opts)
  local subs, logs, created = {}, {}, {}
  local function ev() return setmetatable({}, { __index = function(t, k)
    local e = { Subscribe = function(ref, f) subs[k] = f end, Unsubscribe = function() subs[k] = nil end }
    rawset(t, k, e) return e end }) end
  local Event = ev()
  local function component(fields)
    local c = fields or {}
    function c:SetPos(x, y) self.x, self.y = x, y end
    function c:SetSize(w, h) self.width, self.height = w, h end
    function c:MoveToFront() end
    function c:AlignTo() end
    function c:Destroy() self.destroyed = true end
    return c
  end
  local slots = {
    component({ associatedObjectID = 36705, xyGlobal = { x = 94, y = 367 }, width = 36, height = 32, isMouseOver = false }),
    component({ associatedObjectID = 4151, xyGlobal = { x = 216, y = 180 }, width = 36, height = 32, isMouseOver = false }),
  }
  local open, game_tip = true, false
  local plugin_layer = component({ xyGlobal = { x = 0, y = 0 }, width = 1920, height = 1080 })
  -- the game's own tooltip: a full-screen root (to be ignored) and the box itself
  local TIP_ROOT, TIP_BOX = (1486 << 16) | 0, (1486 << 16) | 1
  local tip_parts = {
    [TIP_ROOT] = component({ xyGlobal = { x = 0, y = 0 }, width = 1920, height = 1080 }),
    [TIP_BOX] = component({ xyGlobal = { x = 60.0, y = 340.0 }, width = 350, height = 430, visibleGlobal = true }),
  }
  local function make(kind) return { new = function(parent, cat, id)
    local c = component({ kind = kind, category = cat, dyn = id })
    created[#created + 1] = c
    return c
  end } end
  local params = {
    [36705] = { { "WEAR_REQUIRES_STAT1", 4 }, { "WEAR_REQUIRES_STAT_LEVEL1", 90 }, { "INVENT_BASE_OBJECT", { id = 28437 } } },
    [28437] = { { "WEAR_REQUIRES_STAT1", 4 }, { "WEAR_REQUIRES_STAT_LEVEL1", 90 } },
    -- the quest is a test fixture (the real whip needs none), laid out as the dragon longsword's is in game:
    -- WEAR_REQUIRES_QUEST1 = Lost City's QUEST_ID, 68
    [4151] = { { "WEAR_REQUIRES_STAT1", 0 }, { "WEAR_REQUIRES_STAT_LEVEL1", 70 }, { "WEAR_REQUIRES_QUEST1", 68 } },
  }
  local names = { [36705] = "Augmented ascension crossbow", [28437] = "Ascension crossbow", [4151] = "Abyssal whip" }
  -- quest configs as in game: the current Lost City (262) carries QUEST_ID 68, its deprecated duplicate (42) does not
  local QUEST_ID = { configName = "QUEST_ID", id = 1345 }
  local quest_cfgs = {
    [42] = { name = "Lost City", deprecated = true, values = {} },
    [262] = { name = "Lost City", deprecated = false, hasFinishedQuest = false, values = { [QUEST_ID] = 68 } },
  }
  for _, q in pairs(quest_cfgs) do
    function q:HasParam(p) return self.values[p] ~= nil end
    function q:GetParamValue(p) return self.values[p] end
  end
  local granted = opts.http
  local db = {}
  local G = {
    Event = Event,
    PersistentDB = { SetString = function(_, k, v) db[k] = v end },
    SkillType = { ATTACK = 0, RANGED = 4 },
    Player = { GetLevelCapped = function(st) return ({ [0] = 99, [4] = 80 })[st] end },
    log = function(m) logs[#logs + 1] = m end,
    Plugin = { HasPermission = function() return granted end, urls = { wiki = "https://runescape.wiki" } },
    PluginPermissions = { httpAccess = 1 },
    HTTPRequest = { new = function(_, path)
      local req = { AddHeader = function() end }
      function req:Get(cb)
        fixture_http(path, function(ok, body)
          cb(ok and { successful = true, responseCode = 200, data = body } or { successful = false, responseCode = 404 })
        end)
      end
      return req
    end },
    id = { Component = { TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = 99, [TIP_ROOT] = "TEXT_TOOLTIP__ROOT",
                         [TIP_BOX] = "TEXT_TOOLTIP__BOX" }, Font = { MUSEO_SANS_15PT_REGULAR = 7 },
          Quest = { LOSTCITY = 42, LOST_CITY = 262 } },
    ui = {
      AlignMode = { TOPLEFT = 1 },
      Layer = make("layer"), Rectangle = make("rect"), Text = make("text"),
      Interfaces = {
        GetInterface = function(_, i)
          if (i == 1558 and open) or (i == 1486 and game_tip) then return {} end
        end,
        GetComponent = function(_, a, b)
          if a == 99 then return plugin_layer end
          if game_tip and tip_parts[a] then return tip_parts[a] end
          if open and a == 1558 and b == 8 then
            return { IterateDynamicComponents = function(_, f) for _, s in ipairs(slots) do f(s) end end }
          end
        end,
      },
    },
    config = {
      Obj = { FromID = function(i)
        local ps = {}
        for _, p in ipairs(params[i] or {}) do ps[#ps + 1] = { configName = p[1], value = p[2] } end
        return { name = names[i], params = ps, quests = {}, GetParamValue = function(_, p) return p.value end }
      end },
      Quest = { FromID = function(cid) return quest_cfgs[cid] end },
      Param = { QUEST_ID = QUEST_ID },
    },
  }
  return {
    G = G, subs = subs, logs = logs, created = created, slots = slots, db = db,
    set_open = function(v) open = v end, grant = function() granted = true end,
    set_game_tip = function(v) game_tip = v end,
    tick = function(n)
      for _ = 1, n or 1 do
        subs.ServerLogic()
        for _ = 1, 3 do subs.Logic() end
      end
    end,
    text = function()
      for _, c in ipairs(created) do if c.kind == "text" then return c end end
    end,
    root = function() -- the tooltip's layer: it is the part that moves and hides
      for _, c in ipairs(created) do if c.kind == "layer" then return c end end
    end,
  }
end

test("hovering an augmented item shows its tooltip with the base item's sources", function()
  local m = mock_client({ http = true })
  local app = adapter.start(m.G)
  m.tick()
  eq(m.text(), nil, "nothing drawn before a hover")
  m.slots[1].isMouseOver = true
  m.tick()
  local t = assert(m.text(), "tooltip text created")
  assert(t.content:find("Augmented ascension crossbow", 1, true), t.content)
  -- the mock player has 80 Ranged, so the crossbow's 90 Ranged is red
  assert(t.content:find("To wear: <col=ff6b6b>90</col> <col=ff6b6b>Ranged</col>", 1, true), t.content)
  assert(t.content:find("Legio", 1, true), t.content)
  local r = assert(m.root(), "tooltip layer created")
  eq(t.font, 7, "font from id.Font." .. "MUSEO_SANS_15PT_REGULAR")
  eq(r.clickthrough, true, "never steals the hover")
  eq(r.hidden, false, "visible")
  eq(r.x, 94 + 36 + 8, "right of the slot")
  m.slots[1].isMouseOver = false
  m.tick()
  eq(r.hidden, true, "hidden after the mouse leaves")
  m.slots[2].isMouseOver = true
  m.tick()
  assert(t.content:find("Abyssal whip", 1, true), t.content)
  assert(t.content:find("<col=7fe08f>70</col> <col=7fe08f>Attack</col>", 1, true), "99 Attack meets 70: " .. t.content)
  assert(t.content:find("Quest to wear: <col=ff6b6b>Lost</col> <col=ff6b6b>City</col>", 1, true),
    "unfinished quest in red: " .. t.content)
  m.tick()
  assert((m.db.log or ""):find("quest numbers indexed: 1 quests", 1, true), "deprecated duplicate skipped: " .. m.db.log)
  m.set_open(false)
  m.tick()
  eq(r.hidden, true, "hidden when the inspect screen closes")
  local saved = m.db.log or ""
  assert(saved:find("inspect screen: 2 worn items", 1, true), saved)
  assert(saved:find("tooltip for Augmented ascension crossbow (slot at 94,367): box at 138,367", 1, true), saved)
  assert(saved:find("inspect screen closed", 1, true), saved)
  app.shutdown()
  eq(r.destroyed, true, "destroyed on shutdown")
end)

test("without httpAccess the tooltip still shows wear requirements, then fills in once granted", function()
  local m = mock_client({ http = false })
  adapter.start(m.G)
  m.slots[2].isMouseOver = true
  m.tick()
  local t = assert(m.text())
  assert(t.content:find("To wear: <col=7fe08f>70</col> <col=7fe08f>Attack</col>", 1, true), t.content)
  assert(t.content:find("httpAccess not granted", 1, true), t.content)
  m.grant()
  m.subs.OptionalPermissionChanged({ permissionName = "httpAccess", enabled = true })
  m.slots[2].isMouseOver = false
  m.tick()
  m.slots[2].isMouseOver = true
  m.tick()
  assert(t.content:find("Dropped by", 1, true), t.content)
end)

test("the box moves beside the game's own tooltip when that appears", function()
  local m = mock_client({ http = true })
  adapter.start(m.G)
  m.slots[2].isMouseOver = true
  m.tick()
  local r = assert(m.root())
  eq(r.x, 216 + 36 + 8, "next to the slot before the game tooltip shows")
  m.set_game_tip(true)
  m.tick()
  eq(r.x, 60 + 350 + 8, "right of the game tooltip (full-screen root ignored)")
  eq(r.y, 340, "top-aligned with the game tooltip")
  m.tick() -- the log is saved on the next server tick
  local saved = m.db.log or ""
  assert(saved:find("game tooltip 60,340 350x430", 1, true), saved)
end)

test("a grant with no permission event still fills in the tooltip on screen", function()
  local m = mock_client({ http = false })
  adapter.start(m.G)
  m.slots[2].isMouseOver = true
  m.tick()
  local t = assert(m.text())
  assert(t.content:find("httpAccess not granted", 1, true), t.content)
  m.grant() -- no OptionalPermissionChanged, and the mouse never leaves the slot
  m.tick()
  assert(t.content:find("Dropped by", 1, true), t.content)
end)

-- ---------------------------------------------------------------- results

if #missing > 0 then
  local f = assert(io.open(fixtures_dir .. "/missing.txt", "a"))
  for _, p in ipairs(missing) do f:write(p, "\n") end
  f:close()
  print(#missing .. " wiki replies have no fixture: run python tools/record_fixtures.py, then the tests again")
end

for _, lines in ipairs(samples) do
  print("\n" .. table.concat(lines, "\n"):gsub("<[^>]*>", ""))
end
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
