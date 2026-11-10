local api = vim.api
local T = require('hx.theme')

local M = {}

local function esc(s)
  return (s:gsub('%%', '%%%%'))
end

function M.render()
  local ok, res = pcall(function()
    local E = require('hx.editor')
    local bg = T.try_get('ui.bufferline.background') or T.get('ui.statusline')
    local active = T.try_get('ui.bufferline.active') or T.get('ui.statusline.active')
    local inactive = T.try_get('ui.bufferline') or T.get('ui.statusline.inactive')
    local bg_group = T.group_for(bg)
    local cur = E.buf()
    local out = { '%#' .. bg_group .. '#' }
    local W = vim.o.columns
    local used = 0
    for _, b in ipairs(E.documents()) do
      local name = api.nvim_buf_get_name(b)
      local fname = vim.b[b].hx_label or (name ~= '' and vim.fn.fnamemodify(name, ':t') or '[scratch]')
      local t = ' ' .. fname .. (vim.bo[b].modified and '[+]' or '') .. ' '
      local style = T.patch(bg, b == cur and active or inactive)
      local w = api.nvim_strwidth(t)
      if used + w > W then
        t = require('hx.util').truncate(t, W - used)
        w = api.nvim_strwidth(t)
      end
      out[#out + 1] = '%#' .. T.group_for(style) .. '#' .. esc(t)
      used = used + w
      if used >= W then break end
    end
    out[#out + 1] = '%#' .. bg_group .. '#'
    return table.concat(out)
  end)
  if ok then return res end
  return ''
end

_G.hx_bufferline = M.render

return M
