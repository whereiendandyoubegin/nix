local Canvas = require('hx.ui.canvas')
local T = require('hx.theme')

local M = {}

local width_of = vim.api.nvim_strwidth

function M.new(title, body)
  if not body or #body == 0 then
    return { title = title, lines = {}, width = #title, height = 1, is_info = true }
  end
  local item_width = 0
  for _, e in ipairs(body) do
    item_width = math.max(item_width, width_of(e[1]))
  end
  local lines = {}
  for _, e in ipairs(body) do
    local item, desc = e[1], e[2] or ''
    local first = true
    for dl in (desc .. '\n'):gmatch('(.-)\n') do
      local pad = string.rep(' ', item_width - width_of(first and item or ''))
      if first then
        lines[#lines + 1] = item .. pad .. '  ' .. dl
        first = false
      else
        lines[#lines + 1] = string.rep(' ', item_width) .. '  ' .. dl
      end
      if desc == '' then break end
    end
    if first then lines[#lines + 1] = item .. string.rep(' ', item_width - width_of(item)) .. '  ' end
  end
  local w = 0
  for _, l in ipairs(lines) do
    w = math.max(w, width_of(l))
  end
  return { title = title, lines = lines, width = w, height = #body, is_info = true }
end

function M.from_registers(title)
  local body = {}
  for _, e in ipairs(require('hx.registers').preview()) do
    body[#body + 1] = { e[1], e[2] }
  end
  local info = M.new(title, body)
  info.width = 30
  return info
end

local function hl_groups()
  local text = T.get('ui.text.info')
  local popup = T.get('ui.popup.info')
  return T.group_for(T.patch(popup, text)), T.group_for(popup)
end

local current = nil

function M.render(info)
  if not info then
    Canvas.hide('info')
    return
  end
  if not info.is_info then info = M.new(info.title or '', info.body or {}) end
  local scr = Canvas.screen()
  local width = info.width + 2 + 2
  local height = info.height + 2
  local x = math.max(0, scr.w - width)
  local y = math.max(0, scr.h - (height + 2))
  width = math.min(width, scr.w - x)
  height = math.min(height, scr.h - y)
  if width <= 0 or height <= 0 then return end
  local text_group, popup_group = hl_groups()
  local c = Canvas.new(width, height, popup_group)
  c:border(0, 0, width, height, popup_group, info.title)
  local inner_w = width - 4
  for i, l in ipairs(info.lines) do
    if i > height - 2 then break end
    c:put(2, i, l, text_group, inner_w)
  end
  c:style(2, 1, inner_w, height - 2, text_group)
  for i, l in ipairs(info.lines) do
    if i > height - 2 then break end
    c:put(2, i, l, text_group, inner_w)
  end
  Canvas.show('info', c, y, x, { zindex = 60 })
end

function M.update(info)
  if info == current and info ~= nil then
    M.render(info)
    return
  end
  current = info
  M.render(info)
end

return M
