-- The tooltip box, built the way the PrettyUI plugin builds its own tooltips (its src/tooltip.lua draws text that
-- shows in game): a root Layer on the plugin build layer holding a filled rectangle, a 1 px border and a Text, the
-- children positioned relative to the root and the root moved as a whole. The first version created the three
-- directly on the build layer with a guessed font (NOTOSANS_REGULAR_11) and AlignTo(); its box drew but its text
-- did not (seen in game 2026-10-23).

local M = {}

local PAD, GAP = 8, 8
local LINE_H = 18      -- PrettyUI's body line height for MUSEO_SANS_15PT_REGULAR
local CHAR_W = 7       -- fallback width per character when the font cannot measure
local MAX_W = 480
local FONT = "MUSEO_SANS_15PT_REGULAR"

local function get(c, name)
  local ok, v = pcall(function() return c[name] end)
  if ok then return v end
  return nil -- one value, not none: tostring(get(...)) must not fail on a missing field
end

--- A line of game markup without its tags (<col=..>, </col>).
function M.plain(line)
  return (tostring(line):gsub("<[^>]*>", ""))
end

--- Box size for `lines` and its position next to `anchor` ({ x, y, w, h }, screen pixels) inside a screen of
--- `sw` x `sh` (nil when unknown): to the right of the slot, or to its left when it would run off screen.
--- `avoid` (optional, same shape) is the game's own tooltip, which is drawn above the plugin layer and would cover
--- the box: when given, the box goes beside it instead (right, else left), top-aligned with it.
--- `measure(plain_line)` gives a line's width in pixels (default: CHAR_W per character).
function M.layout(lines, anchor, sw, sh, avoid, measure)
  measure = measure or function(s) return #s * CHAR_W end
  local longest = 0
  for _, l in ipairs(lines) do longest = math.max(longest, measure(M.plain(l))) end
  local w = math.min(MAX_W, longest + 2 * PAD + 4)
  local h = #lines * LINE_H + 2 * PAD
  local near = avoid or anchor
  local x = near.x + near.w + GAP
  if sw and x + w > sw then x = near.x - w - GAP end
  if x < 0 then x = 0 end
  local y = near.y
  if sh and y + h > sh then y = sh - h end
  if y < 0 then y = 0 end
  return x, y, w, h
end

function M.new(G, log)
  local self = {}
  local parts = nil

  local function destroy()
    if not parts then return end
    pcall(function() parts.root:Destroy() end) -- takes its children with it
    parts = nil
  end

  local function parent()
    return G.ui.Interfaces:GetComponent(G.id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
  end

  local function alive()
    if not parts then return false end
    local ok = pcall(function() return parts.text.content end)
    return ok
  end

  -- Text width in pixels from the font itself when the client can measure it (PrettyUI: font:GetStringWidth).
  local font_cfg = nil
  pcall(function() font_cfg = G.config.Font[FONT] end)
  local function measure(s)
    if font_cfg then
      local ok, w = pcall(function() return font_cfg:GetStringWidth(s, false) end)
      if ok and tonumber(w) then return tonumber(w) end
    end
    return #s * CHAR_W
  end

  local function build()
    destroy()
    local p = parent()
    if not p then error("plugin build layer not found") end
    local root = G.ui.Layer.new(p)
    root.hidden = true
    root.clickthrough = true -- never take the hover away from the slot underneath

    local bg = G.ui.Rectangle.new(root)
    bg.fill = true
    bg.rgba = 0x1E1A14EB
    bg:SetPos(0, 0)
    bg:SetSize(0, 0, 1.0, 1.0)
    bg.clickthrough = true

    local border = G.ui.Rectangle.new(root)
    border.fill = false
    border.rgba = 0x6B5A3AFF
    border:SetPos(0, 0)
    border:SetSize(0, 0, 1.0, 1.0)
    border.clickthrough = true

    local text = G.ui.Text.new(root) -- created last, so it draws above the rectangles
    text:SetPos(PAD, PAD)
    text:SetSize(-PAD * 2, -PAD * 2, 1.0, 1.0)
    text.font = get(G.id.Font, FONT)
    text.rgba = 0xFFFFFFFF
    text.isShadowed = true
    text.maxLines = 0
    text.clickthrough = true
    pcall(function()
      text.alignHorizontal = G.ui.AlignMode.TOPLEFT
      text.alignVertical = G.ui.AlignMode.TOPLEFT
    end)

    parts = { root = root, text = text }
    local g = get(p, "xyGlobal")
    log(string.format("tooltip built on plugin layer at %s,%s size %sx%s; font %s = %s, measures text: %s",
      tostring(g and get(g, "x")), tostring(g and get(g, "y")), tostring(get(p, "width")), tostring(get(p, "height")),
      FONT, tostring(text.font), tostring(font_cfg ~= nil)))
  end

  --- Shows `lines` next to `anchor` ({ x, y, w, h } in screen pixels), beside `avoid` when given (see M.layout).
  --- Returns the box's x, y, w, h.
  function self.show(lines, anchor, avoid)
    if not alive() then build() end
    local p = parent()
    local x, y, w, h = M.layout(lines, anchor, p and get(p, "width"), p and get(p, "height"), avoid, measure)
    parts.root:SetSize(w, h)
    parts.root:SetPos(x, y)
    parts.text.content = table.concat(lines, "<br>")
    parts.root.hidden = false
    pcall(function() parts.root:MoveToFront() end)
    return x, y, w, h
  end

  --- What the client reports about the text, for the log: whether it thinks it is visible, and where.
  function self.describe()
    if not parts then return "no tooltip" end
    local t = parts.text
    local g = get(t, "xyGlobal")
    return string.format("text visible %s at %s,%s size %sx%s, %d chars", tostring(get(t, "visibleGlobal")),
      tostring(g and get(g, "x")), tostring(g and get(g, "y")), tostring(get(t, "width")), tostring(get(t, "height")),
      #tostring(get(t, "content") or ""))
  end

  function self.hide()
    if parts then pcall(function() parts.root.hidden = true end) end
  end

  self.destroy = destroy
  return self
end

return M
