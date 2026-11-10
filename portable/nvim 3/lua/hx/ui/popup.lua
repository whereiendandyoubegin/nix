local api = vim.api
local Canvas = require('hx.ui.canvas')
local C = require('hx.ui.compositor')
local T = require('hx.theme')
local S = require('hx.state')

local M = {}

local MIN_HEIGHT, MAX_HEIGHT, MAX_WIDTH = 6, 26, 120

local Popup = {}
Popup.__index = Popup
M.Popup = Popup

function Popup.new(id, contents, opts)
  opts = opts or {}
  return setmetatable({
    id = id,
    contents = contents,
    position = opts.position,
    bias = opts.bias or 'below',
    scroll_half_pages = 0,
    auto_close = opts.auto_close or false,
    ignore_escape_key = opts.ignore_escape_key or false,
    has_scrollbar = opts.scrollbar ~= false,
    is_menu = opts.is_menu or false,
    on_close = opts.on_close,
  }, Popup)
end

function M.cursor_screen_pos()
  local E = require('hx.editor')
  local win = E.win()
  local buf = api.nvim_win_get_buf(win)
  local text = require('hx.text').get(buf)
  local pos = S.get_sel(win, buf):prim():cursor(text)
  local row, col
  if pos >= text:len() then
    row = math.max(0, text.nlines - 1)
    col = #text:line(row)
  else
    row = text:line_of(pos)
    col = pos - text:line_start(row)
  end
  local ok, sp = pcall(vim.fn.screenpos, win, row + 1, col + 1)
  if ok and sp.row > 0 then return sp.row - 1, sp.col - 1 end
  local wp = api.nvim_win_get_position(win)
  return wp[1], wp[2]
end

function M.cursor_screen_row()
  local r = M.cursor_screen_pos()
  return r
end

function Popup:render_info()
  local scr = Canvas.screen()
  local vw, vh = scr.w, scr.h
  local crow, ccol = M.cursor_screen_pos()
  local position = { crow, ccol }
  if self.position and self.position[1] == crow then
    position = self.position
  else
    self.position = position
  end
  local border_cfg = S.config.editor['popup-border']
  local render_borders
  if self.is_menu then
    render_borders = border_cfg == 'all' or border_cfg == 'menu'
  else
    render_borders = border_cfg == 'all' or border_cfg == 'popup'
  end
  local rel_x, rel_y = position[2], position[1]
  local can_below = vh > rel_y + MIN_HEIGHT
  local can_above = rel_y - MIN_HEIGHT >= 0
  local final = self.bias
  if final == 'below' then
    final = can_below and 'below' or 'above'
  else
    final = can_above and 'above' or 'below'
  end
  local max_h = final == 'above' and rel_y or math.max(0, vh - (1 + rel_y))
  max_h = math.min(max_h, MAX_HEIGHT)
  local max_w = math.min(math.max(0, vw - 2), MAX_WIDTH)
  render_borders = render_borders and max_h > 3 and max_w > 3
  if render_borders then
    max_w = max_w - 2
    max_h = max_h - 2
  end
  local w, child_h = self.contents:required_size(max_w, max_h)
  w = math.min(w, MAX_WIDTH)
  local h = render_borders and math.min(child_h + 2, MAX_HEIGHT) or math.min(child_h, MAX_HEIGHT)
  if render_borders then w = w + 2 end
  if vw <= rel_x + w + 2 then
    rel_x = math.max(0, vw - (w + 2))
    w = math.max(0, vw - (rel_x + 2))
  end
  local area
  if final == 'above' then
    local y = math.max(0, rel_y - h)
    area = { x = rel_x, y = y, w = w, h = position[1] - y }
  else
    local y = rel_y + 1
    local ymax = math.min(vh, h + y)
    area = { x = rel_x, y = y, w = w, h = ymax - y }
  end
  return area, child_h, render_borders
end

function Popup:render()
  local area, child_h, borders = self:render_info()
  self.area = area
  if area.w <= 0 or area.h <= 0 then
    Canvas.hide('popup:' .. self.id)
    return
  end
  local bg
  if self.is_menu then
    bg = T.try_get('ui.menu') or T.get('ui.text')
  else
    bg = T.get('ui.popup')
  end
  local bg_group = T.group_for(bg)
  local c = Canvas.new(area.w, area.h, bg_group)
  local ix, iy, iw, ih = 0, 0, area.w, area.h
  if borders then
    c:border(0, 0, area.w, area.h, T.group_for({}))
    ix, iy, iw, ih = 1, 1, area.w - 2, area.h - 2
  end
  local border = borders and 1 or 0
  local max_offset = math.max(0, child_h - ih)
  local half = math.floor(ih / 2)
  local scroll = math.min(max_offset, self.scroll_half_pages * half)
  self.scroll_half_pages = half > 0 and math.floor(scroll / half) or self.scroll_half_pages
  self.contents:render(c, ix, iy, iw, ih, scroll)
  if self.has_scrollbar then
    local win_h = ih
    local len = child_h
    if len > win_h then
      local scroll_style = T.get('ui.menu.scroll')
      local sh = math.min(math.ceil(win_h * win_h / len), win_h)
      local sl = math.floor((win_h - sh) * scroll / math.max(1, len - win_h))
      local thumb_g = T.group_for({ fg = scroll_style.fg })
      local track_g = T.group_for({ fg = scroll_style.bg })
      local half_block = borders and '▌' or '▐'
      for i = 0, win_h - 1 do
        local x = ix + iw - 1 + border
        if sl <= i and i < sl + sh then
          c:put(x, iy + i, half_block, thumb_g)
        elseif not borders then
          c:put(x, iy + i, half_block, track_g)
        end
      end
    end
  end
  Canvas.show('popup:' .. self.id, c, area.y, area.x, { zindex = self.zindex or 90 })
end

function Popup:close()
  Canvas.hide('popup:' .. self.id)
  if self.on_close then pcall(self.on_close, self) end
end

function Popup:handle_key(key)
  if key == 'esc' and self.ignore_escape_key then return false end
  local res = self.contents.handle_key and self.contents:handle_key(key) or 'ignored'
  if res == true then res = 'consumed' end
  if res == 'consumed' then return true end
  if res == 'consumed_close' then
    C.remove(self)
    return true
  end
  if key == 'esc' or key == 'C-c' then
    if self.contents.handle_key then self.contents:handle_key(key) end
    C.remove(self)
    return true
  elseif key == 'pagedown' or key == 'C-d' then
    self.scroll_half_pages = self.scroll_half_pages + 1
    return true
  elseif key == 'pageup' or key == 'C-u' then
    self.scroll_half_pages = math.max(0, self.scroll_half_pages - 1)
    return true
  end
  if self.auto_close or res == 'ignored_close' then C.remove(self) end
  return false
end

local TextC = {}
TextC.__index = TextC
function M.TextContents(lines)
  return setmetatable({ lines = lines }, TextC)
end
function TextC:required_size(mw, mh)
  local Tx = require('hx.ui.text')
  local w = 0
  for _, l in ipairs(self.lines) do
    w = math.max(w, Tx.line_width(l))
  end
  return math.min(w, mw), math.min(#self.lines, mh)
end
function TextC:render(c, x, y, w, h, _)
  require('hx.ui.text').render(c, x, y, w, h, self.lines, 0, T.group_for(T.get('ui.text')))
end

local MdC = {}
MdC.__index = MdC
function M.MarkdownContents(src)
  return setmetatable({ src = src }, MdC)
end
function MdC:required_size(mw, _)
  local Md = require('hx.ui.markdown')
  local Tx = require('hx.ui.text')
  local padding = 2
  local lines = Md.parse(self.src, false)
  local max_text_w = math.min(math.max(0, mw - padding), 120)
  local w, h = Tx.required_size(lines, max_text_w)
  return w + padding, h + padding
end
function MdC:render(c, x, y, w, h, scroll)
  local Md = require('hx.ui.markdown')
  local lines = Md.parse(self.src, true)
  require('hx.ui.text').render(c, x + 1, y + 1, math.max(0, w - 2), math.max(0, h - 2), lines, scroll,
    T.group_for(T.get('ui.text')))
end

function M.show(id, contents, opts)
  local p = Popup.new(id, contents, opts)
  C.push(p)
  return p
end

function M.text(id, s, opts)
  opts = opts or {}
  local lines = require('hx.ui.text').from_string(s, T.get('ui.text'))
  if opts.row then opts.position = { opts.row, opts.col or 0 } end
  return M.show(id, M.TextContents(lines), opts)
end

function M.markdown(id, s, opts)
  opts = opts or {}
  if opts.row then opts.position = { opts.row, opts.col or 0 } end
  return M.show(id, M.MarkdownContents(s), opts)
end

return M
