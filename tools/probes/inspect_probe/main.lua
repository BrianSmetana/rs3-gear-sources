-- Inspect probe: finds the player-inspect screen (right-click a player > Examine/Inspect) and how a plugin can read
-- and hover its worn items. Everything it learns goes into PersistentDB key "report" (read it from PluginData.db),
-- and short notes go to the console. Five questions:
--   1. which interface opens when you inspect a player, and which components hold the worn items (associatedObjectID)
--   2. whether hovering an item shows up through isMouseOver, ONMOUSEOVER, the mouse position, or the MiniMenu
--   3. whether the worn items also arrive as an inventory (InventoryAdded / InventoryUpdated)
--   4. which item params hold the wear requirements (dumped for every item seen, plus two known items)
--   5. whether HTTPRequest can reach the RS Wiki API (needs: ppe inspect_probe httpAccess)
-- Work is spread over ticks: each client callback is cut off after 1000 ms.

local TAG = "[InspectProbe] "
local function say(m) print(TAG .. m) end

local function get(c, name)
  local ok, v = pcall(function() return c[name] end)
  if ok then return v end
end

-- ---------------------------------------------------------------- report

local sections, order, dirty = {}, {}, false
local function set_section(name, text)
  if sections[name] == nil then order[#order + 1] = name end
  if sections[name] ~= text then sections[name], dirty = text, true end
end

-- A capped log: one section that keeps its last `cap` lines.
local logs = {}
local function log_line(name, line, cap)
  local l = logs[name]
  if not l then l = {} logs[name] = l end
  l[#l + 1] = line
  while #l > (cap or 40) do table.remove(l, 1) end
  set_section(name, table.concat(l, "\n"))
end

local function save()
  if not dirty then return end
  dirty = false
  local out = {}
  for _, name in ipairs(order) do out[#out + 1] = "=== " .. name .. " ===\n" .. sections[name] end
  pcall(function() PersistentDB:SetString("report", table.concat(out, "\n\n"):sub(1, 200000)) end)
end

-- ---------------------------------------------------------------- environment

do
  local env = {}
  for _, n in ipairs({ "Event", "HTTPRequest", "PersistentDB", "Plugin", "PluginPermissions", "Mouse", "MiniMenu",
                       "ui", "id", "config", "var", "Player" }) do
    env[#env + 1] = n .. " = " .. type(_ENV[n])
  end
  local ok, avail = pcall(function() return Mouse.IsAvailable() end)
  env[#env + 1] = "Mouse.IsAvailable() = " .. tostring(ok and avail or "error")
  for _, n in ipairs({ "Logic", "Draw", "ServerLogic", "MiniMenuReady", "InventoryAdded", "InventoryUpdated" }) do
    env[#env + 1] = "Event." .. n .. " = " .. type(get(Event, n))
  end
  env[#env + 1] = "ui.Hook.ONMOUSEOVER = " .. tostring(get(get(ui, "Hook") or {}, "ONMOUSEOVER"))
  set_section("env", table.concat(env, "\n"))
end

-- ---------------------------------------------------------------- interface names

local iface_name, iface_ids = {}, {}
pcall(function()
  for k, v in pairs(id.Interface) do
    local iid = type(k) == "number" and k or v
    if type(iid) == "number" then
      iface_name[iid] = type(k) == "string" and k or tostring(v)
      iface_ids[#iface_ids + 1] = iid
    end
  end
end)
table.sort(iface_ids)

-- Interfaces whose names suggest the inspect screen. v1 only scanned interfaces that opened after the probe started,
-- and saw none of these open, so they are now scanned whenever loaded, including ones already open at start.
local candidate = {}
do
  local hits = {}
  for _, iid in ipairs(iface_ids) do
    local n = iface_name[iid]:upper()
    if n:find("INSPECT") or n:find("EXAMINE") or n:find("WORN") or n:find("EQUIP") then
      hits[#hits + 1] = iid .. " " .. iface_name[iid]
      candidate[iid] = true
    end
  end
  set_section("interface names (INSPECT/EXAMINE/WORN/EQUIP)", #hits > 0 and table.concat(hits, "\n") or "(none)")
end

local statics = {} -- interface id -> list of { combined, name } for its static components
pcall(function()
  for combined, cname in pairs(id.Component) do
    if math.type(combined) == "integer" and combined > 0 then
      local iid = combined >> 16
      statics[iid] = statics[iid] or {}
      table.insert(statics[iid], { combined = combined, name = tostring(cname) })
    end
  end
end)
say("indexed " .. #iface_ids .. " interfaces")

local function loaded(iid)
  local ok, i = pcall(function() return ui.Interfaces:GetInterface(iid) end)
  return ok and i ~= nil
end

local function obj_name(obj)
  local ok, n = pcall(function() return config.Obj.FromID(obj).name end)
  return ok and tostring(n) or "?"
end

-- ---------------------------------------------------------------- params

local param_queue, param_seen = { 4151, 1127 }, { [4151] = true, [1127] = true } -- Abyssal whip, Rune platebody
local param_lines = {}

local function describe(v)
  local t = type(v)
  if t == "userdata" or t == "table" then
    local cn, i = get(v, "configName"), get(v, "id")
    if cn or i then return tostring(cn) .. "#" .. tostring(i) end
  end
  return tostring(v)
end

local function dump_params(obj)
  local cfg = config.Obj.FromID(obj)
  local out = { obj .. " " .. tostring(get(cfg, "name")) .. " (configName " .. tostring(get(cfg, "configName")) .. ")" }
  local params = get(cfg, "params") or {}
  for _, p in ipairs(params) do
    local ok, v = pcall(function() return cfg:GetParamValue(p) end)
    out[#out + 1] = "  param " .. tostring(get(p, "id")) .. " " .. tostring(get(p, "configName")) .. " = " ..
      (ok and describe(v) or ("error " .. tostring(v)))
  end
  if #params == 0 then out[#out + 1] = "  (no params)" end
  param_lines[#param_lines + 1] = table.concat(out, "\n")
  set_section("item params", table.concat(param_lines, "\n"))
end

local function want_params(obj)
  if obj and obj >= 0 and not param_seen[obj] then
    param_seen[obj] = true
    param_queue[#param_queue + 1] = obj
  end
end

-- ---------------------------------------------------------------- scanning an interface for item slots

local watch = {} -- interface id -> list of { c, obj, key, rect } for hover checks
local scan_results = {}
local hooked = {}

local function slot_rect(c)
  local g = get(c, "xyGlobal")
  local gx, gy = g and get(g, "x"), g and get(g, "y")
  return { x = gx, y = gy, w = get(c, "width"), h = get(c, "height") }
end

local function scan(iid)
  local found, texts, nodes = {}, {}, 0
  local function visit(c, label, depth)
    nodes = nodes + 1
    if nodes > 600 or depth > 6 then return end
    local obj = get(c, "associatedObjectID")
    if obj ~= nil and obj >= 0 then
      local r = slot_rect(c)
      found[#found + 1] = {
        c = c, obj = obj, rect = r,
        key = label .. " cat " .. tostring(get(c, "categoryID")) .. " dyn " .. tostring(get(c, "dynamicID")),
        line = string.format("%s cat %s dyn %s type %s: obj %d %s qty %s | local %s,%s %sx%s | global %s,%s | visible %s",
          label, tostring(get(c, "categoryID")), tostring(get(c, "dynamicID")), tostring(get(c, "type")),
          obj, obj_name(obj), tostring(get(c, "associatedObjectQuantity")), tostring(get(c, "x")),
          tostring(get(c, "y")), tostring(r.w), tostring(r.h), tostring(r.x), tostring(r.y),
          tostring(get(c, "visibleGlobal"))),
      }
      want_params(obj)
    end
    local t = get(c, "content")
    if t ~= nil and tostring(t) ~= "" and #texts < 40 then
      texts[#texts + 1] = label .. ": " .. tostring(t):gsub("[\r\n]", " "):sub(1, 80)
    end
    pcall(function() c:IterateStaticComponents(function(ch) visit(ch, label, depth + 1) return false end) end)
    pcall(function() c:IterateDynamicComponents(function(ch) visit(ch, label, depth + 1) return false end) end)
  end
  for _, s in ipairs(statics[iid] or {}) do
    local ok, c = pcall(function() return ui.Interfaces:GetComponent(s.combined) end)
    if ok and c then visit(c, "static " .. (s.combined & 0xFFFF) .. " " .. s.name, 1) end
  end
  return found, texts
end

-- ONMOUSEOVER on the game's own slots: may be refused (restricted components); the result is reported once.
local function try_hook(iid, slots)
  if hooked[iid] then return end
  hooked[iid] = true
  local ok_n, err = 0, nil
  for _, s in ipairs(slots) do
    local ok, e = pcall(function()
      s.c:Subscribe(ui.Hook.ONMOUSEOVER, "inspectprobe", function(_, x, y)
        log_line("hover", "ONMOUSEOVER: " .. obj_name(s.obj) .. " (" .. s.obj .. ") at " .. tostring(x) .. "," .. tostring(y) ..
          " [" .. s.key .. "]")
      end)
    end)
    if ok then ok_n = ok_n + 1 else err = err or tostring(e) end
  end
  log_line("hook results", iid .. " " .. tostring(iface_name[iid]) .. ": " .. ok_n .. "/" .. #slots .. " hooked" ..
    (err and (", first error: " .. err) or ""))
end

-- ---------------------------------------------------------------- tracking which interfaces open

local baseline, is_open = nil, {}
local scan_queue, queued = {}, {}
local function queue_scan(iid)
  if not queued[iid] then queued[iid] = true scan_queue[#scan_queue + 1] = iid end
end

local function track_interfaces()
  local now = {}
  for _, iid in ipairs(iface_ids) do if loaded(iid) then now[iid] = true end end
  if not baseline then
    baseline = now
    local n, cands = 0, {}
    for iid in pairs(now) do
      n = n + 1
      if candidate[iid] then cands[#cands + 1] = iid .. " " .. tostring(iface_name[iid]) queue_scan(iid) end
    end
    table.sort(cands)
    log_line("interfaces opened/closed", "baseline: " .. n .. " interfaces open at start; inspect/worn ones: " ..
      (#cands > 0 and table.concat(cands, ", ") or "none"))
  else
    for iid in pairs(now) do
      if not is_open[iid] then
        log_line("interfaces opened/closed", "OPEN  " .. iid .. " " .. tostring(iface_name[iid]))
        queue_scan(iid)
      end
    end
    for iid in pairs(is_open) do
      if not now[iid] then
        log_line("interfaces opened/closed", "CLOSE " .. iid .. " " .. tostring(iface_name[iid]))
        watch[iid] = nil
        hooked[iid] = nil
      end
    end
  end
  is_open = now
end

local function scan_next()
  local iid = table.remove(scan_queue, 1)
  if not iid then return end
  queued[iid] = nil
  if not is_open[iid] then return end
  local slots, texts = scan(iid)
  if #slots == 0 then
    -- an inspect/worn screen with no item components is still worth seeing: its texts show what it is
    if candidate[iid] and not scan_results[iid] then
      local lines = { "interface " .. iid .. " " .. tostring(iface_name[iid]) .. ": no item slots; texts:" }
      for _, t in ipairs(texts) do lines[#lines + 1] = "    " .. t end
      log_line("inspect/worn screens without item slots", table.concat(lines, "\n"), 20)
      scan_results[iid] = false
    end
    return
  end
  local first = watch[iid] == nil or #watch[iid] ~= #slots
  watch[iid] = slots
  local lines = { "interface " .. iid .. " " .. tostring(iface_name[iid]) .. ": " .. #slots .. " item slots" }
  for _, s in ipairs(slots) do lines[#lines + 1] = "  " .. s.line end
  lines[#lines + 1] = "  texts:"
  for _, t in ipairs(texts) do lines[#lines + 1] = "    " .. t end
  scan_results[iid] = table.concat(lines, "\n")
  local all = {}
  for _, v in pairs(scan_results) do if v then all[#all + 1] = v end end
  set_section("item slots in opened interfaces", table.concat(all, "\n\n"))
  if first then say("interface " .. iid .. " " .. tostring(iface_name[iid]) .. " has " .. #slots .. " item slots") end
  try_hook(iid, slots)
end

-- ---------------------------------------------------------------- hover checks (isMouseOver and mouse-in-rect)

local last_over, last_rect = nil, nil
local function check_hover()
  local mx, my = nil, nil
  pcall(function() mx, my = Mouse.GetX(), Mouse.GetY() end)
  local over, rect = nil, nil
  for iid, slots in pairs(watch) do
    for _, s in ipairs(slots) do
      if not over and get(s.c, "isMouseOver") then over = s end
      local r = s.rect
      if not rect and mx and r.x and r.w and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
        rect = s
      end
    end
  end
  local mouse = " mouse " .. tostring(mx) .. "," .. tostring(my)
  -- compared by key: a rescan replaces the slot tables, which must not count as a new hover
  if (over and over.key) ~= last_over then
    last_over = over and over.key
    if over then log_line("hover", "isMouseOver: " .. obj_name(over.obj) .. " (" .. over.obj .. ")" .. mouse .. " [" .. over.key .. "]") end
  end
  if (rect and rect.key) ~= last_rect then
    last_rect = rect and rect.key
    if rect then log_line("hover", "mouse in rect: " .. obj_name(rect.obj) .. " (" .. rect.obj .. ")" .. mouse .. " [" .. rect.key .. "]") end
  end
end

-- ---------------------------------------------------------------- MiniMenu: the entry under the cursor

local last_menu = nil
local function entry_text(e, label)
  local cd = get(e, "componentData")
  local oc = cd and get(cd, "objConfig")
  if not oc then return nil end
  local comp = get(cd, "component")
  return string.format("%s: '%s' obj %s %s, component iface %s static %s dyn %s, opIndex %s", label,
    tostring(get(e, "fullText")), tostring(get(oc, "id")), tostring(get(oc, "name")),
    tostring(comp and get(comp, "interfaceID")), tostring(comp and get(comp, "staticID")),
    tostring(comp and get(comp, "dynamicID")), tostring(get(cd, "opIndex")))
end

local function on_menu(e)
  local m = get(e, "miniMenu")
  local entries = m and get(m, "entries")
  if not entries or #entries == 0 then return end
  local text = entry_text(entries[#entries], "last") or entry_text(entries[1], "first")
  if text and text ~= last_menu then
    last_menu = text
    log_line("minimenu (item under cursor)", text .. " | " .. #entries .. " entries")
  end
end

-- ---------------------------------------------------------------- inventories

local inv_seen, inv_contents = {}, {}

-- v1 saw WORN_DISPLAY (670) update while inspecting: it may hold the inspected player's gear. Dump the contents of
-- any worn/inspect inventory whenever they change.
local function dump_inv(invtype, name)
  local inv = Inventory.Find(invtype)
  if not inv or not get(inv, "isValid") then return end
  local out = {}
  for i, slot in ipairs(inv:GetSlots() or {}) do
    local obj = get(slot, "obj")
    local oid = obj and get(obj, "id")
    if oid and oid >= 0 then
      out[#out + 1] = string.format("  slot %d: %d %s x%s", i, oid, tostring(get(obj, "name")), tostring(get(slot, "count")))
      want_params(oid)
    end
  end
  local text = name .. ": " .. tostring(get(inv, "usedSlotCount")) .. "/" .. tostring(get(inv, "slotCount")) ..
    " slots used\n" .. table.concat(out, "\n")
  if inv_contents[name] ~= text then
    inv_contents[name] = text
    log_line("worn/inspect inventory contents", text, 10)
  end
end

local function on_inv(kind, e)
  local inv = get(e, "inv")
  local cname = tostring(get(inv, "configName"))
  local key = tostring(get(inv, "id")) .. " " .. cname .. " " .. tostring(get(inv, "name"))
  local n = (inv_seen[key] or 0) + 1
  inv_seen[key] = n
  if n == 1 then log_line("inventories seen", kind .. " " .. key .. " (" .. tostring(inv) .. ")") end
  local upper = cname:upper()
  if upper:find("WORN") or upper:find("INSPECT") then
    local ok, err = pcall(dump_inv, inv, key)
    if not ok then log_line("worn/inspect inventory contents", key .. ": dump failed: " .. tostring(err), 10) end
  end
end

-- ---------------------------------------------------------------- wiki HTTP test

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", string.byte(ch)) end))
end

local http_paths = {
  "/api.php?action=bucket&format=json&query=" ..
    urlencode("bucket('infobox_item').select('page_name','item_id').where('item_id','4151').limit(1).run()"),
  "api.php?action=bucket&format=json&query=" ..
    urlencode("bucket('infobox_item').select('page_name','item_id').where('item_id','4151').limit(1).run()"),
}
local http_step, http_busy, http_done = 1, false, false

local function http_test()
  if http_done or http_busy then return end
  local granted = false
  pcall(function() granted = Plugin.HasPermission(PluginPermissions.httpAccess) end)
  if not granted then
    set_section("wiki http", "httpAccess not granted (run: ppe inspect_probe httpAccess)")
    return
  end
  local path = http_paths[http_step]
  if not path then http_done = true return end
  http_busy = true
  local ok, err = pcall(function()
    local req = HTTPRequest.new(Plugin.urls.wiki, path)
    pcall(function() req:AddHeader("User-Agent", "RS3 Gear Sources plugin (development probe)") end)
    req:Get(function(r)
      http_busy = false
      local body = tostring(get(r, "data") or "")
      log_line("wiki http", string.format("path %d: url %s | code %s successful %s failed %s timedOut %s error %s %s | %d bytes: %s",
        http_step, tostring(get(r, "url")), tostring(get(r, "responseCode")), tostring(get(r, "successful")),
        tostring(get(r, "failed")), tostring(get(r, "timedOut")), tostring(get(r, "errorCode")),
        tostring(get(r, "errorInfo")), #body, body:sub(1, 300)))
      if get(r, "successful") and body:find("Abyssal whip", 1, true) then http_done = true else http_step = http_step + 1 end
    end)
  end)
  if not ok then
    http_busy = false
    log_line("wiki http", "path " .. http_step .. " raised: " .. tostring(err))
    http_step = http_step + 1
  end
end

-- ---------------------------------------------------------------- events

local ticks = 0
Event.ServerLogic.Subscribe("inspectprobe", function()
  ticks = ticks + 1
  if ticks % 2 == 0 then
    track_interfaces()
  else
    scan_next()
  end
  -- re-scan open interfaces that had items, and open inspect/worn screens, now and then: they may fill in later
  if ticks % 10 == 0 then
    for iid in pairs(watch) do queue_scan(iid) end
    for iid in pairs(is_open) do if candidate[iid] and scan_results[iid] == nil then queue_scan(iid) end end
  end
  for _ = 1, 3 do
    local obj = table.remove(param_queue, 1)
    if not obj then break end
    local ok, err = pcall(dump_params, obj)
    if not ok then log_line("item params errors", obj .. ": " .. tostring(err)) end
  end
  if ticks % 5 == 0 then http_test() end
  save()
end)

local logic_n = 0
pcall(function()
  Event.Logic.Subscribe("inspectprobe", function()
    logic_n = logic_n + 1
    if logic_n % 5 == 0 then pcall(check_hover) end -- 10 times a second
  end)
end)

pcall(function() Event.MiniMenuReady.Subscribe("inspectprobe", function(e) pcall(on_menu, e) end) end)
pcall(function() Event.InventoryAdded.Subscribe("inspectprobe", function(e) pcall(on_inv, "added", e) end) end)
pcall(function() Event.InventoryUpdated.Subscribe("inspectprobe", function(e) pcall(on_inv, "updated", e) end) end)

function PluginShutdown()
  for _, n in ipairs({ "ServerLogic", "Logic", "MiniMenuReady", "InventoryAdded", "InventoryUpdated" }) do
    pcall(function() Event[n].Unsubscribe("inspectprobe") end)
  end
  for _, slots in pairs(watch) do
    for _, s in ipairs(slots) do pcall(function() s.c:Unsubscribe(ui.Hook.ONMOUSEOVER, "inspectprobe") end) end
  end
  save()
end

set_section("status", "running")
save()
say("running: inspect a player, hover each worn item, then close the screen")
