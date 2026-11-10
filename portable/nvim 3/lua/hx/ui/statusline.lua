local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')
local Text = require('hx.text')

local M = {}

local SPINNER = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' }
M.spinner_frame = nil

local function esc(s)
  return (s:gsub('%%', '%%%%'))
end

local function width(s)
  return api.nvim_strwidth(s)
end

local function elements(list, ctx)
  local spans = {}
  local function write(text, style)
    spans[#spans + 1] = { text, T.patch(ctx.base, style or {}) }
  end
  for _, id in ipairs(list) do
    local f = M.elements[id]
    if f then f(ctx, write) end
  end
  return spans
end

local function spans_width(spans)
  local w = 0
  for _, s in ipairs(spans) do
    w = w + width(s[1])
  end
  return w
end

M.elements = {}
local E = M.elements

E['mode'] = function(ctx, write)
  local names = (S.config.editor.statusline.mode or {})
  local mode = S.mode
  local mode_str = names[mode] or ({ normal = 'NOR', insert = 'INS', select = 'SEL' })[mode]
  local content
  if ctx.focused then
    content = ' ' .. mode_str .. ' '
  else
    content = string.rep(' ', width(mode_str) + 2)
  end
  local style = {}
  if ctx.focused and S.config.editor['color-modes'] then style = T.get('ui.statusline.' .. mode) end
  write(content, style)
end

E['spinner'] = function(ctx, write)
  local frame = require('hx.lsp').spinner_frame(ctx.buf) or ' '
  write(frame)
end

E['file-name'] = function(ctx, write)
  write(' ' .. require('hx.editor').relative_path(ctx.buf) .. ' ')
end

E['file-absolute-path'] = function(ctx, write)
  local n = api.nvim_buf_get_name(ctx.buf)
  write(' ' .. (n ~= '' and n or '[scratch]') .. ' ')
end

E['file-base-name'] = function(ctx, write)
  local n = api.nvim_buf_get_name(ctx.buf)
  write(' ' .. (n ~= '' and vim.fn.fnamemodify(n, ':t') or '[scratch]') .. ' ')
end

E['file-modification-indicator'] = function(ctx, write)
  write(vim.bo[ctx.buf].modified and '[+]' or '   ')
end

E['read-only-indicator'] = function(ctx, write)
  if vim.bo[ctx.buf].readonly or not vim.bo[ctx.buf].modifiable then write(' [readonly] ') end
end

E['file-encoding'] = function(ctx, write)
  local enc = vim.bo[ctx.buf].fileencoding
  if enc ~= '' and enc ~= 'utf-8' then write(' ' .. enc .. ' ') end
end

E['file-line-ending'] = function(ctx, write)
  write(vim.bo[ctx.buf].fileformat == 'dos' and ' CRLF ' or ' LF ')
end

E['file-indent-style'] = function(ctx, write)
  if vim.bo[ctx.buf].expandtab then
    local n = vim.bo[ctx.buf].shiftwidth
    write((' %d space%s '):format(n, n == 1 and '' or 's'))
  else
    write(' tabs ')
  end
end

E['file-type'] = function(ctx, write)
  local ft = vim.bo[ctx.buf].filetype
  write(' ' .. (ft ~= '' and ft or 'text') .. ' ')
end

local function diag_counts(diags)
  local c = { hint = 0, info = 0, warning = 0, error = 0 }
  for _, d in ipairs(diags) do
    c[d.severity or 'hint'] = (c[d.severity or 'hint'] or 0) + 1
  end
  return c
end

E['diagnostics'] = function(ctx, write)
  local ok, Dg = pcall(require, 'hx.lsp.diagnostics')
  if not ok then return end
  local c = diag_counts(Dg.doc_diagnostics(ctx.buf))
  for _, sev in ipairs(S.config.editor.statusline.diagnostics or { 'warning', 'error' }) do
    if (c[sev] or 0) > 0 then
      write('●', T.get(sev))
      write(' ' .. c[sev] .. ' ')
    end
  end
end

E['workspace-diagnostics'] = function(ctx, write)
  local ok, Dg = pcall(require, 'hx.lsp.diagnostics')
  if not ok then return end
  local c = diag_counts(Dg.workspace_diagnostics())
  local sevs = S.config.editor.statusline['workspace-diagnostics'] or { 'warning', 'error' }
  local any = false
  for _, sev in ipairs(sevs) do
    if (c[sev] or 0) > 0 then any = true end
  end
  if not any then return end
  write(' W ')
  for _, sev in ipairs(sevs) do
    if (c[sev] or 0) > 0 then
      write('●', T.get(sev))
      write(' ' .. c[sev] .. ' ')
    end
  end
end

E['selections'] = function(ctx, write)
  local sel = S.get_sel(ctx.win, ctx.buf)
  local n = #sel.ranges
  if n == 1 then
    write(' 1 sel ')
  else
    write((' %d/%d sels '):format(sel.primary, n))
  end
end

E['primary-selection-length'] = function(ctx, write)
  local sel = S.get_sel(ctx.win, ctx.buf)
  local text = Text.get(ctx.buf)
  local n = text:char_count(sel:prim():from(), sel:prim():to())
  write((' %d char%s '):format(n, n == 1 and '' or 's'))
end

local function position(ctx)
  local text = Text.get(ctx.buf)
  local sel = S.get_sel(ctx.win, ctx.buf)
  local pos = sel:prim():cursor(text)
  local row = text:line_of(pos)
  local col = text:char_count(text:line_start(row), pos)
  return row, col, text
end

E['position'] = function(ctx, write)
  local row, col = position(ctx)
  write((' %d:%d '):format(row + 1, col + 1))
end

E['total-line-numbers'] = function(ctx, write)
  write((' %d '):format(Text.get(ctx.buf):len_lines()))
end

E['position-percentage'] = function(ctx, write)
  local row, _, text = position(ctx)
  write(('%d%%'):format(math.floor((row + 1) * 100 / text:len_lines())))
end

E['separator'] = function(_, write)
  write(S.config.editor.statusline.separator or '│')
end

E['spacer'] = function(_, write)
  write(' ')
end

E['version-control'] = function(ctx, write)
  local head = require('hx.git').head(ctx.buf) or ''
  write(head)
end

E['register'] = function(_, write)
  local r = require('hx.input').view.register
  if r then write(' reg=' .. r .. ' ') end
end

E['current-working-directory'] = function(_, write)
  write(' ' .. vim.fn.fnamemodify(vim.fn.getcwd(), ':~') .. ' ')
end

function M.render(win)
  win = win or vim.g.statusline_winid
  if not win or not api.nvim_win_is_valid(win) then return '' end
  local buf = api.nvim_win_get_buf(win)
  local focused = win == require('hx.ui.compositor').editor_win()
  local bgs = T.get('ui.background')
  local base = T.patch(bgs, focused and T.get('ui.statusline') or T.get('ui.statusline.inactive'))
  local ctx = { win = win, buf = buf, focused = focused, base = base }
  local cfg = S.config.editor.statusline
  local W = api.nvim_win_get_width(win)
  local ok, res = pcall(function()
    local left = elements(cfg.left or {}, ctx)
    local right = elements(cfg.right or {}, ctx)
    local center = elements(cfg.center or {}, ctx)
    local Canvas = require('hx.ui.canvas')
    local base_group = T.group_for(base)
    local c = Canvas.new(W, 1, base_group)
    local lw = spans_width(left)
    local rw = spans_width(right)
    local function put(x, spans, maxw)
      local tmp = {}
      for _, s in ipairs(spans) do
        tmp[#tmp + 1] = { s[1], T.group_for(s[2]) }
      end
      c:put_spans(x, 0, tmp, maxw)
    end
    put(0, left, lw)
    put(math.max(0, W - rw), right, rw)
    local edge = math.max(lw, rw)
    local center_max = math.max(0, W - (2 * edge + 2))
    local cw = math.min(center_max, spans_width(center))
    put(math.floor(W / 2) - math.floor(cw / 2), center, cw)
    local out = {}
    local row = c.rows[0]
    local cur
    for x = 0, W - 1 do
      local cell = row[x]
      if cell[2] ~= cur then
        out[#out + 1] = '%#' .. cell[2] .. '#'
        cur = cell[2]
      end
      out[#out + 1] = esc(cell[1])
    end
    return table.concat(out)
  end)
  if ok then return res end
  return esc(tostring(res))
end

_G.hx_statusline = function()
  return M.render(vim.g.statusline_winid)
end

return M
