local api = vim.api
local U = require('hx.util')

local Canvas = {}
Canvas.__index = Canvas

function Canvas.new(w, h, default_group)
  local self = setmetatable({ w = w, h = h, rows = {}, default = default_group or 'HxDefault' }, Canvas)
  for y = 0, h - 1 do
    local row = {}
    for x = 0, w - 1 do
      row[x] = { ' ', self.default }
    end
    self.rows[y] = row
  end
  return self
end

function Canvas:clear(x, y, w, h, group)
  for yy = y, math.min(self.h - 1, y + h - 1) do
    local row = self.rows[yy]
    if row then
      for xx = x, math.min(self.w - 1, x + w - 1) do
        row[xx] = { ' ', group or self.default }
      end
    end
  end
end

function Canvas:style(x, y, w, h, group)
  for yy = y, math.min(self.h - 1, y + h - 1) do
    local row = self.rows[yy]
    if row then
      for xx = x, math.min(self.w - 1, x + w - 1) do
        if row[xx] then row[xx][2] = group end
      end
    end
  end
end

function Canvas:put(x, y, s, group, maxw)
  local row = self.rows[y]
  if not row then return x end
  local limit = maxw and math.min(self.w, x + maxw) or self.w
  for _, cp in U.chars(s) do
    local ch = U.encode(cp)
    if ch == '\t' then ch = ' ' end
    if cp < 32 then ch = ' ' end
    local cw = api.nvim_strwidth(ch)
    if cw == 0 then
      if x > 0 and row[x - 1] then row[x - 1][1] = row[x - 1][1] .. ch end
    else
      if x + cw > limit then break end
      row[x] = { ch, group or row[x][2] }
      if cw == 2 then row[x + 1] = { '', group or row[x + 1][2] } end
      x = x + cw
    end
  end
  return x
end

function Canvas:put_spans(x, y, spans, maxw)
  local start = x
  for _, sp in ipairs(spans) do
    local remaining = maxw and (maxw - (x - start)) or nil
    if remaining and remaining <= 0 then break end
    x = self:put(x, y, sp[1], sp[2], remaining)
  end
  return x
end

local BORDER = { tl = '┌', tr = '┐', bl = '└', br = '┘', h = '─', v = '│' }
local ROUNDED = { tl = '╭', tr = '╮', bl = '╰', br = '╯', h = '─', v = '│' }

function Canvas:border(x, y, w, h, group, title, rounded)
  local b = rounded and ROUNDED or BORDER
  for yy = y, y + h - 1 do
    self:put(x, yy, b.v, group)
    self:put(x + w - 1, yy, b.v, group)
  end
  for xx = x, x + w - 1 do
    self:put(xx, y, b.h, group)
    self:put(xx, y + h - 1, b.h, group)
  end
  self:put(x, y, b.tl, group)
  self:put(x + w - 1, y, b.tr, group)
  self:put(x, y + h - 1, b.bl, group)
  self:put(x + w - 1, y + h - 1, b.br, group)
  if title and title ~= '' then
    if type(title) == 'table' then
      self:put_spans(x + 1, y, title, w - 2)
    else
      self:put(x + 1, y, title, nil, w - 2)
    end
  end
end

function Canvas:render()
  local lines, hls = {}, {}
  for y = 0, self.h - 1 do
    local row = self.rows[y]
    local parts = {}
    local bytepos = 0
    local cur_group, cur_start = nil, 0
    for x = 0, self.w - 1 do
      local cell = row[x]
      local ch, g = cell[1], cell[2]
      if g ~= cur_group then
        if cur_group then hls[#hls + 1] = { y, cur_start, bytepos, cur_group } end
        cur_group, cur_start = g, bytepos
      end
      parts[#parts + 1] = ch
      bytepos = bytepos + #ch
    end
    if cur_group then hls[#hls + 1] = { y, cur_start, bytepos, cur_group } end
    lines[y + 1] = table.concat(parts)
  end
  return lines, hls
end

local floats = {}
local ns = api.nvim_create_namespace('hx_canvas')

function Canvas.show(id, canvas, row, col, opts)
  opts = opts or {}
  local f = floats[id]
  if not f or not api.nvim_buf_is_valid(f.buf) then
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    f = { buf = buf }
    floats[id] = f
  end
  local lines, hls = canvas:render()
  vim.bo[f.buf].modifiable = true
  api.nvim_buf_set_lines(f.buf, 0, -1, false, lines)
  vim.bo[f.buf].modifiable = false
  api.nvim_buf_clear_namespace(f.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    if h[4] ~= 'HxNone' then
      pcall(api.nvim_buf_set_extmark, f.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4], priority = 100 })
    end
  end
  local cfg = {
    relative = 'editor',
    row = row,
    col = col,
    width = math.max(1, canvas.w),
    height = math.max(1, canvas.h),
    style = 'minimal',
    focusable = opts.focusable or false,
    zindex = 200 + (opts.zindex or 50),
    noautocmd = true,
  }
  if f.win and api.nvim_win_is_valid(f.win) then
    cfg.noautocmd = nil
    api.nvim_win_set_config(f.win, cfg)
  else
    f.win = api.nvim_open_win(f.buf, false, cfg)
    vim.wo[f.win].winhighlight = 'Normal:' .. (opts.normal or 'HxDefault') .. ',NormalFloat:' .. (opts.normal or 'HxDefault')
    vim.wo[f.win].wrap = false
    vim.wo[f.win].cursorline = false
    vim.wo[f.win].winblend = 0
    vim.wo[f.win].scrolloff = 0
    vim.wo[f.win].sidescrolloff = 0
    vim.wo[f.win].virtualedit = 'all'
  end
  return f.win, f.buf
end

function Canvas.hide(id)
  local f = floats[id]
  if f and f.win and api.nvim_win_is_valid(f.win) then pcall(api.nvim_win_close, f.win, true) end
  if f then f.win = nil end
end

function Canvas.get(id)
  return floats[id]
end

function Canvas.screen()
  local cmdh = 1
  return { w = vim.o.columns, h = vim.o.lines }
end

return Canvas
