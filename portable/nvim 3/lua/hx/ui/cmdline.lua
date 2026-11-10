local Canvas = require('hx.ui.canvas')
local S = require('hx.state')
local T = require('hx.theme')

local M = {}

function M.render()
  if not S.enabled then return end
  local C = require('hx.ui.compositor')
  for _, l in ipairs(C.layers) do
    if l.covers_cmdline then
      return
    end
  end
  local scr = Canvas.screen()
  local bg = T.get('ui.background')
  local c = Canvas.new(scr.w, 1, 'HxCmdline')
  local status_w = 0
  local st = S.status
  if st and st.msg then
    local style = st.severity == 'error' and T.get('error') or T.get('ui.text')
    local msg = st.msg:gsub('\n', ' ')
    c:put(0, 0, msg, T.group_for(T.patch(bg, style)))
    status_w = vim.api.nvim_strwidth(msg)
  end
  local key_width = 15
  if scr.w - status_w > key_width then
    local disp = require('hx.input').pending_display()
    local rec = require('hx.input').recording
    local macro_w = rec and 3 or 0
    local text_group = T.group_for(T.patch(bg, T.get('ui.text')))
    if #disp > key_width then disp = disp:sub(#disp - key_width + 1) end
    c:put(scr.w - (key_width + macro_w), 0, disp, text_group)
    if rec then
      local g = T.group_for(T.patch(T.patch(bg, T.get('ui.text')), { fg = 'Yellow', mods = { bold = true } }))
      c:put(scr.w - 3, 0, '[' .. rec.reg .. ']', g)
    end
  end
  Canvas.show('cmdline', c, scr.h - 1, 0, { zindex = 40, normal = 'HxCmdline' })
end

return M
