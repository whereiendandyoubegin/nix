local api = vim.api
local M = {}
local drag_anchor
function M.handle(ev)
  local S = require('hx.state')
  local E = require('hx.editor')
  local SL = require('hx.selection')
  local mp = vim.fn.getmousepos()
  if ev == 'scroll_up' or ev == 'scroll_down' then
    local win = mp.winid ~= 0 and mp.winid or E.win()
    if api.nvim_win_get_config(win).relative ~= '' then return end
    local n = S.config.editor['scroll-lines'] or 3
    local C = require('hx.commands'); C.load()
    local prev = E.win()
    require('hx.ui.compositor').set_editor_win(win)
    C.H.scroll(require('hx.input').new_ctx(), n, ev == 'scroll_down', false)
    return
  end
  if mp.winid == 0 or api.nvim_win_get_config(mp.winid).relative ~= '' then return end
  local win = mp.winid
  local buf = api.nvim_win_get_buf(win)
  local text = require('hx.text').get(buf)
  if mp.line == 0 then return end
  local row = math.min(mp.line - 1, text:len_lines() - 1)
  local col = math.max(0, mp.column - 1)
  local l = text:line(row)
  col = math.min(col, #l)
  local pos = text:line_start(row) + col
  if ev == 'left_down' then
    if win ~= E.win() then api.nvim_set_current_win(win); require('hx.ui.compositor').set_editor_win(win) end
    drag_anchor = pos
    S.set_sel(SL.Selection.point(pos):ensure_invariants(text), win, buf)
  elseif ev == 'alt_left_down' then
    local sel = S.get_sel(win, buf)
    S.set_sel(sel:push(SL.R(pos, text:next_grapheme(pos))), win, buf)
  elseif ev == 'left_drag' then
    if drag_anchor then
      local r = SL.R(drag_anchor, text:next_grapheme(drag_anchor)):put_cursor(text, pos, true)
      S.set_sel(SL.Selection.new({ r }, 1), win, buf)
    end
  elseif ev == 'left_up' then
    drag_anchor = nil
  elseif ev == 'middle_down' then
    if S.config.editor['middle-click-paste'] then
      S.set_sel(SL.Selection.point(pos):ensure_invariants(text), win, buf)
      require('hx.cmd.edit_paste').paste('*', 'before', 1)
    end
  end
end
return M
