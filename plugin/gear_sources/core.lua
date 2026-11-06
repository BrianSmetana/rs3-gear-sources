-- Pure logic for Gear Sources: wear requirements from item params, RS Wiki bucket queries and their parsing, and the
-- tooltip text. Nothing here touches the client, so it runs under stock Lua in test/run.lua.

local json = require("json")

local M = {}

-- RS3 stat index -> skill name. 0 Attack, 1 Defence and 4 Ranged were checked against item params in game.
M.SKILLS = {
  [0] = "Attack", "Defence", "Strength", "Constitution", "Ranged", "Prayer", "Magic", "Cooking", "Woodcutting",
  "Fletching", "Fishing", "Firemaking", "Crafting", "Smithing", "Mining", "Herblore", "Agility", "Thieving", "Slayer",
  "Farming", "Runecrafting", "Hunter", "Construction", "Summoning", "Dungeoneering", "Divination", "Invention",
  "Archaeology", "Necromancy",
}

M.MAX_DROPS = 4      -- monsters listed before "+N more"
M.MAX_MATERIALS = 5  -- recipe materials listed
M.MAX_STORES = 2
M.WRAP = 58          -- characters per tooltip line

--- Wear requirements from an item's params. `params` = { { name = configName, value = v }, ... }; the game pairs
--- WEAR_REQUIRES_STATn (stat index) with WEAR_REQUIRES_STAT_LEVELn. Returns { { skill, level }, ... } in n order.
function M.wear_requirements(params)
  local stat, level = {}, {}
  for _, p in ipairs(params or {}) do
    local name = tostring(p.name)
    local n = name:match("^WEAR_REQUIRES_STAT(%d+)$")
    if n then stat[tonumber(n)] = tonumber(p.value) end
    n = name:match("^WEAR_REQUIRES_STAT_LEVEL(%d+)$")
    if n then level[tonumber(n)] = tonumber(p.value) end
  end
  local out = {}
  for n = 1, 10 do
    if stat[n] and level[n] and level[n] > 0 then
      out[#out + 1] = { skill = M.SKILLS[stat[n]] or ("skill " .. stat[n]), level = level[n] }
    end
  end
  return out
end

-- ---------------------------------------------------------------- wiki queries (Bucket API)

local function lua_quote(s) return "'" .. tostring(s):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'" end

function M.query_page(item_id)
  return "bucket('infobox_item').select('page_name','item_name','item_id').where('item_id','" ..
    math.floor(item_id) .. "').limit(5).run()"
end

--- Drops of one item name, or of several (a recipe's materials), in one query.
function M.query_drops(names)
  local cond
  if #names == 1 then
    cond = "'item_name'," .. lua_quote(names[1])
  else
    local parts = {}
    for i, n in ipairs(names) do parts[i] = "{'item_name'," .. lua_quote(n) .. "}" end
    cond = "bucket.Or(" .. table.concat(parts, ",") .. ")"
  end
  -- several names share one query, and one item can have dozens of sources (Magical thread: every runecrafting altar)
  local limit = #names == 1 and 100 or math.min(500, 50 * #names)
  return "bucket('dropsline').select('page_name','item_name','drop_json').where(" .. cond .. ").limit(" .. limit ..
    ").run()"
end

--- Recipes producing one item name, or any of several (a recipe's materials, for the sub-recipe tree).
function M.query_recipes(names)
  if type(names) ~= "table" then names = { names } end
  local cond
  if #names == 1 then
    cond = "'production_output'," .. lua_quote(names[1])
  else
    local parts = {}
    for i, n in ipairs(names) do parts[i] = "{'production_output'," .. lua_quote(n) .. "}" end
    cond = "bucket.Or(" .. table.concat(parts, ",") .. ")"
  end
  return "bucket('recipe').select('page_name','production_output','production_json').where(" .. cond ..
    ").limit(" .. (5 * #names) .. ").run()"
end

function M.query_stores(name)
  return "bucket('storeline').select('page_name','sold_item','store_sell_price','store_currency').where('sold_item'," ..
    lua_quote(name) .. ").limit(20).run()"
end

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", string.byte(ch)) end))
end

--- Path (relative to https://runescape.wiki) for a bucket query.
function M.api_path(query)
  return "/api.php?action=bucket&format=json&query=" .. urlencode(query)
end

--- Rows of a bucket reply, or nil and an error.
function M.parse_bucket(body)
  local data, err = json.decode(body or "")
  if not data then return nil, err end
  if type(data) ~= "table" then return nil, "unexpected reply" end
  if data.error then return nil, "wiki: " .. tostring(data.error) end
  if type(data.bucket) ~= "table" then return nil, "reply has no bucket" end
  return data.bucket
end

local function str(v)
  if v == nil or v == json.null then return nil end
  if type(v) == "table" then v = v[1] end
  if v == nil or v == json.null then return nil end
  return tostring(v)
end

--- The wiki page for an item id: the first infobox row's page name.
function M.page_from_rows(rows)
  for _, r in ipairs(rows or {}) do
    local p = str(r.page_name)
    if p and p ~= "" then return p end
  end
end

-- ---------------------------------------------------------------- drops

local RARITY_WORDS = {
  always = 1, common = 1 / 8, uncommon = 1 / 32, rare = 1 / 128, ["very rare"] = 1 / 512,
}

--- Per-kill chance from a wiki rarity ("1/1,024", "3/128", "Always", "Rare", "~1/250"); 0 when unknown.
function M.rarity_chance(text)
  local t = tostring(text or ""):gsub(",", ""):lower()
  local a, b = t:match("(%d+%.?%d*)%s*/%s*(%d+%.?%d*)")
  if a then
    a, b = tonumber(a), tonumber(b)
    if a and b and b > 0 then return a / b end
  end
  for word, p in pairs(RARITY_WORDS) do
    if t:match("^%s*" .. word .. "%s*$") then return p end
  end
  return 0
end

--- { { monster, item, rarity, chance, levels = "combat 107, Slayer 85", reward = bool }, ... }, best chance first,
--- one row per source and item (the best one). `reward` marks sources that are not killed: caskets, crackers and
--- other containers (the wiki's drop type "reward"). Historical sources are left out.
function M.drops_from_rows(rows)
  local best = {}
  for _, r in ipairs(rows or {}) do
    local d = type(r.drop_json) == "string" and json.decode(r.drop_json) or {}
    if type(d) ~= "table" then d = {} end
    local monster = str(d["Dropped from"]) or str(r.page_name)
    monster = monster and monster:gsub("#.*$", "") -- "Golden chinchompa (Squeal of Fortune)#Total level 70+"
    local item = str(d["Dropped item"]) or str(r.item_name)
    if monster and item and not monster:lower():find("historical", 1, true) then
      local rarity = str(d["Rarity"]) or "?"
      local levels, combat = {}, false
      local types, lv = d["Drop type"], d["Drop level"]
      for _, kind in ipairs(type(types) == "table" and types or {}) do
        if kind == "combat" then combat = true end
      end
      if type(types) == "table" and type(lv) == "table" then
        for i, kind in ipairs(types) do
          local l = lv[i]
          if type(l) == "table" then l = l[1] end
          -- the wiki gives bosses with no real combat level 9999 (Amascut, the Devourer; seen in game)
          if l ~= nil and l ~= json.null and tostring(l) ~= "" and (tonumber(l) or 0) < 9999 then
            levels[#levels + 1] = (kind == "combat" and "combat " or (tostring(kind):gsub("^%l", string.upper) .. " ")) ..
              tostring(l)
          end
        end
      end
      local row = { monster = monster, item = item, rarity = rarity, chance = M.rarity_chance(rarity),
                    levels = table.concat(levels, ", "), reward = not combat,
                    types = type(types) == "table" and types or {} }
      local key = monster .. "\0" .. item
      if not best[key] or row.chance > best[key].chance then best[key] = row end
    end
  end
  local out = {}
  for _, row in pairs(best) do out[#out + 1] = row end
  table.sort(out, function(a, b)
    if a.reward ~= b.reward then return not a.reward end -- monsters first
    if a.chance ~= b.chance then return a.chance > b.chance end
    return a.monster < b.monster
  end)
  return out
end

--- Whether `drops` include a usual way to get a material, one that beats making it: a combat or skilling source
--- (drop type other than "reward") no rarer than 1 in 100, or of unknown rarity. Magical thread: every runecrafting
--- altar (yes, so its 110 Runecrafting recipe is not a requirement). Rune bar: crackers, mystery bags, a Rare impling
--- (no, so it stays "50 Smithing at Furnace").
function M.usual_source(drops)
  for _, d in ipairs(drops or {}) do
    local reward = #(d.types or {}) == 0
    for _, t in ipairs(d.types or {}) do if t == "reward" then reward = true end end
    if not reward and (d.chance == 0 or d.chance >= 0.01) then return true end
  end
  return false
end

-- ---------------------------------------------------------------- recipes and stores

-- Materials that are trivial to get: listed in a recipe, but with no requirement or sub-recipe after them, and never
-- looked up. Exact names (any case), plus name patterns matched against the lower-cased name. Edit freely.
M.TRIVIAL_NAMES = {
  "Rune essence", "Pure essence", "Vial", "Vial of water", "Bucket of water", "Jug of water", "Bowl of water",
  "Thread", "Coins",
}
M.TRIVIAL_PATTERNS = {
  "^%a+ rune$", -- Fire rune, Cosmic rune, Steam rune, ...
}

local trivial_set
function M.is_trivial(name)
  if not trivial_set then
    trivial_set = {}
    for _, n in ipairs(M.TRIVIAL_NAMES) do trivial_set[n:lower()] = true end
  end
  local low = tostring(name):lower()
  if trivial_set[low] then return true end
  for _, p in ipairs(M.TRIVIAL_PATTERNS) do
    if low:find(p) then return true end
  end
  return false
end

--- Wiki link markup to plain text: "[[Summer's End]]" -> "Summer's End", "[[Page|label]]" -> "label".
function M.strip_links(s)
  if not s then return nil end
  s = s:gsub("%[%[([^%]|]*)|([^%]]*)%]%]", "%2"):gsub("%[%[([^%]]*)%]%]", "%1")
  return s
end

--- { { skills = { {name, level} }, materials = { {name, quantity} }, facility, quest, outputs = { names } }, ... }
--- A material may later get `.recipe`: the recipe that makes it (see lookup.lua's sub-recipe tree).
function M.recipes_from_rows(rows)
  local out = {}
  for _, r in ipairs(rows or {}) do
    local p = type(r.production_json) == "string" and json.decode(r.production_json)
    if type(p) == "table" then
      local rec = { skills = {}, materials = {}, facility = M.strip_links(str(p.facility)),
                    quest = M.strip_links(str(p.quest)), method = str(p.method), outputs = {} }
      for _, o in ipairs(type(r.production_output) == "table" and r.production_output or { r.production_output }) do
        if o ~= nil and o ~= json.null then rec.outputs[#rec.outputs + 1] = tostring(o) end
      end
      for _, o in ipairs(type(p.outputs) == "table" and p.outputs or {}) do
        if type(o) == "table" and str(o.name) then rec.outputs[#rec.outputs + 1] = str(o.name) end
      end
      for _, s in ipairs(type(p.skills) == "table" and p.skills or {}) do
        if type(s) == "table" and str(s.name) then
          rec.skills[#rec.skills + 1] = { name = str(s.name), level = tonumber(str(s.level)) }
        end
      end
      for _, m in ipairs(type(p.materials) == "table" and p.materials or {}) do
        if type(m) == "table" and str(m.name) then
          rec.materials[#rec.materials + 1] = { name = str(m.name), quantity = str(m.quantity) or "1" }
        end
      end
      if rec.facility == "" then rec.facility = nil end
      if rec.quest == "" then rec.quest = nil end
      out[#out + 1] = rec
    end
  end
  return out
end

--- The recipe to show for an item when the wiki has several: the first that needs a skill, else the first.
--- Divination transmutation (energy + a lower ore -> runite ore) is how the wiki lists gathered resources as
--- "made", which is not how anyone gets them, so it is passed over; with `materials_only` (the sub-recipe tree) it is
--- never used, and an ore or log simply has no recipe.
function M.pick_recipe(list, materials_only)
  local fallback
  for _, rec in ipairs(list or {}) do
    if rec.method ~= "transmutation" then
      if #rec.skills > 0 then return rec end
      fallback = fallback or rec
    end
  end
  if fallback or materials_only then return fallback end
  return list and list[1]
end

--- Recipes grouped by the item they make: { [output name] = { recipe, ... } }.
function M.recipes_by_output(recipes)
  local by = {}
  for _, rec in ipairs(recipes or {}) do
    local seen = {}
    for _, name in ipairs(rec.outputs or {}) do
      if not seen[name] then
        seen[name] = true
        by[name] = by[name] or {}
        table.insert(by[name], rec)
      end
    end
  end
  return by
end

--- { { store, price, currency }, ... }, current stores only, cheapest first.
function M.stores_from_rows(rows)
  local out, seen = {}, {}
  for _, r in ipairs(rows or {}) do
    local store = str(r.page_name)
    if store and not seen[store] then
      seen[store] = true
      out[#out + 1] = { store = store, price = tonumber((str(r.store_sell_price) or ""):gsub(",", "") or ""),
                        currency = str(r.store_currency) or "coins" }
    end
  end
  table.sort(out, function(a, b) return (a.price or math.huge) < (b.price or math.huge) end)
  return out
end

-- ---------------------------------------------------------------- tooltip text

local GOLD, GREY, GREEN, ORANGE, RED = "<col=f2c66d>", "<col=b8b8b8>", "<col=7fe08f>", "<col=ffa94d>", "<col=ff6b6b>"

function M.thousands(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

--- Text without its colour tags.
function M.plain(s) return (tostring(s):gsub("<[^>]*>", "")) end

local function visible(s) return #M.plain(s) end

--- Word-wraps text at `width` visible characters (colour tags do not count, and are kept inside words, so a tag never
--- straddles a break). The text's own leading spaces are kept; continuation lines get two more than that.
function M.wrap(text, width)
  width = width or M.WRAP
  text = tostring(text)
  local lead = text:match("^ *")
  local indent = lead .. "  "
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = lead .. word
    elseif visible(line) + 1 + visible(word) <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = indent .. word
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

local function add(lines, text, colour)
  for _, l in ipairs(M.wrap(text)) do lines[#lines + 1] = colour and (colour .. l .. "</col>") or l end
end

--- "95 Magic" coloured for the player: green when `level_of(skill)` is at least `level`, red when below, uncoloured
--- when the player's level is unknown. Each word gets its own tag so wrapping can never split one.
function M.requirement(level, skill, level_of)
  local text = level and (level .. " " .. skill) or skill
  local have = level and level_of and level_of(skill)
  if not have then return text end
  local colour = have >= level and GREEN or RED
  return (text:gsub("%S+", function(word) return colour .. word .. "</col>" end))
end

local function colour_words(text, colour)
  return (text:gsub("%S+", function(word) return colour .. word .. "</col>" end))
end

--- A quest name, green when the player has finished it (`done` true), red when not (false), plain when unknown (nil).
function M.quest_requirement(name, done)
  if done == nil then return name end
  return colour_words(name, done and GREEN or RED)
end

M.TREE_DEPTH = 3       -- material levels drawn under a recipe (its own materials are level 1)
M.MAX_TREE_LINES = 16  -- material lines in the whole tree

--- What a recipe needs, coloured for the player: "85 Smithing, 90 Prayer at Anvil", "at Ocellus", or "".
local function recipe_needs(rec, level_of)
  local how = {}
  for _, s in ipairs(rec.skills) do how[#how + 1] = M.requirement(s.level, s.name, level_of) end
  local text = table.concat(how, ", ")
  if rec.facility then text = (text ~= "" and (text .. " at ") or "at ") .. rec.facility end
  return text
end

--- "Air altar +9 more" / "Legio Primus 1/50": where a material comes from, best source first.
local function source_text(drops)
  local d = drops[1]
  local text = d.monster .. (d.reward and "" or (" " .. d.rarity))
  if #drops > 1 then text = text .. " +" .. (#drops - 1) .. " more" end
  return text
end

-- One line per material, then (indented) the materials of its own recipe, down to M.TREE_DEPTH levels. A material
-- with a usual source (M.usual_source), or with no recipe, shows where it drops; its recipe is then only an
-- alternative: grey, uncoloured, not followed.
local function material_tree(lines, rec, indent, depth, info, budget)
  for i, m in ipairs(rec.materials) do
    if i > M.MAX_MATERIALS then
      add(lines, indent .. "+" .. (#rec.materials - M.MAX_MATERIALS) .. " more materials", GREY)
      break
    end
    if budget.left <= 0 then
      budget.cut = true
      return
    end
    budget.left = budget.left - 1
    local text = indent .. m.quantity .. " x " .. m.name
    local trivial = M.is_trivial(m.name)
    local sub = not trivial and m.recipe or nil
    local drops = not trivial and m.drops or nil
    if drops and sub and not M.usual_source(drops) then drops = nil end -- rare or reward-only: making it is the way
    local follow = false
    if trivial then -- listed, nothing about how to get it
    elseif drops and drops[1] then
      text = text .. " - from " .. source_text(drops)
    elseif sub then
      local needs = recipe_needs(sub, info.level_of)
      text = text .. ": " .. (needs ~= "" and needs or "made from")
      if sub.quest then text = text .. " " .. colour_words("(quest: " .. sub.quest .. ")", GREY) end
      follow = true
    end
    add(lines, text)
    if drops and drops[1] and sub then
      local needs = M.plain(recipe_needs(sub, nil)) -- no red/green: it is not required
      if needs ~= "" then add(lines, indent .. "  or made: " .. needs, GREY) end
    end
    if follow and depth < M.TREE_DEPTH then material_tree(lines, sub, indent .. "  ", depth + 1, info, budget) end
  end
end

local function drop_text(d)
  return d.monster .. " " .. d.rarity .. (d.levels ~= "" and (" (" .. d.levels .. ")") or "")
end

--- Tooltip lines (game markup) for `info`:
---   name, base_name (augmented items), reqs = wear_requirements(), status = nil | "loading" | "error: ..."
---   page, drops, recipes, stores (the shown recipe's materials carry .drops and .recipe, see lookup.lua)
---   level_of = function(skill name) -> the player's level, or nil: wear and recipe requirements turn green or red
function M.tooltip_lines(info)
  local lines = {}
  local level_of = info.level_of
  add(lines, info.name or "Unknown item", GOLD)
  if info.base_name and info.base_name ~= info.name then add(lines, "Sources shown for " .. info.base_name, GREY) end

  local quests = info.quests or {}
  if info.reqs and #info.reqs > 0 then
    local parts = {}
    for i, r in ipairs(info.reqs) do parts[i] = M.requirement(r.level, r.skill, level_of) end
    add(lines, "To wear: " .. table.concat(parts, ", "))
  elseif #quests == 0 then
    add(lines, "To wear: no requirement in the item data", GREY)
  end
  if #quests > 0 then
    local parts = {}
    for i, q in ipairs(quests) do parts[i] = M.quest_requirement(q.name, q.done) end
    add(lines, (#quests == 1 and "Quest to wear: " or "Quests to wear: ") .. table.concat(parts, ", "))
  end

  if info.status == "loading" then
    add(lines, "Looking it up on the RuneScape Wiki...", GREY)
    return lines
  elseif info.status then
    add(lines, "Wiki lookup failed: " .. tostring(info.status), ORANGE)
    return lines
  end

  local drops, recipes, stores = info.drops or {}, info.recipes or {}, info.stores or {}
  local monsters, rewards = {}, {}
  for _, d in ipairs(drops) do
    if d.reward then rewards[#rewards + 1] = d.monster else monsters[#monsters + 1] = d end
  end
  if #monsters > 0 then
    lines[#lines + 1] = GOLD .. "Dropped by</col>"
    for i = 1, math.min(#monsters, M.MAX_DROPS) do add(lines, "  " .. drop_text(monsters[i])) end
    if #monsters > M.MAX_DROPS then add(lines, "  +" .. (#monsters - M.MAX_DROPS) .. " more", GREY) end
  end
  if #rewards > 0 then
    local shown = {}
    for i = 1, math.min(#rewards, 3) do shown[i] = rewards[i] end
    add(lines, "Also from: " .. table.concat(shown, ", ") .. (#rewards > 3 and (" +" .. (#rewards - 3) .. " more") or ""),
      GREY)
  end

  local rec = M.pick_recipe(recipes)
  if rec then
    local needs = recipe_needs(rec, level_of)
    local head = #rec.skills > 0 and ("Needs " .. needs) or (rec.facility and ("Made " .. needs) or "Made from")
    lines[#lines + 1] = GOLD .. "How it's made</col>"
    add(lines, "  " .. head)
    if rec.quest then add(lines, "  Needs quest: " .. rec.quest, GREY) end
    local budget = { left = M.MAX_TREE_LINES }
    material_tree(lines, rec, "  ", 1, info, budget)
    if budget.cut then add(lines, "  (more materials on the wiki)", GREY) end
    if #recipes > 1 then add(lines, "  (" .. (#recipes - 1) .. " other recipe" .. (#recipes > 2 and "s" or "") .. " on the wiki)", GREY) end
  end

  if #stores > 0 then
    lines[#lines + 1] = GOLD .. "Sold by</col>"
    for i = 1, math.min(#stores, M.MAX_STORES) do
      local s = stores[i]
      add(lines, "  " .. s.store .. (s.price and (" (" .. M.thousands(s.price) .. " " .. s.currency .. ")") or ""))
    end
  end

  if #drops == 0 and not rec and #stores == 0 then
    add(lines, "No drop, recipe or shop for it on the wiki. It may be a reward: see the '" ..
      tostring(info.page or info.name) .. "' page.", GREY)
  end
  return lines
end

return M
