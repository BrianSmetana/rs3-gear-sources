-- Looks items up on the RS Wiki and caches the results for the session. Per item:
--   1. item id -> wiki page (infobox_item); the game's item name is used when the wiki has no page for the id
--   2. drops, recipes and stores of that page, in parallel
--   3. for the materials of its recipe, level by level (M.SUB_LEVELS deep): their drop sources and their recipes, two
--      queries per level in parallel. Each material gets `.drops` (who drops it, incl. skilling sources such as the
--      runecrafting altars for Magical thread) and `.recipe` (how it is made). A material with a usual source
--      (core.usual_source) is not followed further: its recipe is only an alternative, not a requirement.
-- `http_get(path, cb)` calls cb(true, body) or cb(false, reason); `on_update(key)` runs whenever an entry changes.

local core = require("core")

local M = {}

M.SUB_LEVELS = 2       -- levels of materials looked up under the item's own recipe
M.MAX_PER_LEVEL = 12   -- material names looked up per level

function M.new(http_get, on_update, log)
  local self = { cache = {} }
  log = log or function() end

  local function changed(key) if on_update then on_update(key) end end

  local function query(q, cb)
    http_get(core.api_path(q), function(ok, body)
      if not ok then return cb(nil, body) end
      local rows, err = core.parse_bucket(body)
      cb(rows, err)
    end)
  end

  local function fail(entry, key, why)
    if entry.status ~= "loading" then return end -- report the first failure only
    entry.status = tostring(why)
    log("lookup " .. key .. " failed: " .. entry.status)
    changed(key)
  end

  -- Looks up the materials in `frontier` (one level of the tree): their drops and recipes, then the next level under
  -- those that can only be made. `known[name]` = { recipe, drops } once looked up; false for a trivial material or the
  -- item itself (so loops end).
  local function materials(key, frontier, level, known, done)
    if level > M.SUB_LEVELS or #frontier == 0 then return done() end
    local names, asked = {}, {}
    for _, m in ipairs(frontier) do
      if known[m.name] == nil and core.is_trivial(m.name) then known[m.name] = false end -- listed, never looked up
      if known[m.name] == nil and not asked[m.name] and #names < M.MAX_PER_LEVEL then
        asked[m.name] = true
        names[#names + 1] = m.name
      end
    end

    local function attach()
      local next_frontier = {}
      for _, m in ipairs(frontier) do
        local k = known[m.name]
        if k then
          m.recipe = k.recipe
          m.drops = (#k.drops > 0) and k.drops or nil
          if k.recipe and not core.usual_source(m.drops) then -- made, not usually found: its materials are next
            for i, sub in ipairs(k.recipe.materials) do
              if i <= core.MAX_MATERIALS then next_frontier[#next_frontier + 1] = sub end
            end
          end
        end
      end
      materials(key, next_frontier, level + 1, known, done)
    end
    if #names == 0 then return attach() end

    local recipes, drops, left = nil, nil, 2
    local function part_done()
      left = left - 1
      if left > 0 then return end
      if not recipes then return done() end -- show what we have
      local by_recipe = core.recipes_by_output(recipes)
      local by_drop = {}
      for _, d in ipairs(drops or {}) do
        by_drop[d.item] = by_drop[d.item] or {}
        table.insert(by_drop[d.item], d)
      end
      for _, name in ipairs(names) do
        known[name] = { recipe = core.pick_recipe(by_recipe[name], true), drops = by_drop[name] or {} }
      end
      attach()
    end
    query(core.query_recipes(names), function(rows, err)
      if rows then recipes = core.recipes_from_rows(rows)
      else log("lookup " .. key .. ": material recipes failed: " .. tostring(err)) end
      part_done()
    end)
    query(core.query_drops(names), function(rows, err)
      if rows then drops = core.drops_from_rows(rows)
      else log("lookup " .. key .. ": material drops failed: " .. tostring(err)) end
      part_done()
    end)
  end

  local function details(entry, key)
    local page, left = entry.page, 3
    local function finish()
      entry.status = nil
      changed(key)
    end
    local function part_done()
      left = left - 1
      if left > 0 or entry.status ~= "loading" then return end
      local rec = core.pick_recipe(entry.recipes)
      if not rec then return finish() end
      local frontier = {}
      for i, m in ipairs(rec.materials) do
        if i <= core.MAX_MATERIALS then frontier[#frontier + 1] = m end
      end
      materials(key, frontier, 1, { [page] = false }, finish)
    end
    query(core.query_drops({ page }), function(rows, err)
      if not rows then return fail(entry, key, err) end
      entry.drops = core.drops_from_rows(rows)
      part_done()
    end)
    query(core.query_recipes(page), function(rows, err)
      if not rows then return fail(entry, key, err) end
      entry.recipes = core.recipes_from_rows(rows)
      part_done()
    end)
    query(core.query_stores(page), function(rows, err)
      if not rows then return fail(entry, key, err) end
      entry.stores = core.stores_from_rows(rows)
      part_done()
    end)
  end

  --- The cache entry for item `id` (the id to look up: the base item for augmented gear), starting a lookup the first
  --- time. `name` is the game's name for it, used if the wiki has no page for the id.
  --- Entry: { status = "loading" | nil (done) | error text, page, drops, recipes, stores }; the materials of the
  --- shown recipe carry `.drops` and `.recipe` (see step 3 above).
  function self.get(id, name)
    local key = tostring(id)
    local entry = self.cache[key]
    if entry then return entry end
    entry = { status = "loading", drops = {}, recipes = {}, stores = {} }
    self.cache[key] = entry
    query(core.query_page(id), function(rows, err)
      if not rows then return fail(entry, key, err) end
      entry.page = core.page_from_rows(rows) or name
      if not entry.page then return fail(entry, key, "no wiki page for item " .. key) end
      details(entry, key)
    end)
    return entry
  end

  --- Forget failed lookups so the next hover tries again (after the player grants httpAccess, say).
  function self.retry_failed()
    for key, entry in pairs(self.cache) do
      if entry.status and entry.status ~= "loading" then self.cache[key] = nil end
    end
  end

  return self
end

return M
