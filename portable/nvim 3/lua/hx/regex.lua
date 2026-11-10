local U = require('hx.util')
local byte, sub = string.byte, string.sub
local decode = U.decode

local M = {}

local Parser = {}
Parser.__index = Parser

local function perr(msg)
  error({ regex_error = msg }, 0)
end

local posix = {
  alnum = { { 48, 57 }, { 65, 90 }, { 97, 122 } },
  alpha = { { 65, 90 }, { 97, 122 } },
  ascii = { { 0, 127 } },
  blank = { { 9, 9 }, { 32, 32 } },
  cntrl = { { 0, 31 }, { 127, 127 } },
  digit = { { 48, 57 } },
  graph = { { 33, 126 } },
  lower = { { 97, 122 } },
  print = { { 32, 126 } },
  punct = { { 33, 47 }, { 58, 64 }, { 91, 96 }, { 123, 126 } },
  space = { { 9, 13 }, { 32, 32 } },
  upper = { { 65, 90 } },
  word = { { 48, 57 }, { 65, 90 }, { 97, 122 }, { 95, 95 } },
  xdigit = { { 48, 57 }, { 65, 70 }, { 97, 102 } },
}

function Parser.new(s, flags)
  return setmetatable({ s = s, i = 1, ncap = 0, ci = flags.ci or false, dotnl = flags.s or false,
    ml = flags.ml ~= false, x = false }, Parser)
end

function Parser:peek()
  return decode(self.s, self.i)
end

function Parser:next()
  local cp, n = decode(self.s, self.i)
  if not cp then perr('unexpected end of pattern') end
  self.i = self.i + n
  return cp
end

function Parser:eof()
  return self.i > #self.s
end

function Parser:skip_ws()
  if not self.x then return end
  while not self:eof() do
    local c = byte(self.s, self.i)
    if c == 32 or c == 9 or c == 10 or c == 13 then
      self.i = self.i + 1
    elseif c == 35 then
      while not self:eof() and byte(self.s, self.i) ~= 10 do
        self.i = self.i + 1
      end
    else
      break
    end
  end
end

function Parser:parse_alt()
  local list = { self:parse_cat() }
  while not self:eof() and byte(self.s, self.i) == 124 do
    self.i = self.i + 1
    list[#list + 1] = self:parse_cat()
  end
  if #list == 1 then return list[1] end
  return { t = 'alt', list = list }
end

function Parser:parse_cat()
  local list = {}
  while true do
    self:skip_ws()
    if self:eof() then break end
    local c = byte(self.s, self.i)
    if c == 124 or c == 41 then break end
    local atom = self:parse_atom()
    if atom then
      if atom.t ~= 'flags' then
        atom = self:parse_quant(atom)
        list[#list + 1] = atom
      end
    end
  end
  if #list == 1 then return list[1] end
  return { t = 'cat', list = list }
end

function Parser:parse_quant(atom)
  while true do
    self:skip_ws()
    if self:eof() then return atom end
    local c = byte(self.s, self.i)
    local min, max
    if c == 42 then
      min, max = 0, math.huge
      self.i = self.i + 1
    elseif c == 43 then
      min, max = 1, math.huge
      self.i = self.i + 1
    elseif c == 63 then
      min, max = 0, 1
      self.i = self.i + 1
    elseif c == 123 then
      local a, b, close = self.s:match('^{%s*(%d*)%s*(,?%s*%d*)%s*()}', self.i)
      if not close or a == '' then return atom end
      min = tonumber(a)
      if b == '' then
        max = min
      else
        local bn = b:match('%d+')
        max = bn and tonumber(bn) or math.huge
      end
      self.i = close + 1
    else
      return atom
    end
    if atom.t == 'bol' or atom.t == 'eol' then perr('repetition operator missing expression') end
    local lazy = false
    if not self:eof() and byte(self.s, self.i) == 63 then
      lazy = true
      self.i = self.i + 1
    end
    atom = { t = 'rep', node = atom, min = min, max = max, lazy = lazy }
  end
end

local function cls_item(letter)
  local l = string.char(letter)
  local lower = l:lower()
  return { cls = lower, neg = l ~= lower }
end

function Parser:parse_escape(in_class)
  local c = self:next()
  local ch = c < 128 and string.char(c) or nil
  if ch == 'n' then return { t = 'lit', cp = 10 } end
  if ch == 't' then return { t = 'lit', cp = 9 } end
  if ch == 'r' then return { t = 'lit', cp = 13 } end
  if ch == 'f' then return { t = 'lit', cp = 12 } end
  if ch == 'v' then return { t = 'lit', cp = 11 } end
  if ch == 'a' then return { t = 'lit', cp = 7 } end
  if ch == '0' then return { t = 'lit', cp = 0 } end
  if ch == 'x' or ch == 'u' or ch == 'U' then
    local hex
    if byte(self.s, self.i) == 123 then
      local h, close = self.s:match('^{(%x+)}()', self.i)
      if not h then perr('invalid hex escape') end
      hex = h
      self.i = close
    else
      local n = ch == 'x' and 2 or (ch == 'u' and 4 or 8)
      hex = sub(self.s, self.i, self.i + n - 1)
      if not hex:match('^%x+$') or #hex ~= n then perr('invalid hex escape') end
      self.i = self.i + n
    end
    return { t = 'lit', cp = tonumber(hex, 16) }
  end
  if ch and ch:match('[dDwWsS]') then return { t = 'set', neg = false, items = { cls_item(c) } } end
  if ch == 'p' or ch == 'P' then
    local name
    if byte(self.s, self.i) == 123 then
      local nm, close = self.s:match('^{([^}]*)}()', self.i)
      name = nm
      self.i = close
    else
      name = string.char(self:next())
    end
    local item
    local ln = (name or ''):lower()
    if ln == 'l' or ln == 'letter' or ln == 'alphabetic' or ln == 'alpha' then
      item = { cls = 'alpha', neg = false }
    elseif ln == 'n' or ln == 'nd' or ln == 'number' or ln == 'digit' then
      item = { cls = 'd', neg = false }
    elseif ln == 'p' or ln == 'punctuation' then
      item = { cls = 'punct', neg = false }
    elseif ln == 'lu' or ln == 'uppercase' or ln == 'upper' then
      item = { cls = 'upper', neg = false }
    elseif ln == 'll' or ln == 'lowercase' or ln == 'lower' then
      item = { cls = 'lower', neg = false }
    elseif ln == 'whitespace' or ln == 'white_space' or ln == 'z' then
      item = { cls = 's', neg = false }
    else
      item = { cls = 'w', neg = false }
    end
    if ch == 'P' then item.neg = true end
    return { t = 'set', neg = false, items = { item } }
  end
  if not in_class then
    if ch == 'b' then return { t = 'wb' } end
    if ch == 'B' then return { t = 'nwb' } end
    if ch == 'A' then return { t = 'bot' } end
    if ch == 'z' then return { t = 'eot' } end
    if ch == '<' then return { t = 'wstart' } end
    if ch == '>' then return { t = 'wend' } end
  else
    if ch == 'b' then return { t = 'lit', cp = 8 } end
  end
  if ch and ch:match('[%w]') then perr('unrecognized escape sequence \\' .. ch) end
  return { t = 'lit', cp = c }
end

function Parser:parse_class()
  local neg = false
  if byte(self.s, self.i) == 94 then
    neg = true
    self.i = self.i + 1
  end
  local items = {}
  local first = true
  while true do
    if self:eof() then perr('unclosed character class') end
    local c = byte(self.s, self.i)
    if c == 93 and not first then
      self.i = self.i + 1
      break
    end
    first = false
    local lo
    if c == 91 and byte(self.s, self.i + 1) == 58 then
      local negp, name, close = self.s:match('^%[:(%^?)(%a+):%]()', self.i)
      if name and posix[name] then
        self.i = close
        items[#items + 1] = { cls = 'posix', ranges = posix[name], neg = negp == '^' }
        goto continue
      end
    end
    if c == 91 then
      self.i = self.i + 1
      local inner = self:parse_class()
      items[#items + 1] = { cls = 'set', set = inner }
      goto continue
    end
    if c == 92 then
      self.i = self.i + 1
      local e = self:parse_escape(true)
      if e.t == 'set' then
        for _, it in ipairs(e.items) do
          items[#items + 1] = it
        end
        goto continue
      end
      lo = e.cp
    else
      lo = self:next()
    end
    if byte(self.s, self.i) == 45 and byte(self.s, self.i + 1) ~= 93 and self.i + 1 <= #self.s then
      self.i = self.i + 1
      local hi
      if byte(self.s, self.i) == 92 then
        self.i = self.i + 1
        local e = self:parse_escape(true)
        if e.t ~= 'lit' then perr('invalid range') end
        hi = e.cp
      else
        hi = self:next()
      end
      if hi < lo then perr('invalid character class range') end
      items[#items + 1] = { lo, hi }
    else
      items[#items + 1] = { lo, lo }
    end
    ::continue::
  end
  return { t = 'set', neg = neg, items = items }
end

function Parser:parse_group()
  local cap
  local save_ci, save_s, save_x, save_ml = self.ci, self.dotnl, self.x, self.ml
  if byte(self.s, self.i) == 63 then
    self.i = self.i + 1
    local c = byte(self.s, self.i)
    if c == 80 or c == 60 then
      local nm, close = self.s:match('^P?<([%w_]+)>()', self.i)
      if not nm then perr('invalid named group') end
      self.i = close
      self.ncap = self.ncap + 1
      cap = self.ncap
    else
      local on = true
      while true do
        local f = byte(self.s, self.i)
        if not f then perr('unclosed group') end
        self.i = self.i + 1
        if f == 45 then
          on = false
        elseif f == 105 then
          self.ci = on
        elseif f == 115 then
          self.dotnl = on
        elseif f == 109 then
          self.ml = on
        elseif f == 120 then
          self.x = on
        elseif f == 85 or f == 117 then
        elseif f == 41 then
          return { t = 'flags' }
        elseif f == 58 then
          break
        else
          perr('unrecognized flag')
        end
      end
      local node = self:parse_alt()
      if self:eof() or byte(self.s, self.i) ~= 41 then perr('unclosed group') end
      self.i = self.i + 1
      self.ci, self.dotnl, self.x, self.ml = save_ci, save_s, save_x, save_ml
      return { t = 'group', node = node }
    end
  else
    self.ncap = self.ncap + 1
    cap = self.ncap
  end
  local node = self:parse_alt()
  if self:eof() or byte(self.s, self.i) ~= 41 then perr('unclosed group') end
  self.i = self.i + 1
  self.ci, self.dotnl, self.x, self.ml = save_ci, save_s, save_x, save_ml
  return { t = 'group', node = node, cap = cap }
end

function Parser:parse_atom()
  local c = byte(self.s, self.i)
  if c == 40 then
    self.i = self.i + 1
    return self:parse_group()
  elseif c == 91 then
    self.i = self.i + 1
    local s = self:parse_class()
    s.ci = self.ci
    return s
  elseif c == 46 then
    self.i = self.i + 1
    return { t = 'any', nl = self.dotnl }
  elseif c == 94 then
    self.i = self.i + 1
    return { t = self.ml and 'bol' or 'bot' }
  elseif c == 36 then
    self.i = self.i + 1
    return { t = self.ml and 'eol' or 'eot' }
  elseif c == 92 then
    self.i = self.i + 1
    local e = self:parse_escape(false)
    if e.t == 'lit' or e.t == 'set' then e.ci = self.ci end
    return e
  elseif c == 42 or c == 43 or c == 63 then
    perr('repetition operator missing expression')
  end
  local cp = self:next()
  return { t = 'lit', cp = cp, ci = self.ci }
end

local lower = U.lower
local category = U.category

local function is_word_at(s, i)
  local b = byte(s, i)
  if not b then return false end
  if b < 128 then
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
  end
  local j = i
  while j > 1 do
    local bb = byte(s, j)
    if bb < 0x80 or bb >= 0xC0 then break end
    j = j - 1
  end
  return category(decode(s, j)) == 3
end

local function word_before(s, i)
  if i <= 1 then return false end
  return is_word_at(s, i - 1)
end

local function class_match(item, cp)
  local cls = item.cls
  local r
  if cls == 'd' then
    r = cp >= 48 and cp <= 57
    if not r and cp > 127 then r = (cp >= 0x660 and cp <= 0x669) or (cp >= 0xFF10 and cp <= 0xFF19) end
  elseif cls == 'w' then
    r = category(cp) == 3
  elseif cls == 's' then
    r = U.rust_whitespace(cp)
  elseif cls == 'alpha' then
    r = category(cp) == 3 and not (cp >= 48 and cp <= 57) and cp ~= 95
  elseif cls == 'punct' then
    r = category(cp) == 4
  elseif cls == 'upper' then
    r = U.is_upper(cp)
  elseif cls == 'lower' then
    r = U.is_lower(cp)
  elseif cls == 'posix' then
    r = false
    for _, rg in ipairs(item.ranges) do
      if cp >= rg[1] and cp <= rg[2] then
        r = true
        break
      end
    end
  end
  if item.neg then return not r end
  return r
end

local function set_contains(node, cp)
  local hit = false
  for _, it in ipairs(node.items) do
    if it.cls then
      if it.cls == 'set' then
        if set_contains(it.set, cp) then
          hit = true
          break
        end
      elseif class_match(it, cp) then
        hit = true
        break
      end
    elseif cp >= it[1] and cp <= it[2] then
      hit = true
      break
    end
  end
  if not hit and node.ci then
    local l, u = lower(cp), U.upper(cp)
    for _, it in ipairs(node.items) do
      if not it.cls then
        if (l >= it[1] and l <= it[2]) or (u >= it[1] and u <= it[2]) then
          hit = true
          break
        end
      end
    end
  end
  if node.neg then return not hit end
  return hit
end

local function single_pred(node)
  if node.t == 'lit' then
    local cp = node.cp
    if node.ci then
      local lc = lower(cp)
      return function(c)
        return lower(c) == lc
      end
    end
    return function(c)
      return c == cp
    end
  elseif node.t == 'any' then
    if node.nl then return function() return true end end
    return function(c)
      return c ~= 10
    end
  elseif node.t == 'set' then
    return function(c)
      return set_contains(node, c)
    end
  end
  return nil
end

local compile

local function compile_cat(list, ctx)
  if #list == 0 then
    return function(s, i, k)
      return k(i)
    end
  end
  local ms = {}
  for idx, n in ipairs(list) do
    ms[idx] = compile(n, ctx)
  end
  local function chain(idx)
    if idx > #ms then return nil end
    local m = ms[idx]
    if idx == #ms then return m end
    local rest = chain(idx + 1)
    return function(s, i, k)
      return m(s, i, function(j)
        return rest(s, j, k)
      end)
    end
  end
  return chain(1)
end

compile = function(node, ctx)
  local t = node.t
  if t == 'lit' or t == 'any' or t == 'set' then
    local pred = single_pred(node)
    if t == 'lit' and not node.ci and node.cp < 128 then
      local b = node.cp
      return function(s, i, k)
        if byte(s, i) == b and i <= ctx.limit then return k(i + 1) end
        return nil
      end
    end
    return function(s, i, k)
      if i > ctx.limit then return nil end
      local cp, n = decode(s, i)
      if cp and pred(cp) then return k(i + n) end
      return nil
    end
  elseif t == 'cat' then
    return compile_cat(node.list, ctx)
  elseif t == 'alt' then
    local ms = {}
    for idx, n in ipairs(node.list) do
      ms[idx] = compile(n, ctx)
    end
    return function(s, i, k)
      for idx = 1, #ms do
        local r = ms[idx](s, i, k)
        if r then return r end
      end
      return nil
    end
  elseif t == 'group' then
    local m = compile(node.node, ctx)
    local cap = node.cap
    if not cap then return m end
    return function(s, i, k)
      local caps = ctx.caps
      local old_s, old_e = caps[cap * 2 - 1], caps[cap * 2]
      local r = m(s, i, function(j)
        local ps, pe = caps[cap * 2 - 1], caps[cap * 2]
        caps[cap * 2 - 1], caps[cap * 2] = i, j
        local rr = k(j)
        if not rr then caps[cap * 2 - 1], caps[cap * 2] = ps, pe end
        return rr
      end)
      if not r then caps[cap * 2 - 1], caps[cap * 2] = old_s, old_e end
      return r
    end
  elseif t == 'rep' then
    local min, max, lazy = node.min, node.max, node.lazy
    local pred = single_pred(node.node)
    if pred then
      return function(s, i, k)
        local positions = { i }
        local j = i
        local count = 0
        local limit = ctx.limit
        while count < max and j <= limit do
          local cp, n = decode(s, j)
          if not cp or not pred(cp) then break end
          j = j + n
          count = count + 1
          positions[count + 1] = j
          if lazy and count >= min then
          end
        end
        if count < min then return nil end
        if lazy then
          for c = min, count do
            local r = k(positions[c + 1])
            if r then return r end
          end
        else
          for c = count, min, -1 do
            local r = k(positions[c + 1])
            if r then return r end
          end
        end
        return nil
      end
    end
    local m = compile(node.node, ctx)
    local function try(s, i, k, count)
      if lazy then
        if count >= min then
          local r = k(i)
          if r then return r end
        end
        if count < max then
          return m(s, i, function(j)
            if j == i and count >= min then return nil end
            return try(s, j, k, count + 1)
          end)
        end
        return nil
      end
      if count < max then
        local r = m(s, i, function(j)
          if j == i then return nil end
          return try(s, j, k, count + 1)
        end)
        if r then return r end
      end
      if count >= min then return k(i) end
      return nil
    end
    return function(s, i, k)
      return try(s, i, k, 0)
    end
  elseif t == 'bol' then
    return function(s, i, k)
      if i == 1 or byte(s, i - 1) == 10 then return k(i) end
      return nil
    end
  elseif t == 'eol' then
    return function(s, i, k)
      local b = byte(s, i)
      if b == nil or b == 10 or i > #s then return k(i) end
      return nil
    end
  elseif t == 'bot' then
    return function(s, i, k)
      if i == 1 then return k(i) end
      return nil
    end
  elseif t == 'eot' then
    return function(s, i, k)
      if i > #s then return k(i) end
      return nil
    end
  elseif t == 'wb' or t == 'nwb' then
    local want = t == 'wb'
    return function(s, i, k)
      local a = word_before(s, i)
      local b = is_word_at(s, i)
      if (a ~= b) == want then return k(i) end
      return nil
    end
  elseif t == 'wstart' then
    return function(s, i, k)
      if not word_before(s, i) and is_word_at(s, i) then return k(i) end
      return nil
    end
  elseif t == 'wend' then
    return function(s, i, k)
      if word_before(s, i) and not is_word_at(s, i) then return k(i) end
      return nil
    end
  end
  error('unknown node ' .. tostring(t))
end

local function literal_prefix(node)
  local out = {}
  local function walk(n)
    if n.t == 'lit' and not n.ci then
      out[#out + 1] = U.encode(n.cp)
      return true
    elseif n.t == 'cat' then
      for _, x in ipairs(n.list) do
        if not walk(x) then return false end
      end
      return true
    elseif n.t == 'group' then
      return walk(n.node)
    end
    return false
  end
  walk(node)
  return table.concat(out)
end

local Regex = {}
Regex.__index = Regex

function M.new(pattern, flags)
  flags = flags or {}
  local p = Parser.new(pattern, flags)
  local ok, ast = pcall(function()
    local a = p:parse_alt()
    if not p:eof() then perr('unopened group') end
    return a
  end)
  if not ok then
    local msg = type(ast) == 'table' and ast.regex_error or tostring(ast)
    return nil, msg
  end
  local ctx = { caps = {}, limit = math.huge }
  local m = compile(ast, ctx)
  local self = setmetatable({ pattern = pattern, m = m, ctx = ctx, ncap = p.ncap, ast = ast }, Regex)
  self.prefix = literal_prefix(ast)
  return self
end

function Regex:find(s, from, to)
  from = from or 0
  to = to or #s
  local ctx = self.ctx
  ctx.limit = to
  local m = self.m
  local function k(j)
    if j - 1 <= to then return j end
    return nil
  end
  local i = from + 1
  local last = to + 1
  local prefix = self.prefix
  while i <= last do
    if prefix ~= '' then
      local f = s:find(prefix, i, true)
      if not f or f > last then return nil end
      i = f
    end
    ctx.caps = {}
    local e = m(s, i, k)
    if e then return i - 1, e - 1, ctx.caps end
    local b = byte(s, i)
    if not b then break end
    i = i + U.seq_len(b)
  end
  return nil
end

function Regex:find_iter(s, from, to)
  from = from or 0
  to = to or #s
  local pos = from
  local done = false
  local last_end = nil
  return function()
    if done or pos > to then return nil end
    local a, b, caps = self:find(s, pos, to)
    if a and a == b and a == last_end then
      local nb = byte(s, a + 1)
      if not nb or a + 1 > to then
        done = true
        return nil
      end
      a, b, caps = self:find(s, a + U.seq_len(nb), to)
    end
    if not a then
      done = true
      return nil
    end
    last_end = b
    if b == a then
      local nb = byte(s, b + 1)
      pos = b + (nb and U.seq_len(nb) or 1)
    else
      pos = b
    end
    return a, b, caps
  end
end

function Regex:is_match(s, from, to)
  return self:find(s, from, to) ~= nil
end

function M.escape(s)
  return (s:gsub('[\\%.%+%*%?%(%)%|%[%]%{%}%^%$%#%&%-%~]', '\\%0'))
end

function M.smart(pattern)
  local has_upper = false
  for _, cp in U.chars(pattern) do
    if U.is_upper(cp) then
      has_upper = true
      break
    end
  end
  return M.new(pattern, { ci = not has_upper })
end

return M
