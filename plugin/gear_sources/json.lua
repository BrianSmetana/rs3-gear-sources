-- Minimal JSON decoder for the RS Wiki's API replies (the client has no JSON library).
-- Objects become tables keyed by string, arrays become 1-based lists; JSON null is M.null so arrays keep their length.

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)) end
  if cp < 0x10000 then
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local ESCAPES = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

--- Decodes `s`. Returns the value, or nil and an error message.
function M.decode(s)
  local pos = 1

  local function fail(msg) error({ json = "json: " .. msg .. " at " .. pos }, 0) end
  local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end

  local value

  local function str()
    pos = pos + 1 -- opening quote
    local buf = {}
    while true do
      local j = s:find('["\\]', pos)
      if not j then fail("unterminated string") end
      buf[#buf + 1] = s:sub(pos, j - 1)
      pos = j
      if s:sub(pos, pos) == '"' then pos = pos + 1 break end
      local e = s:sub(pos + 1, pos + 1)
      if e == "u" then
        local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or fail("bad \\u escape")
        pos = pos + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then -- surrogate pair
          local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        buf[#buf + 1] = utf8_char(cp)
      else
        buf[#buf + 1] = ESCAPES[e] or fail("bad escape")
        pos = pos + 2
      end
    end
    return table.concat(buf)
  end

  function value()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skip()
        if s:sub(pos, pos) ~= '"' then fail("expected key") end
        local k = str()
        skip()
        if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
        pos = pos + 1
        obj[k] = value()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then fail("expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = value()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then fail("expected ',' or ']'") end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif s:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif s:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return M.null
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then fail("unexpected character '" .. c .. "'") end
      pos = pos + #num
      return tonumber(num) or fail("bad number")
    end
  end

  local ok, res = pcall(function()
    local v = value()
    skip()
    if pos <= #s then fail("trailing data") end
    return v
  end)
  if ok then return res end
  if type(res) == "table" and res.json then return nil, res.json end
  return nil, "json: " .. tostring(res)
end

return M
