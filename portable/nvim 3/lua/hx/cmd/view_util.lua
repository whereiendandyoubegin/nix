local api = vim.api
local S = require('hx.state')
local SL = require('hx.selection')
local Text = require('hx.text')

local M = {}

local function cursor_row(win)
  local buf = api.nvim_win_get_buf(win)
  local text = Text.get(buf)
  local pos = S.get_sel(win, buf):prim():cursor(text)
  return math.min(text:line_of(pos), math.max(0, text.nlines - 1))
end

function M.align_view(win, align)
  win = win or require('hx.editor').win()
  require('hx.render').sync_cursor(win)
  api.nvim_win_call(win, function()
    if align == 'top' then
      vim.cmd('normal! zt')
    elseif align == 'bottom' then
      vim.cmd('normal! zb')
    else
      vim.cmd('normal! zz')
    end
  end)
end

function M.ensure_cursor_in_view_center(win)
  win = win or require('hx.editor').win()
  local row = cursor_row(win) + 1
  local top, bot = api.nvim_win_call(win, function()
    return vim.fn.line('w0'), vim.fn.line('w$')
  end)
  local so = vim.wo[win].scrolloff
  if row < top + so or row > bot - so then M.align_view(win, 'center') end
end

function M.trim_trailing_whitespace(buf)
  local text = Text.get(buf)
  local changes = {}
  for row = 0, text.nlines - 1 do
    local l = text:line(row)
    local s = l:find('[ \t]+$')
    if s then
      local ls = text:line_start(row)
      changes[#changes + 1] = { ls + s - 1, ls + #l, nil }
    end
  end
  if #changes > 0 then require('hx.doc').apply(SL.Transaction.change(text, changes), { buf = buf }) end
end

return M
