local S = require('hx.state')
local E = require('hx.editor')
local D = require('hx.doc')
local SL = require('hx.selection')
local Regs = require('hx.registers')
local R = SL.R
local Sel = SL.Selection
local Tx = SL.Transaction

local M = {}

local function normalize_le(v)
  return (v:gsub('\r\n', '\n'):gsub('\r', '\n'))
end

function M.paste_impl(values, action, count, mode)
  if not values or #values == 0 then return end
  local buf = E.buf()
  if mode == 'insert' then D.checkpoint(buf) end
  local linewise = false
  for _, v in ipairs(values) do
    if v:find('[\r\n]$') then linewise = true end
  end
  local function map_value(v)
    v = normalize_le(v)
    return string.rep(v, count)
  end
  local mapped = {}
  for i, v in ipairs(values) do
    mapped[i] = map_value(v)
  end
  local last = mapped[#mapped]
  local text = E.text()
  local sel = E.sel()
  local offset = 0
  local ranges = {}
  local nl = text:len_lines()
  local changes = {}
  for i, r in ipairs(sel.ranges) do
    local pos
    if action == 'before' and linewise then
      pos = text:line_start(text:line_of(r:from()))
    elseif action == 'after' and linewise then
      local _, line = r:line_range(text)
      pos = text:line_start(math.min(line + 1, nl))
    elseif action == 'before' then
      pos = r:from()
    elseif action == 'after' then
      pos = r:to()
    else
      pos = r:cursor(text)
    end
    local value = mapped[i] or last
    local anchor = offset + pos
    ranges[i] = R(anchor, anchor + #value):with_direction(r:forward())
    offset = offset + #value
    changes[i] = { pos, pos, value }
  end
  local tx = Tx.change(text, changes)
  if mode == 'normal' then tx:with_selection(Sel.new(ranges, sel.primary)) end
  D.apply(tx, { win = E.win() })
  if mode == 'insert' then D.checkpoint(buf) end
end

function M.paste(register, action, count)
  local values = Regs.read(register)
  if not values then return end
  M.paste_impl(values, action, count, S.mode)
end

function M.replace_selections_with_register(register, count)
  local values = Regs.read(register)
  if not values or #values == 0 then return end
  local mapped = {}
  for i, v in ipairs(values) do
    mapped[i] = string.rep(normalize_le(v), count)
  end
  local last = mapped[#mapped]
  local text = E.text()
  local sel = E.sel()
  local idx = 0
  local tx = Tx.change_by_selection(text, sel, function(r)
    if not r:is_empty() then
      idx = idx + 1
      return { r:from(), r:to(), mapped[idx] or last }
    end
    return { r:from(), r:to(), nil }
  end)
  D.apply(tx, { win = E.win() })
end

return M
