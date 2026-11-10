local U = require('hx.util')
local M = {}

local code_order = {
  backspace = 1, ret = 2, left = 3, right = 4, up = 5, down = 6, home = 7, ['end'] = 8,
  pageup = 9, pagedown = 10, tab = 11, del = 12, ins = 13,
  null = 200, esc = 201,
}

local special_names = {
  backspace = true, ret = true, left = true, right = true, up = true, down = true, home = true,
  ['end'] = true, pageup = true, pagedown = true, tab = true, del = true, ins = true, null = true,
  esc = true, space = true, minus = true, lt = true, gt = true,
}

function M.parse(key)
  local mods = {}
  local rest = key
  while true do
    local m, r = rest:match('^([SCAM])%-(.+)$')
    if not m then
      local r2 = rest:match('^Meta%-(.+)$')
      if r2 then
        mods.M = true
        rest = r2
      else
        break
      end
    else
      mods[m] = true
      rest = r
    end
  end
  return { code = rest, mods = mods }
end

local function code_char(code)
  if code == 'space' then return ' ' end
  if code == 'minus' then return '-' end
  if code == 'lt' then return '<' end
  if code == 'gt' then return '>' end
  if special_names[code] then return nil end
  if code:match('^F%d+$') then return nil end
  if U.char_count(code) == 1 then return code end
  return nil
end
M.code_char = code_char

function M.char(key)
  local p = M.parse(key)
  if p.mods.C or p.mods.A or p.mods.M then return nil end
  return code_char(p.code)
end

function M.normalize(key)
  if key == '<' then return 'lt' end
  if key == '>' then return 'gt' end
  if key == '-' then return 'minus' end
  if key == ' ' then return 'space' end
  local p = M.parse(key)
  local code = p.code
  if code == '<' then code = 'lt' end
  if code == '>' then code = 'gt' end
  if code == '-' then code = 'minus' end
  if code == ' ' then code = 'space' end
  if code == 'enter' then code = 'ret' end
  if code == 'delete' then code = 'del' end
  if code == 'insert' then code = 'ins' end
  if code == 'escape' then code = 'esc' end
  local ch = code_char(code)
  if ch and p.mods.S and #code == 1 then
    code = code:upper()
    p.mods.S = nil
  end
  return M.format({ code = code, mods = p.mods })
end

function M.format(p)
  local s = ''
  if p.mods.M then s = s .. 'Meta-' end
  if p.mods.S then s = s .. 'S-' end
  if p.mods.A then s = s .. 'A-' end
  if p.mods.C then s = s .. 'C-' end
  return s .. p.code
end

function M.seq_format(key)
  if U.char_count(key) > 1 then return '<' .. key .. '>' end
  return key
end

local function code_rank(code)
  local r = code_order[code]
  if r then return r, 0 end
  local f = code:match('^F(%d+)$')
  if f then return 14, tonumber(f) end
  local ch = code_char(code)
  if ch then return 100, U.decode(ch, 1) end
  return 150, 0
end

local function mod_bits(m)
  return (m.S and 1 or 0) + (m.C and 2 or 0) + (m.A and 4 or 0) + (m.M and 8 or 0)
end

function M.less(a, b)
  local pa, pb = M.parse(a), M.parse(b)
  local ra, sa = code_rank(pa.code)
  local rb, sb = code_rank(pb.code)
  if ra ~= rb then return ra < rb end
  if sa ~= sb then return sa < sb end
  return mod_bits(pa.mods) < mod_bits(pb.mods)
end

local nvim_special = {
  BS = 'backspace', CR = 'ret', Left = 'left', Right = 'right', Up = 'up', Down = 'down',
  Home = 'home', End = 'end', PageUp = 'pageup', PageDown = 'pagedown', Tab = 'tab',
  Del = 'del', Insert = 'ins', Esc = 'esc', Space = 'space', lt = 'lt', Bar = '|',
  Bslash = '\\', NL = 'ret', kEnter = 'ret',
}

function M.all_mappings()
  local out = {}
  local function add(lhs, key)
    out[#out + 1] = { lhs, key }
  end
  for c = 33, 126 do
    local ch = string.char(c)
    local lhs = ch
    if ch == '<' then lhs = '<lt>' end
    if ch == '|' then lhs = '<Bar>' end
    if ch == '\\' then lhs = '<Bslash>' end
    add(lhs, M.normalize(ch))
  end
  add('<Space>', 'space')
  for c = string.byte('a'), string.byte('z') do
    local ch = string.char(c)
    if ch ~= 'i' and ch ~= 'm' and ch ~= '[' then add('<C-' .. ch .. '>', 'C-' .. ch) end
  end
  add('<C-Space>', 'C-space')
  add('<C-@>', 'C-space')
  add('<C-\\>', 'C-\\')
  add('<C-]>', 'C-]')
  add('<C-^>', 'C-^')
  add('<C-_>', 'C-_')
  for c = 33, 126 do
    local ch = string.char(c)
    local lhs = '<M-' .. ch .. '>'
    if ch == '<' then lhs = '<M-lt>' end
    if ch == '|' then lhs = '<M-Bar>' end
    if ch == '\\' then lhs = '<M-Bslash>' end
    if ch == '>' then lhs = '<M->>' end
    local name = ch
    if ch == '-' then name = 'minus' end
    if ch == '<' then name = 'lt' end
    if ch == '>' then name = 'gt' end
    add(lhs, 'A-' .. name)
  end
  add('<M-Space>', 'A-space')
  for c = string.byte('a'), string.byte('z') do
    add('<C-M-' .. string.char(c) .. '>', 'A-C-' .. string.char(c))
  end
  local specials = { 'BS', 'CR', 'Left', 'Right', 'Up', 'Down', 'Home', 'End', 'PageUp', 'PageDown',
    'Tab', 'Del', 'Insert', 'Esc' }
  for _, s in ipairs(specials) do
    local name = nvim_special[s]
    add('<' .. s .. '>', name)
    add('<S-' .. s .. '>', 'S-' .. name)
    add('<C-' .. s .. '>', 'C-' .. name)
    add('<M-' .. s .. '>', 'A-' .. name)
    add('<M-S-' .. s .. '>', 'S-A-' .. name)
    add('<C-S-' .. s .. '>', 'S-C-' .. name)
  end
  add('<kEnter>', 'ret')
  add('<C-i>', 'tab')
  add('<C-m>', 'ret')
  for i = 1, 12 do
    add('<F' .. i .. '>', 'F' .. i)
    add('<S-F' .. i .. '>', 'S-F' .. i)
    add('<C-F' .. i .. '>', 'C-F' .. i)
  end
  return out
end

function M.parse_macro(s)
  local keys = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '<' then
      local close = s:find('>', i + 1, true)
      if close and close == i + 1 then
        keys[#keys + 1] = 'lt'
        i = i + 1
      elseif close then
        local inner = s:sub(i + 1, close - 1)
        if inner:sub(-1) == '-' and s:sub(close + 1, close + 1) == '>' then
          inner = inner .. '>'
          close = close + 1
        end
        keys[#keys + 1] = M.normalize(inner)
        i = close + 1
      else
        return nil, 'Unmatched <'
      end
    elseif c == '>' then
      keys[#keys + 1] = 'gt'
      i = i + 1
    else
      local cp, n = U.decode(s, i)
      local ch = s:sub(i, i + n - 1)
      if ch == '\n' then
        keys[#keys + 1] = 'ret'
      elseif ch == '\t' then
        keys[#keys + 1] = 'tab'
      else
        keys[#keys + 1] = M.normalize(ch)
      end
      i = i + n
    end
  end
  return keys
end

function M.format_macro(keys)
  local out = {}
  for _, k in ipairs(keys) do
    if U.char_count(k) == 1 then
      out[#out + 1] = k
    else
      out[#out + 1] = '<' .. k .. '>'
    end
  end
  return table.concat(out)
end

return M
