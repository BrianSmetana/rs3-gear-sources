-- Entry point run by the RS client when the plugin is enabled (pon gear_sources).
-- Logic lives in adapter.lua so it can be tested with mock globals (test/run.lua).
local function say(m) print("[GearSources] " .. m) end

local function trace(e)
  if debug and debug.traceback then return debug.traceback(tostring(e), 2) end
  return tostring(e)
end

local loaded = true
for _, m in ipairs({ "json", "core", "lookup", "tooltip", "adapter" }) do
  local ok, err = xpcall(function()
    if require(m) == nil then error("require returned nil (file missing?)") end
  end, trace)
  if not ok then
    say("require " .. m .. " FAILED\n" .. tostring(err))
    pcall(function() PersistentDB:SetString("log", "require " .. m .. " FAILED\n" .. tostring(err)) end)
  end
  loaded = loaded and ok
end

local app
if loaded then
  local ok, err = xpcall(function()
    app = require("adapter").start({
      Event = Event,
      HTTPRequest = HTTPRequest,
      Plugin = Plugin,
      PluginPermissions = PluginPermissions,
      log = log,
      PersistentDB = PersistentDB, -- the plugin's log is kept under key "log" for reading back from PluginData.db
      ui = ui,
      id = id,
      config = config, -- the client's config tables: config.Obj.FromID(id) gives an item's name and params
      Player = Player, -- Player.GetLevelCapped(SkillType.MAGIC): your level, to colour requirements met or not
      SkillType = SkillType,
    })
  end, trace)
  if not ok then
    say("start FAILED\n" .. tostring(err))
    pcall(function() PersistentDB:SetString("log", "start FAILED\n" .. tostring(err)) end)
  end
end

-- Run by the client when the plugin is disabled or reloaded: remove the tooltip and event hooks.
function PluginShutdown()
  if app and app.shutdown then pcall(app.shutdown) end
end
