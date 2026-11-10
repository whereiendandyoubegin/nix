local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')

local M = {}
local ns = api.nvim_create_namespace('hx_decorations')

local frame = {}

local function indent_level(line, ts)
  local w = 0
  for i = 1, #line do
    local c = line:byte(i)
    if c == 32 then
      w = w + 1
    elseif c == 9 then
      w = w + (ts - w % ts)
    else
      return w, true
    end
  end
  return w, false
end

function M.setup()
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf, top, bot)
      frame[win] = nil
      if not S.enabled then return false end
      if api.nvim_win_get_config(win).relative ~= '' then return false end
      if vim.bo[buf].buftype ~= '' and not vim.b[buf].hx_label then return false end
      local cfg = S.config.editor['indent-guides']
      if not cfg.render then return false end
      local ts = vim.bo[buf].tabstop
      local iw = vim.bo[buf].expandtab and (vim.bo[buf].shiftwidth > 0 and vim.bo[buf].shiftwidth or ts) or ts
      local levels = {}
      local last = 0
      local start = top
      local p = top - 1
      while p >= 0 do
        local l = api.nvim_buf_get_lines(buf, p, p + 1, false)[1] or ''
        local lv, nonblank = indent_level(l, ts)
        if nonblank then
          last = lv
          break
        end
        p = p - 1
        if top - p > 200 then break end
      end
      local lines = api.nvim_buf_get_lines(buf, start, bot + 1, false)
      for i, l in ipairs(lines) do
        local lv, nonblank = indent_level(l, ts)
        if nonblank then last = lv end
        levels[start + i - 1] = last
      end
      local leftcol = api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
      end)
      frame[win] = { levels = levels, iw = iw, skip = cfg['skip-levels'] or 0, char = cfg.character or '│',
        leftcol = leftcol }
      return true
    end,
    on_line = function(_, win, buf, row)
      local f = frame[win]
      if not f then return end
      local lv = f.levels[row]
      if not lv or lv == 0 then return end
      local starting = math.floor(f.leftcol / f.iw) + ((f.leftcol % f.iw ~= 0) and 1 or 0) + f.skip
      local end_indent = math.floor(lv / f.iw)
      for i = starting, end_indent - 1 do
        local col = i * f.iw - f.leftcol
        pcall(api.nvim_buf_set_extmark, buf, ns, row, 0, {
          virt_text = { { f.char, 'HxIndentGuide' } },
          virt_text_win_col = col,
          hl_mode = 'combine',
          ephemeral = true,
          priority = 7000,
        })
      end
    end,
  })
  local bg = T.get('ui.background')
  local text = T.get('ui.text')
  local guide = T.try_get('ui.virtual.indent-guide') or T.get('ui.virtual.whitespace')
  api.nvim_set_hl(0, 'HxIndentGuide', T.to_hl(T.patch(text, guide)))
end

return M
