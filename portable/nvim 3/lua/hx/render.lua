local api = vim.api
local S = require('hx.state')
local Text = require('hx.text')
local T = require('hx.theme')

local M = {}
local ns = api.nvim_create_namespace('hx_render')
M.ns = ns

local PRIO_CURSORLINE = 10
local PRIO_TABSTOP = 5000
local PRIO_SELECTION = 6000
local PRIO_CURSOR = 6001
local PRIO_MATCH = 6002

local frame = {}

local function cursor_groups()
  local mode = S.mode
  local base_cursor = T.get_exact('ui.cursor') and 'ui.cursor' or 'ui.selection'
  local base_primary = T.try_get('ui.cursor.primary') and 'ui.cursor.primary' or base_cursor
  local cursor_scope = T.get_exact('ui.cursor.' .. mode) and ('ui.cursor.' .. mode) or base_cursor
  local primary_scope = T.get_exact('ui.cursor.primary.' .. mode) and ('ui.cursor.primary.' .. mode) or base_primary
  local function style_of(scope)
    return T.try_get(scope) or {}
  end
  return T.group_for(style_of(cursor_scope)), T.group_for(style_of(primary_scope))
end

local function add_span(rows, text, a, b, group, top, bot)
  if b <= a then return end
  local ra = text:line_of(a)
  local rb = text:line_of(b > a and text:prev_char(b) or b)
  if rb < top or ra > bot then return end
  for row = math.max(ra, top), math.min(rb, bot) do
    local ls = text:line_start(row)
    local len = #text:line(row)
    local s = math.max(a, ls) - ls
    local e = math.min(b, ls + len + 1) - ls
    local list = rows[row]
    if not list then
      list = {}
      rows[row] = list
    end
    if s < len then list[#list + 1] = { s, math.min(e, len), group } end
    if e > len then list[#list + 1] = { len, len, group, eol = true } end
  end
end

local function compute(win, buf, top, bot)
  local text = Text.get(buf)
  local sel = S.get_sel(win, buf)
  local rows = {}
  local mode = S.mode
  local cursor_is_block = mode ~= 'insert'
  local sel_group = 'HxSelection'
  local psel_group = 'HxSelectionPrimary'
  local cur_group, pcur_group = cursor_groups()
  local cursors = {}
  local len = text:len()
  local primary_idx = sel.primary
  local in_prompt = require('hx.ui.compositor').has_focus_layer()
  local terminal_focused = not in_prompt
  for i, r0 in ipairs(sel.ranges) do
    local is_primary = i == primary_idx
    local cgroup = is_primary and pcur_group or cur_group
    local sgroup = is_primary and psel_group or sel_group
    local draw_cursor = (not is_primary) or (cursor_is_block and terminal_focused)
    if r0.head == r0.anchor and r0.head == len then
      if draw_cursor then cursors[#cursors + 1] = { len, len + 1, cgroup } end
    else
      local r = r0:min_width_1(text)
      if r.head > r.anchor then
        local cstart = text:prev_grapheme(r.head)
        local send
        if is_primary and not cursor_is_block and mode ~= 'insert' then
          send = r.head
        else
          send = cstart
        end
        add_span(rows, text, r.anchor, send, sgroup, top, bot)
        if draw_cursor then cursors[#cursors + 1] = { cstart, r.head, cgroup } end
      else
        local cend = text:next_grapheme(r.head)
        if draw_cursor then cursors[#cursors + 1] = { r.head, cend, cgroup } end
        local sstart
        if is_primary and not cursor_is_block and not (mode == 'insert' and cend == r.anchor) then
          sstart = r.head
        else
          sstart = cend
        end
        add_span(rows, text, sstart, r.anchor, sgroup, top, bot)
      end
    end
  end
  local crow = {}
  for _, cdef in ipairs(cursors) do
    local a, b, g = cdef[1], cdef[2], cdef[3]
    if a >= len then
    else
      local row = text:line_of(a)
      if row >= top and row <= bot then
        local ls = text:line_start(row)
        local l = text:line(row)
        local s = a - ls
        crow[row] = crow[row] or {}
        if s >= #l then
          table.insert(crow[row], { #l, #l, g, eol = true })
        else
          table.insert(crow[row], { s, math.min(b - ls, #l), g })
        end
      end
    end
  end
  local cl = {}
  if S.config.cursorline then
    local prow = sel:prim():cursor_line(text)
    for _, r in ipairs(sel.ranges) do
      cl[r:cursor_line(text)] = 'HxCursorlineSecondary'
    end
    cl[prow] = 'HxCursorline'
  end
  local match
  local ok, mb = pcall(require, 'hx.match_brackets')
  if ok then
    local pos = sel:prim():cursor(text)
    local m = mb.find_matching_bracket(buf, text, pos)
    if m then
      local row = text:line_of(m)
      if row >= top and row <= bot then match = { row, m - text:line_start(row) } end
    end
  end
  local tabstops
  local snip = S.docs[buf] and S.docs[buf].active_snippet
  local ts_style = snip and T.get_exact('tabstop')
  if ts_style then
    tabstops = {}
    local g = T.group_for(ts_style)
    for _, t in ipairs(snip.tabstops) do
      for _, r in ipairs(t.ranges) do
        add_span(tabstops, text, r[1], r[2], g, top, bot)
      end
    end
  end
  return { rows = rows, cursors = crow, cursorline = cl, match = match, tabstops = tabstops }
end

M.cursor_group_names = cursor_groups

local function set_span(buf, row, sp, prio)
  local s, e, g = sp[1], sp[2], sp[3]
  if sp.eol then
    pcall(api.nvim_buf_set_extmark, buf, ns, row, s, {
      virt_text = { { ' ', g } },
      virt_text_pos = 'overlay',
      hl_mode = 'combine',
      ephemeral = true,
      priority = prio,
    })
  else
    pcall(api.nvim_buf_set_extmark, buf, ns, row, s, {
      end_row = row,
      end_col = e,
      hl_group = g,
      ephemeral = true,
      priority = prio,
      hl_mode = 'combine',
    })
  end
end

function M.setup()
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf, top, bot)
      frame[win] = nil
      if not S.enabled then return false end
      if win ~= api.nvim_get_current_win() then
        local comp = require('hx.ui.compositor')
        if win ~= comp.editor_win() then return false end
      end
      local cfg = api.nvim_win_get_config(win)
      if cfg.relative ~= '' then return false end
      if vim.bo[buf].buftype == 'terminal' then return false end
      local ok, f = pcall(compute, win, buf, top, bot)
      if not ok then
        frame[win] = nil
        return false
      end
      frame[win] = f
      return true
    end,
    on_line = function(_, win, buf, row)
      local f = frame[win]
      if not f then return end
      local clg = f.cursorline[row]
      if clg then
        pcall(api.nvim_buf_set_extmark, buf, ns, row, 0, {
          end_row = row + 1,
          end_col = 0,
          hl_group = clg,
          hl_eol = true,
          ephemeral = true,
          priority = PRIO_CURSORLINE,
        })
      end
      local ts = f.tabstops and f.tabstops[row]
      if ts then
        for _, sp in ipairs(ts) do
          set_span(buf, row, sp, PRIO_TABSTOP)
        end
      end
      local spans = f.rows[row]
      if spans then
        for _, sp in ipairs(spans) do
          set_span(buf, row, sp, PRIO_SELECTION)
        end
      end
      local cs = f.cursors[row]
      if cs then
        for _, sp in ipairs(cs) do
          set_span(buf, row, sp, PRIO_CURSOR)
        end
      end
      if f.match and f.match[1] == row then
        local col = f.match[2]
        local l = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
        local n = 1
        local b = l:byte(col + 1)
        if b then n = require('hx.util').seq_len(b) end
        set_span(buf, row, { col, col + n, 'HxCursorMatch' }, PRIO_MATCH)
      end
    end,
  })
end

local hidden_cursor = 'n-v-c-sm:block-HxHiddenCursor,i-ci-ve:ver25,r-cr-o:hor20,t:block'
local bar_cursor = 'n-v-c-sm-i-ci-ve:ver25,r-cr-o:hor20,t:block'

function M.update_cursor_shape()
  local comp = package.loaded['hx.ui.compositor']
  local want
  if comp and comp.has_focus_layer() then
    want = comp.cursor_shape() or bar_cursor
  elseif S.mode == 'insert' then
    want = bar_cursor
  else
    want = hidden_cursor
  end
  if want == 'hidden' then want = hidden_cursor end
  if want == 'bar' then want = bar_cursor end
  if vim.o.guicursor ~= want then vim.o.guicursor = want end
end

function M.sync_cursor(win)
  win = win or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then return end
  local buf = api.nvim_win_get_buf(win)
  local text = Text.get(buf)
  local sel = S.get_sel(win, buf)
  local pos = sel:prim():cursor(text)
  local row, col
  if pos >= text:len() then
    row = math.max(0, text.nlines - 1)
    col = #text:line(row)
  else
    row = text:line_of(pos)
    col = pos - text:line_start(row)
  end
  pcall(api.nvim_win_set_cursor, win, { row + 1, col })
end

function M.redraw(win)
  win = win or api.nvim_get_current_win()
  if api.nvim_win_is_valid(win) then pcall(api.nvim__redraw, { win = win, valid = false }) end
end

return M
