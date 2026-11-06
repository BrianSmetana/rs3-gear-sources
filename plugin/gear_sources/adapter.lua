-- Binds Gear Sources to the client. Layout verified with tools/probes/inspect_probe (2026-10-23):
--   inspecting a player opens interface 1558 (TOPLEVEL_V2_INSPECT_WORN); its static 8 (ITEM_LAYER) holds one dynamic
--   type-3 component per worn item, whose associatedObjectID is the item id and whose isMouseOver is true while
--   hovered; xyGlobal is in the same pixels as the mouse.
--   Wear requirements are item params WEAR_REQUIRES_STATn / WEAR_REQUIRES_STAT_LEVELn; augmented items name their
--   base item in INVENT_BASE_OBJECT.
-- STILL UNVERIFIED: HTTPS requests to runescape.wiki from the client, and the tooltip's look (font, line height).

local core = require("core")
local lookup = require("lookup")
local tooltip = require("tooltip")

local M = {}

local IFACE, ITEM_LAYER = 1558, 8
local POLL_EVERY = 3 -- Logic ticks (50 a second) between hover checks
local MAX_IN_FLIGHT = 2
local USER_AGENT = "RS3 Gear Sources plugin (in-game item source tooltip)"

local function get(c, name)
  local ok, v = pcall(function() return c[name] end)
  if ok then return v end
  return nil -- one value, not none: tostring(get(...)) must not fail on a missing field
end

local LOG_LINES = 80 -- kept in PersistentDB key "log", so a session can be read back from PluginData.db

function M.start(G)
  local say = G.log or print
  local history, history_dirty, seq = {}, false, 0
  local function log(m)
    say("[GearSources] " .. m)
    seq = seq + 1
    history[#history + 1] = seq .. " " .. m
    while #history > LOG_LINES do table.remove(history, 1) end
    history_dirty = true
  end
  local function save_log()
    if not history_dirty or not G.PersistentDB then return end
    history_dirty = false
    pcall(function() G.PersistentDB:SetString("log", table.concat(history, "\n")) end)
  end

  -- ---------------------------------------------------------------- HTTP, a couple of requests at a time

  local queue, in_flight = {}, 0

  local function has_http()
    local ok, v = pcall(function() return G.Plugin.HasPermission(G.PluginPermissions.httpAccess) end)
    return ok and v
  end

  local pump
  local function finish(job, ok, body)
    in_flight = in_flight - 1
    local fine, err = pcall(job.cb, ok, body)
    if not fine then log("lookup callback failed: " .. tostring(err)) end
    pump()
  end

  function pump()
    while in_flight < MAX_IN_FLIGHT and #queue > 0 do
      local job = table.remove(queue, 1)
      in_flight = in_flight + 1
      local started, err = pcall(function()
        local req = G.HTTPRequest.new(G.Plugin.urls.wiki, job.path)
        pcall(function() req:AddHeader("User-Agent", USER_AGENT) end)
        req:Get(function(r)
          local code = get(r, "responseCode")
          if get(r, "successful") and (code == nil or code == 200) then
            finish(job, true, tostring(get(r, "data") or ""))
          else
            local why = "HTTP " .. tostring(code)
            if get(r, "timedOut") then why = why .. ", timed out" end
            local info = get(r, "errorInfo")
            if info and tostring(info) ~= "" then why = why .. ", " .. tostring(info) end
            finish(job, false, why)
          end
        end)
      end)
      if not started then finish(job, false, "request failed: " .. tostring(err)) end
    end
  end

  local function http_get(path, cb)
    if not has_http() then
      return cb(false, "httpAccess not granted (console: ppe gear_sources httpAccess, then prl gear_sources)")
    end
    queue[#queue + 1] = { path = path, cb = cb }
    pump()
  end

  -- ---------------------------------------------------------------- item data from the game

  local items = {} -- item id -> { name, reqs, lookup_id, lookup_name, base_name }

  local function obj_name(id)
    local ok, n = pcall(function() return G.config.Obj.FromID(id).name end)
    return ok and n and tostring(n) or nil
  end

  -- Quests to wield are item params WEAR_REQUIRES_QUEST1, 2, ... holding a quest's QUEST_ID param (1345), not its
  -- config id: the dragon scimitar's 73 is Monkey Madness (config 130, QUEST_ID 73). Only the current quest configs
  -- carry QUEST_ID; the deprecated duplicates (Lost City 42 vs 262) do not. Verified in game 2026-10-23. (ObjType.quests
  -- is empty for these items.) The QUEST_ID -> quest table is built once, on first need.
  local quest_by_number
  local function quest_numbered(n)
    if not quest_by_number then
      quest_by_number = {}
      local qid_param
      pcall(function() qid_param = G.config.Param.QUEST_ID end)
      pcall(function()
        for k, v in pairs(G.id.Quest) do
          local cid = type(k) == "number" and k or v
          local ok, q = pcall(function() return G.config.Quest.FromID(cid) end)
          if ok and q and not get(q, "deprecated") then
            local num
            if qid_param then
              pcall(function() if q:HasParam(qid_param) then num = tonumber(q:GetParamValue(qid_param)) end end)
            else
              for _, p in ipairs(get(q, "params") or {}) do
                if get(p, "configName") == "QUEST_ID" then pcall(function() num = tonumber(q:GetParamValue(p)) end) end
              end
            end
            if num then quest_by_number[num] = q end
          end
        end
      end)
      local n = 0
      for _ in pairs(quest_by_number) do n = n + 1 end
      log("quest numbers indexed: " .. n .. " quests")
    end
    return quest_by_number[n]
  end

  -- Returns the item's skill requirements, its base item (augmented gear) and the quests needed to wield it, kept as
  -- the client's QuestType proxies so `hasFinishedQuest` is read fresh each time the tooltip is drawn.
  local function read_params(id)
    local cfg = G.config.Obj.FromID(id)
    local params, base, quests, seen = {}, nil, {}, {}
    for _, p in ipairs(get(cfg, "params") or {}) do
      local name = tostring(get(p, "configName"))
      if name:find("^WEAR_REQUIRES_STAT") or name:find("^WEAR_REQUIRES_QUEST%d+$") or name == "INVENT_BASE_OBJECT" then
        local ok, v = pcall(function() return cfg:GetParamValue(p) end)
        if ok then
          if name == "INVENT_BASE_OBJECT" then
            base = tonumber(get(v, "id")) or tonumber(v)
          elseif name:find("^WEAR_REQUIRES_QUEST") then
            local n = tonumber(v)
            if n and n >= 0 and not seen[n] then
              seen[n] = true
              local q = quest_numbered(n)
              if q then quests[#quests + 1] = q
              else log("item " .. id .. ": " .. name .. " = " .. n .. " matches no quest") end
            end
          else
            params[#params + 1] = { name = name, value = v }
          end
        end
      end
    end
    return core.wear_requirements(params), base, quests
  end

  local function item(id)
    local it = items[id]
    if it then return it end
    it = { name = obj_name(id) or ("item " .. id), reqs = {}, quests = {}, lookup_id = id }
    local ok, reqs, base, quests = pcall(read_params, id)
    if ok then
      it.reqs, it.quests = reqs, quests
      if base and base >= 0 and base ~= id then
        it.lookup_id, it.base_name = base, obj_name(base)
        local ok2, base_reqs, _, base_quests = pcall(read_params, base)
        if ok2 then
          if #it.reqs == 0 then it.reqs = base_reqs end
          if #it.quests == 0 then it.quests = base_quests end
        end
      end
    else
      log("reading params of item " .. id .. " failed: " .. tostring(reqs))
    end
    it.lookup_name = it.base_name or it.name
    items[id] = it
    return it
  end

  -- ---------------------------------------------------------------- hover and tooltip

  local tip = tooltip.new(G, log)
  local slots, shown = {}, nil
  local wiki

  local function anchor_of(c)
    local g = get(c, "xyGlobal")
    return { x = tonumber(g and get(g, "x")) or 0, y = tonumber(g and get(g, "y")) or 0,
             w = tonumber(get(c, "width")) or 36, h = tonumber(get(c, "height")) or 32 }
  end

  -- The game's own item tooltip (interface 1486 TEXT_TOOLTIP) is drawn above the plugin layer and covered our box
  -- when it sat next to the slot (seen in game 2026-10-23), so the box goes beside it. Its bounds are the union of
  -- its visible static components, leaving out any that span (nearly) the whole screen, such as a root layer.
  local GAME_TIP = 1486
  local game_tip_statics = {}
  pcall(function()
    for combined in pairs(G.id.Component) do
      if math.type(combined) == "integer" and (combined >> 16) == GAME_TIP then
        game_tip_statics[#game_tip_statics + 1] = combined
      end
    end
  end)

  local function game_tip_rect()
    local open = false
    pcall(function() open = G.ui.Interfaces:GetInterface(GAME_TIP) ~= nil end)
    if not open then return nil end
    local layer = G.ui.Interfaces:GetComponent(G.id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    local sw, sh = tonumber(layer and get(layer, "width")) or 1e9, tonumber(layer and get(layer, "height")) or 1e9
    local x1, y1, x2, y2
    for _, combined in ipairs(game_tip_statics) do
      local ok, c = pcall(function() return G.ui.Interfaces:GetComponent(combined) end)
      if ok and c and get(c, "visibleGlobal") ~= false then
        local r = anchor_of(c)
        if r.w > 0 and r.h > 0 and r.w < 0.9 * sw and r.h < 0.9 * sh then
          x1, y1 = math.min(x1 or r.x, r.x), math.min(y1 or r.y, r.y)
          x2, y2 = math.max(x2 or r.x + r.w, r.x + r.w), math.max(y2 or r.y + r.h, r.y + r.h)
        end
      end
    end
    if not x1 then return nil end
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
  end

  -- The player's real (XP) level in a skill named as the wiki and core.SKILLS name it ("Smithing"), or nil when the
  -- client cannot say. Boosts are left out: they do not count towards wearing gear.
  local function level_of(skill)
    local ok, level = pcall(function()
      local st = G.SkillType[tostring(skill):upper()]
      if st == nil then return nil end
      return G.Player.GetLevelCapped(st)
    end)
    return ok and tonumber(level) or nil
  end

  -- { { name, done = true | false | nil (unknown) }, ... } for the tooltip, read now so a quest finished this session
  -- turns green.
  local function quest_states(quests)
    local out = {}
    for _, q in ipairs(quests or {}) do
      local done = get(q, "hasFinishedQuest")
      if done ~= true and done ~= false then done = nil end -- anything else: unknown
      out[#out + 1] = { name = tostring(get(q, "name")), done = done }
    end
    return out
  end

  local function rect_key(r)
    local f = math.floor
    return r and string.format("%d,%d %dx%d", f(r.x), f(r.y), f(r.w), f(r.h)) or "none"
  end

  local function render()
    if not shown then return end
    local it = item(shown.obj)
    local entry = wiki.get(it.lookup_id, it.lookup_name)
    local lines = core.tooltip_lines({
      name = it.name, base_name = it.base_name, reqs = it.reqs, status = entry.status, page = entry.page,
      drops = entry.drops, recipes = entry.recipes, stores = entry.stores,
      level_of = level_of, quests = quest_states(it.quests),
    })
    local anchor = anchor_of(shown.c)
    local ok, x, y, w, h = pcall(tip.show, lines, anchor, shown.avoid)
    if not ok then
      if not shown.failed then
        shown.failed = true
        log("tooltip failed: " .. tostring(x))
      end
    else
      local state = tostring(entry.status or "done") .. ", game tooltip " .. rect_key(shown.avoid)
      if shown.logged ~= state then -- once per hover, lookup state and game-tooltip position, not on every redraw
        shown.logged = state
        log(string.format("tooltip for %s (slot at %d,%d): box at %s,%s size %sx%s, %d lines, wiki %s; %s", it.name,
          anchor.x, anchor.y, tostring(x), tostring(y), tostring(w), tostring(h), #lines, state, tip.describe()))
      end
    end
  end

  wiki = lookup.new(http_get, function(key)
    if shown and tostring(item(shown.obj).lookup_id) == key then render() end
  end, log)

  local last_count = 0
  local function scan()
    slots = {}
    local ok = pcall(function()
      if G.ui.Interfaces:GetInterface(IFACE) == nil then return end
      local layer = G.ui.Interfaces:GetComponent(IFACE, ITEM_LAYER)
      if not layer then return end
      layer:IterateDynamicComponents(function(c)
        local obj = get(c, "associatedObjectID")
        if obj and obj >= 0 then slots[#slots + 1] = { c = c, obj = obj } end
        return false
      end)
    end)
    if not ok then slots = {} end
    if #slots ~= last_count then
      last_count = #slots
      log(#slots > 0 and ("inspect screen: " .. #slots .. " worn items") or "inspect screen closed")
    end
  end

  local function poll()
    local hit
    for _, s in ipairs(slots) do
      if get(s.c, "isMouseOver") then hit = s break end
    end
    if not hit then
      if shown then pcall(tip.hide) shown = nil end
      return
    end
    -- the game's tooltip appears a moment after the hover and can move, so the box follows it
    local ok, avoid = pcall(game_tip_rect)
    avoid = ok and avoid or nil
    local key = rect_key(avoid)
    if shown and shown.c == hit.c and shown.obj == hit.obj then
      if key ~= shown.avoid_key then
        shown.avoid, shown.avoid_key = avoid, key
        render()
      end
      return
    end
    shown = { c = hit.c, obj = hit.obj, avoid = avoid, avoid_key = key }
    render()
  end

  -- ---------------------------------------------------------------- events

  -- A grant does not always raise OptionalPermissionChanged, so the permission is also checked every server tick:
  -- when it turns on, lookups that failed for want of it are retried and the tooltip on screen is redrawn.
  local http_was = has_http()
  G.Event.ServerLogic.Subscribe("gearSourcesScan", function()
    local http_now = has_http()
    if http_now ~= http_was then
      http_was = http_now
      log("httpAccess is now " .. (http_now and "granted: wiki lookups on" or "revoked"))
      if http_now then
        wiki.retry_failed()
        if shown then render() end
      end
    end
    local ok, err = pcall(scan)
    if not ok then log("scan failed: " .. tostring(err)) end
    if #slots == 0 and shown then pcall(tip.hide) shown = nil end
    save_log()
  end)

  local logic = 0
  G.Event.Logic.Subscribe("gearSourcesHover", function()
    logic = logic + 1
    if logic % POLL_EVERY ~= 0 or #slots == 0 then return end
    local ok, err = pcall(poll)
    if not ok then log("hover check failed: " .. tostring(err)) end
  end)

  G.Event.OptionalPermissionChanged.Subscribe("gearSourcesPerm", function(e)
    log("permission " .. tostring(get(e, "permissionName")) .. " enabled = " .. tostring(get(e, "enabled")))
    wiki.retry_failed()
    if shown then render() end
  end)


  log(has_http() and "ready: inspect a player and hover their gear"
    or "ready, but httpAccess is not granted: only wear requirements will show " ..
       "(console: ppe gear_sources httpAccess, then prl gear_sources)")

  local app = {}
  function app.shutdown()
    for event, ref in pairs({ ServerLogic = "gearSourcesScan", Logic = "gearSourcesHover",
                              OptionalPermissionChanged = "gearSourcesPerm" }) do
      pcall(function() G.Event[event].Unsubscribe(ref) end)
    end
    pcall(tip.destroy)
  end
  -- for tests
  app.wiki, app.item = wiki, item
  return app
end

return M
