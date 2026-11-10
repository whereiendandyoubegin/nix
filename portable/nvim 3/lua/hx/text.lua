local U = require('hx.util')
local api = vim.api
local byte = string.byte

local Text = {}
Text.__index = Text

local cache = {}

local function new_buf_text(buf)
  local self = setmetatable({ buf = buf, lines = {}, starts = {} }, Text)
  self.tick = api.nvim_buf_get_changedtick(buf)
  self.nlines = api.nvim_buf_line_count(buf)
  self.total = api.nvim_buf_get_offset(buf, self.nlines)
  return self
end

function Text.get(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local t = cache[buf]
  if t and t.tick == api.nvim_buf_get_changedtick(buf) and api.nvim_buf_line_count(buf) == t.nlines then
    return t
  end
  t = new_buf_text(buf)
  cache[buf] = t
  return t
end

function Text.invalidate(buf)
  cache[buf] = nil
end

function Text.from_string(s)
  local self = setmetatable({ str = s, lines = {}, starts = {} }, Text)
  local starts, lines = {}, {}
  local pos = 0
  local row = 0
  while true do
    local i = s:find('\n', pos + 1, true)
    starts[row] = pos
    if not i then
      lines[row] = s:sub(pos + 1)
      break
    end
    lines[row] = s:sub(pos + 1, i - 1)
    pos = i
    row = row + 1
  end
  self.lines = lines
  self.starts = starts
  self.nlines = row + 1
  self.total = #s
  self.is_string = true
  return self
end

function Text:len()
  return self.total
end

function Text:len_lines()
  if self.is_string then return self.nlines end
  return self.nlines + 1
end

function Text:line(row)
  local l = self.lines[row]
  if l then return l end
  if self.is_string then return '' end
  if row >= self.nlines or row < 0 then return '' end
  l = api.nvim_buf_get_lines(self.buf, row, row + 1, true)[1] or ''
  self.lines[row] = l
  return l
end

function Text:has_eol(row)
  if self.is_string then return row < self.nlines - 1 end
  return row < self.nlines
end

function Text:line_start(row)
  local s = self.starts[row]
  if s then return s end
  if self.is_string then
    if row >= self.nlines then return self.total end
    return 0
  end
  if row >= self.nlines then return self.total end
  if row <= 0 then return 0 end
  s = api.nvim_buf_get_offset(self.buf, row)
  self.starts[row] = s
  return s
end

function Text:line_end(row)
  return self:line_start(row) + #self:line(row)
end

function Text:line_next(row)
  if row + 1 >= self:len_lines() then return self.total end
  return self:line_start(row + 1)
end

function Text:line_of(pos)
  if pos <= 0 then return 0 end
  if pos >= self.total then
    if self.is_string then return self.nlines - 1 end
    return self.nlines
  end
  local h = self.hint
  if h then
    local s = self:line_start(h)
    if pos >= s then
      local e = self:line_next(h)
      if pos < e then return h end
      if h + 1 < self:len_lines() and pos < self:line_next(h + 1) then
        self.hint = h + 1
        return h + 1
      end
    elseif h > 0 and pos >= self:line_start(h - 1) then
      self.hint = h - 1
      return h - 1
    end
  end
  local lo, hi = 0, self:len_lines() - 1
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if self:line_start(mid) <= pos then
      lo = mid
    else
      hi = mid - 1
    end
  end
  self.hint = lo
  return lo
end

function Text:to_rc(pos)
  local row = self:line_of(pos)
  return row, pos - self:line_start(row)
end

function Text:from_rc(row, col)
  return self:line_start(row) + col
end

function Text:char(pos)
  if pos >= self.total or pos < 0 then return nil, 0 end
  local row = self:line_of(pos)
  local l = self:line(row)
  local col = pos - self:line_start(row)
  if col >= #l then return 10, 1 end
  return U.decode(l, col + 1)
end

function Text:char_str(pos)
  local cp = self:char(pos)
  if not cp then return '' end
  return U.encode(cp)
end

function Text:next_char(pos)
  if pos >= self.total then return self.total end
  local row = self:line_of(pos)
  local l = self:line(row)
  local col = pos - self:line_start(row)
  if col >= #l then return pos + 1 end
  return pos + U.seq_len(byte(l, col + 1))
end

function Text:prev_char(pos)
  if pos <= 0 then return 0 end
  local row = self:line_of(pos)
  local ls = self:line_start(row)
  if pos == ls then return pos - 1 end
  local l = self:line(row)
  return ls + U.prev_boundary(l, pos - ls)
end

function Text:next_grapheme(pos, n)
  n = n or 1
  for _ = 1, n do
    if pos >= self.total then return self.total end
    pos = self:next_char(pos)
    while pos < self.total do
      local cp = self:char(pos)
      if cp and U.is_extender(cp) then
        pos = self:next_char(pos)
      else
        break
      end
    end
  end
  return pos
end

function Text:prev_grapheme(pos, n)
  n = n or 1
  for _ = 1, n do
    if pos <= 0 then return 0 end
    pos = self:prev_char(pos)
    while pos > 0 do
      local cp = self:char(pos)
      if cp and U.is_extender(cp) then
        pos = self:prev_char(pos)
      else
        break
      end
    end
  end
  return pos
end

function Text:is_grapheme_boundary(pos)
  if pos <= 0 or pos >= self.total then return true end
  local row = self:line_of(pos)
  local l = self:line(row)
  local col = pos - self:line_start(row)
  if col < #l then
    local b = l:byte(col + 1)
    if b >= 0x80 and b < 0xC0 then return false end
  end
  local cp = self:char(pos)
  if cp and U.is_extender(cp) then return false end
  if col > 0 and self:char(self:prev_char(pos)) == 0x200D then return false end
  return true
end

function Text:slice(a, b)
  if b <= a then return '' end
  if self.is_string then return self.str:sub(a + 1, b) end
  local ra = self:line_of(a)
  local rb = self:line_of(b)
  local ca = a - self:line_start(ra)
  local cb = b - self:line_start(rb)
  if ra == rb then
    local l = self:line(ra)
    local s = l:sub(ca + 1, cb)
    if cb > #l then s = s .. '\n' end
    return s
  end
  local parts = {}
  local l = self:line(ra)
  parts[1] = l:sub(ca + 1) .. '\n'
  if rb - ra > 64 then
    local mid = api.nvim_buf_get_lines(self.buf, ra + 1, rb, false)
    for i = 1, #mid do
      parts[#parts + 1] = mid[i] .. '\n'
    end
  else
    for r = ra + 1, rb - 1 do
      parts[#parts + 1] = self:line(r) .. '\n'
    end
  end
  if rb < self:len_lines() then
    local lb = self:line(rb)
    local s = lb:sub(1, cb)
    if cb > #lb then s = s .. '\n' end
    parts[#parts + 1] = s
  end
  return table.concat(parts)
end

function Text:all()
  if self.is_string then return self.str end
  if self._all then return self._all end
  local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)
  self._all = table.concat(lines, '\n') .. '\n'
  return self._all
end

function Text:iter(pos)
  local p = pos
  return function()
    if p >= self.total then return nil end
    local cp = self:char(p)
    local at = p
    p = self:next_char(p)
    return at, cp
  end
end

function Text:iter_back(pos)
  local p = pos
  return function()
    if p <= 0 then return nil end
    p = self:prev_char(p)
    return p, self:char(p)
  end
end

function Text:char_count(a, b)
  return U.char_count(self:slice(a, b))
end

function Text:advance(pos, n)
  for _ = 1, n do
    pos = self:next_char(pos)
  end
  return pos
end

function Text:line_is_empty(row)
  return #self:line(row) == 0
end

function Text:first_non_ws(row)
  local l = self:line(row)
  local i = l:find('[^ \t]')
  if not i then return nil end
  return i - 1
end

function Text:visual_col(pos, ts)
  local row = self:line_of(pos)
  local l = self:line(row)
  local col = pos - self:line_start(row)
  local w = 0
  local i = 1
  while i <= col and i <= #l do
    local cp, n = U.decode(l, i)
    if cp == 9 then
      w = w + (ts - w % ts)
    else
      w = w + vim.api.nvim_strwidth(l:sub(i, i + n - 1))
    end
    i = i + n
  end
  if col > #l then w = w + (col - #l) end
  return w
end

return Text
