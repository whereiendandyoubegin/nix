local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')
local Text = require('hx.text')

local M = {}

local function count_digits(n)
  if n <= 0 then return 1 end
  return #tostring(n)
end

function M.line_numbers_width(buf)
  local text = Text.get(buf)
  local last_line = text:len_lines() - 1
  local draw_last = text:line_start(last_line) < text:len()
  local last_drawn = draw_last and (last_line + 1) or last_line
  return math.max(count_digits(last_drawn), 3)
end

local cache = {}

local function cursor_lines(win, buf)
  local sel = S.get_sel(win, buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = cache[win]
  if c and c.sel == sel and c.tick == tick and c.buf == buf then return c end
  local text = Text.get(buf)
  local lines = {}
  for _, r in ipairs(sel.ranges) do
    lines[r:cursor_line(text)] = true
  end
  c = { sel = sel, tick = tick, buf = buf, lines = lines, primary = sel:prim():cursor_line(text) }
  cache[win] = c
  return c
end

local function esc(s)
  return (s:gsub('%%', '%%%%'))
end

local bgs

local function grp(style, cursorline)
  local st = T.patch(bgs, style or {})
  if cursorline then st = T.patch(st, T.get('ui.cursorline.primary')) end
  return T.group_for(st)
end

function M.diag_cell(buf, line)
  local ok, Dg = pcall(require, 'hx.lsp.diagnostics')
  if not ok then return nil end
  local best
  local rank = { hint = 1, info = 2, warning = 3, error = 4 }
  for _, d in ipairs(Dg.line_diagnostics(buf, line)) do
    if not best or (rank[d.severity] or 3) > (rank[best.severity] or 3) then best = d end
  end
  if not best then return nil end
  local sev = best.severity or 'warning'
  return '●', T.get(sev)
end

function M.diff_cell(buf, line, first_visual)
  local ok, Diff = pcall(require, 'hx.diff')
  if not ok then return nil end
  local hunks = Diff.hunks(buf)
  if not hunks then return nil end
  for _, h in ipairs(hunks) do
    local pure_removal = h.after_start == h.after_end
    local pure_insertion = h.before_start == h.before_end
    local hend = h.after_end
    if not (hend < line or (not pure_removal and line == hend)) then
      if h.after_start > line then return nil end
      if pure_insertion then return '▍', T.get('diff.plus.gutter') end
      if pure_removal then
        if not first_visual then return nil end
        return '▔', T.get('diff.minus.gutter')
      end
      return '▍', T.get('diff.delta.gutter')
    end
  end
  return nil
end

function M.render()
  local win = vim.g.statusline_winid
  local buf = api.nvim_win_get_buf(win)
  bgs = T.get('ui.background')
  local lnum = vim.v.lnum - 1
  local virt = vim.v.virtnum
  local first_visual = virt == 0
  local focused = win == require('hx.ui.compositor').editor_win()
  local cl = false
  local primary_line
  if focused and S.config.cursorline then
    local c = cursor_lines(win, buf)
    cl = c.lines[lnum] or false
    primary_line = c.primary
  end
  local width = M.line_numbers_width(buf)
  local out = {}
  local d, dst
  if first_visual then d, dst = M.diag_cell(buf, lnum) end
  out[#out + 1] = '%#' .. grp(dst, cl) .. '#' .. esc(d or ' ')
  out[#out + 1] = '%#' .. grp(nil, cl) .. '# '
  local selected = focused and primary_line == lnum
  local nst = selected and T.get('ui.linenr.selected') or T.get('ui.linenr')
  local numtxt
  if first_visual then
    numtxt = tostring(lnum + 1)
  else
    numtxt = ' '
  end
  numtxt = string.rep(' ', width - #numtxt) .. numtxt
  out[#out + 1] = '%#' .. grp(first_visual and nst or nil, cl) .. '#' .. numtxt
  out[#out + 1] = '%#' .. grp(nil, cl) .. '# '
  local df, dfst = M.diff_cell(buf, lnum, first_visual)
  out[#out + 1] = '%#' .. grp(dfst, cl) .. '#' .. esc(df or ' ')
  return table.concat(out)
end

_G.hx_statuscolumn = function()
  local ok, res = pcall(M.render)
  if ok then return res end
  return ''
end

local pns = api.nvim_create_namespace('hx_phantom')

function M.update_phantom(win)
  if not api.nvim_win_is_valid(win) then return end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' and not vim.b[buf].hx_label then return end
  bgs = T.get('ui.background')
  api.nvim_buf_clear_namespace(buf, pns, 0, -1)
  local text = Text.get(buf)
  local last_line = text:len_lines() - 1
  local draw_last = text:line_start(last_line) < text:len()
  if draw_last or text.nlines == 0 then return end
  local sel = S.get_sel(win, buf)
  local len = text:len()
  local has_cursor, primary_here = false, false
  for i, r in ipairs(sel.ranges) do
    if r.head == len and r.anchor == len then
      has_cursor = true
      if i == sel.primary then primary_here = true end
    end
  end
  local focused = win == require('hx.ui.compositor').editor_win()
  local cl = focused and S.config.cursorline and has_cursor
  local width = M.line_numbers_width(buf)
  local chunks = {}
  chunks[#chunks + 1] = { '  ' .. string.rep(' ', width - 1), grp(nil, cl) }
  chunks[#chunks + 1] = { '~', grp(T.get('ui.linenr'), cl) }
  chunks[#chunks + 1] = { '  ', grp(nil, cl) }
  if has_cursor and focused then
    local Rr = require('hx.render')
    local cur_g, pcur_g = Rr.cursor_group_names()
    local block = S.mode ~= 'insert'
    if block or not primary_here then
      chunks[#chunks + 1] = { ' ', primary_here and pcur_g or cur_g }
    end
  end
  if cl then
    local tw = api.nvim_win_get_width(win)
    local used = 0
    for _, ch in ipairs(chunks) do
      used = used + api.nvim_strwidth(ch[1])
    end
    if tw > used then chunks[#chunks + 1] = { string.rep(' ', tw - used), 'HxCursorline' } end
  end
  pcall(api.nvim_buf_set_extmark, buf, pns, text.nlines - 1, 0, {
    virt_lines = { chunks },
    virt_lines_leftcol = true,
  })
end

return M
