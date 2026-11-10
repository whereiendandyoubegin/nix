local T = require('hx.theme')
local U = require('hx.util')

local M = {}
local LEFT_PADDING = 1

local Menu = {}
Menu.__index = Menu
M.Menu = Menu

function Menu.new(options, format, callback)
  local self = setmetatable({
    options = options,
    format = format,
    callback = callback,
    matches = {},
    cursor = nil,
    scroll = 0,
    size = { 0, 0 },
    auto_close = false,
    is_menu = true,
  }, Menu)
  for i = 1, #options do
    self.matches[i] = { i, 0 }
  end
  return self
end

local function cell_spans(c)
  if type(c) == 'string' then return { { c, nil } } end
  return c
end

local function cell_width(c)
  local w = 0
  for _, sp in ipairs(cell_spans(c)) do
    w = w + vim.api.nvim_strwidth(sp[1])
  end
  return w
end

function Menu:reset_cursor()
  self.cursor = nil
  self.scroll = 0
end

function Menu:clear()
  self.matches = {}
  self.cursor = nil
  self.scroll = 0
end

function Menu:ensure_cursor_in_bounds()
  if #self.matches == 0 then
    self.cursor = nil
    self.scroll = 0
  else
    self.scroll = 0
    if self.cursor then self.cursor = math.min(self.cursor, #self.matches - 1) end
  end
end

function Menu:adjust_scroll()
  local h = self.size[2]
  if self.cursor then
    local scroll = self.scroll
    if self.cursor > math.max(0, h + scroll - 1) then
      scroll = scroll + self.cursor - math.max(0, h + scroll - 1)
    elseif self.cursor < scroll then
      scroll = self.cursor
    end
    self.scroll = scroll
  end
end

function Menu:move_up()
  local len = #self.matches
  if len == 0 then return end
  local max_index = len - 1
  self.cursor = (self.cursor and ((self.cursor + max_index) % len) or max_index) % len
  self:adjust_scroll()
end

function Menu:move_down()
  local len = #self.matches
  if len == 0 then return end
  self.cursor = (self.cursor and (self.cursor + 1) or 0) % len
  self:adjust_scroll()
end

function Menu:move_half_page_up()
  local len = #self.matches
  if len == 0 then return end
  local max_index = math.max(0, len - math.max(1, math.floor(self.size[2] / 2)))
  self.cursor = (self.cursor and ((self.cursor + max_index) % len) or max_index) % len
  self:adjust_scroll()
end

function Menu:move_half_page_down()
  local len = #self.matches
  if len == 0 then return end
  self.cursor = (self.cursor and (self.cursor + math.max(1, math.floor(self.size[2] / 2))) or 0) % len
  self:adjust_scroll()
end

function Menu:selection()
  if not self.cursor then return nil end
  local m = self.matches[self.cursor + 1]
  if not m then return nil end
  return self.options[m[1]]
end

function Menu:is_empty()
  return #self.matches == 0
end

function Menu:required_size(vw, vh)
  local ncols = 0
  local max_lens = {}
  for _, opt in ipairs(self.options) do
    local row = self.format(opt)
    ncols = math.max(ncols, #row)
    for ci, c in ipairs(row) do
      max_lens[ci] = math.max(max_lens[ci] or 0, cell_width(c))
    end
  end
  local height = math.min(#self.matches, 10, vh)
  local fits = #self.matches <= height
  local len = ncols
  for ci = 1, ncols do
    len = len + (max_lens[ci] or 0)
  end
  if not fits then len = len + 1 end
  len = len + LEFT_PADDING
  local width = math.min(len, vw)
  self.widths = max_lens
  self.size = { width, height }
  self:adjust_scroll()
  return width, height
end

function Menu:render(c, x, y, w, h, _)
  local style = T.try_get('ui.menu') or T.get('ui.text')
  local selected = T.get('ui.menu.selected')
  local base_g = T.group_for(style)
  c:clear(x, y, w, h, base_g)
  local tx, tw = x + LEFT_PADDING, math.max(0, w - LEFT_PADDING - 1)
  local scroll = self.scroll
  for row = 0, h - 1 do
    local mi = scroll + row + 1
    local m = self.matches[mi]
    if not m then break end
    local opt = self.options[m[1]]
    local is_sel = self.cursor == (mi - 1)
    local row_style = is_sel and T.patch(style, selected) or style
    if is_sel then c:style(tx, y + row, tw, 1, T.group_for(row_style)) end
    local cx = tx
    for ci, cell in ipairs(self.format(opt)) do
      local cw = (self.widths and self.widths[ci]) or cell_width(cell)
      local limit = math.max(0, math.min(cw, tx + tw - cx))
      local px = cx
      for _, sp in ipairs(cell_spans(cell)) do
        local st = T.patch(row_style, sp[2] or {})
        px = c:put(px, y + row, sp[1], T.group_for(st), math.max(0, cx + limit - px))
      end
      cx = cx + cw + 1
      if cx >= tx + tw then break end
    end
  end
  if self.cursor then
    local off = self.cursor - scroll
    if off >= 0 and off < h then
      c:style(x, y + off, 1, 1, T.group_for(T.patch(style, selected)))
      c:style(x + w - 1, y + off, 1, 1, T.group_for(T.patch(style, selected)))
    end
  end
  local len = #self.matches
  if len > h then
    local scroll_style = T.get('ui.menu.scroll')
    local sh = math.min(math.ceil(h * h / len), h)
    local sl = math.floor((h - sh) * scroll / math.max(1, len - h))
    for i = 0, h - 1 do
      if sl <= i and i < sl + sh then
        c:put(x + w - 1, y + i, '▐', T.group_for(T.patch(style, { fg = scroll_style.fg })))
      else
        c:put(x + w - 1, y + i, '▐', T.group_for(T.patch(style, { fg = scroll_style.bg })))
      end
    end
  end
end

function Menu:handle_key(key)
  if key == 'tab' or key == 'S-tab' then
    local ed = require('hx.state').config.editor
    local st = ed['smart-tab']
    if ed['auto-completion'] and type(st) == 'table' and st.enable and st['supersede-menu'] then
      return 'ignored'
    end
  end
  if key == 'esc' or key == 'C-c' then
    self.callback(self:selection(), 'abort')
    return 'consumed_close'
  elseif key == 'S-tab' or key == 'up' or key == 'C-p' then
    self:move_up()
    self.callback(self:selection(), 'update')
    return 'consumed'
  elseif key == 'tab' or key == 'down' or key == 'C-n' then
    self:move_down()
    self.callback(self:selection(), 'update')
    return 'consumed'
  elseif key == 'pageup' or key == 'C-u' then
    self:move_half_page_up()
    self.callback(self:selection(), 'update')
    return 'consumed'
  elseif key == 'pagedown' or key == 'C-d' then
    self:move_half_page_down()
    self.callback(self:selection(), 'update')
    return 'consumed'
  elseif key == 'ret' then
    local sel = self:selection()
    if sel then
      self.callback(sel, 'validate')
      return 'consumed_close'
    end
    return 'ignored_close'
  end
  if self.auto_close then
    self.callback(self:selection(), 'abort')
    return 'ignored_close'
  end
  return 'ignored'
end

return M
