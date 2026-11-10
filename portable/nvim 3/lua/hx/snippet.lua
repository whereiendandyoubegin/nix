local S = require('hx.state')
local SL = require('hx.selection')
local U = require('hx.util')

local M = {}

local sub, byte = string.sub, string.byte

local function lit(t)
  local n = #t
  return function(s, i)
    if sub(s, i, i + n - 1) == t then return i + n, t end
    return nil
  end
end

local function set_of(chars)
  local t = {}
  for _, c in ipairs(chars) do
    t[c] = true
  end
  return t
end

local TEXT_ESCAPE_CHARS = set_of({ '\\', '}', '$' })
local CHOICE_TEXT_ESCAPE_CHARS = set_of({ '\\', '|', ',' })

local function text(esc, term)
  return function(s, i)
    local res = {}
    local n = #s
    while i <= n do
      local c = sub(s, i, i)
      if c == '\\' then
        local nc = sub(s, i + 1, i + 1)
        if nc ~= '' and esc[nc] then
          res[#res + 1] = nc
          i = i + 2
        else
          res[#res + 1] = '\\'
          i = i + 1
        end
      elseif term[c] then
        return i, table.concat(res)
      else
        res[#res + 1] = c
        i = i + 1
      end
    end
    return i, table.concat(res)
  end
end

local function digit(s, i)
  local j = i
  while true do
    local b = byte(s, j)
    if b and b >= 48 and b <= 57 then j = j + 1 else break end
  end
  if j == i then return nil end
  local v = tonumber(sub(s, i, j - 1))
  if not v or v > 2 ^ 52 then return nil end
  return j, v
end

local function var(s, i)
  local j = i
  while true do
    local b = byte(s, j)
    if not b then break end
    local ok
    if b == 95 then
      ok = true
    elseif j == i then
      ok = (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
    else
      ok = (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57)
    end
    if not ok then break end
    j = j + 1
  end
  if j == i then return nil end
  return j, sub(s, i, j - 1)
end

local function seq(...)
  local ps = { ... }
  return function(s, i)
    local vals = {}
    for k, p in ipairs(ps) do
      local ni, v = p(s, i)
      if not ni then return nil end
      vals[k] = v == nil and false or v
      i = ni
    end
    return i, vals
  end
end

local function choice(...)
  local ps = { ... }
  return function(s, i)
    for _, p in ipairs(ps) do
      local ni, v = p(s, i)
      if ni then return ni, v end
    end
    return nil
  end
end

local function map(p, f)
  return function(s, i)
    local ni, v = p(s, i)
    if not ni then return nil end
    return ni, f(v)
  end
end

local function optional(p)
  return function(s, i)
    local ni, v = p(s, i)
    if ni then return ni, { v } end
    return i, false
  end
end

local function non_empty(p)
  return function(s, i)
    local ni, v = p(s, i)
    if not ni or ni == i then return nil end
    return ni, v
  end
end

local function zero_or_more(p)
  p = non_empty(p)
  return function(s, i)
    local vals = {}
    while true do
      local ni, v = p(s, i)
      if not ni then break end
      vals[#vals + 1] = v
      i = ni
    end
    return i, vals
  end
end

local function one_or_more(p)
  local zm = zero_or_more(p)
  local ne = non_empty(p)
  return function(s, i)
    local ni, v = ne(s, i)
    if not ni then return nil end
    local nj, rest = zm(s, ni)
    table.insert(rest, 1, v)
    return nj, rest
  end
end

local function sep(p, separator)
  return function(s, i)
    local vals = {}
    local ni, v = p(s, i)
    if not ni then return nil end
    vals[1] = v
    i = ni
    while true do
      local si = separator(s, i)
      if not si then break end
      i = si
      local pi, pv = p(s, i)
      if not pi then break end
      vals[#vals + 1] = pv
      i = pi
    end
    return i, vals
  end
end

local function right(l, r)
  return map(seq(l, r), function(v) return v[2] end)
end

local case_change = choice(
  map(lit('upcase'), function() return 'upcase' end),
  map(lit('downcase'), function() return 'downcase' end),
  map(lit('capitalize'), function() return 'capitalize' end),
  map(lit('pascalcase'), function() return 'pascalcase' end),
  map(lit('camelcase'), function() return 'camelcase' end)
)

local format = choice(
  map(right(lit('$'), digit), function(n) return { type = 'capture', n = n } end),
  map(seq(lit('${'), digit, lit('}')), function(v) return { type = 'capture', n = v[2] } end),
  map(seq(lit('${'), digit, lit(':/'), case_change, lit('}')), function(v)
    return { type = 'case', n = v[2], change = v[4] }
  end),
  map(seq(lit('${'), digit, lit(':+'), text(TEXT_ESCAPE_CHARS, set_of({ '}' })), lit('}')), function(v)
    return { type = 'cond', n = v[2], if_ = v[4], else_ = '' }
  end),
  map(seq(lit('${'), digit, lit(':?'), text(TEXT_ESCAPE_CHARS, set_of({ ':' })), lit(':'),
    text(TEXT_ESCAPE_CHARS, set_of({ '}' })), lit('}')), function(v)
    return { type = 'cond', n = v[2], if_ = v[4], else_ = v[6] }
  end),
  map(seq(lit('${'), digit, lit(':'), optional(lit('-')), text(TEXT_ESCAPE_CHARS, set_of({ '}' })), lit('}')),
    function(v)
      return { type = 'cond', n = v[2], if_ = '', else_ = v[5] }
    end)
)

local regex = map(seq(
  lit('/'),
  text(set_of({ '/' }), set_of({ '/' })),
  lit('/'),
  zero_or_more(choice(
    format,
    map(lit('$'), function() return { type = 'text', text = '$' } end),
    map(text(set_of({ '\\', '/' }), set_of({ '/', '$' })), function(t) return { type = 'text', text = t } end)
  )),
  lit('/'),
  text({}, set_of({ '}' }))
), function(v)
  return { regex = v[2], replacement = v[4], options = v[6] }
end)

local anything

local tabstop = map(choice(
  map(right(lit('$'), digit), function(n) return { n, nil } end),
  map(seq(lit('${'), digit, optional(regex), lit('}')), function(v)
    return { v[2], v[3] and v[3][1] or nil }
  end)
), function(v)
  return { type = 'tabstop', tabstop = v[1], transform = v[2] }
end)

local function placeholder(s, i)
  return map(seq(lit('${'), digit, lit(':'), zero_or_more(anything(TEXT_ESCAPE_CHARS, true)), lit('}')), function(v)
    return { type = 'placeholder', tabstop = v[2], value = v[4] }
  end)(s, i)
end

local choice_el = map(seq(
  lit('${'), digit, lit('|'),
  sep(text(CHOICE_TEXT_ESCAPE_CHARS, set_of({ '|', ',' })), lit(',')),
  lit('|}')
), function(v)
  return { type = 'choice', tabstop = v[2], choices = v[4] }
end)

local function variable(s, i)
  return choice(
    map(right(lit('$'), var), function(name) return { type = 'variable', name = name } end),
    map(seq(lit('${'), var, lit('}')), function(v) return { type = 'variable', name = v[2] } end),
    map(seq(lit('${'), var, lit(':'), zero_or_more(anything(TEXT_ESCAPE_CHARS, true)), lit('}')), function(v)
      return { type = 'variable', name = v[2], default = v[4] }
    end),
    map(seq(lit('${'), var, regex, lit('}')), function(v)
      return { type = 'variable', name = v[2], transform = v[3] }
    end)
  )(s, i)
end

local TERM_BRACE = set_of({ '$', '}' })
local TERM = set_of({ '$' })
anything = function(esc, end_at_brace)
  local term = end_at_brace and TERM_BRACE or TERM
  return choice(
    tabstop,
    placeholder,
    choice_el,
    variable,
    map(lit('$'), function() return { type = 'text', text = '$' } end),
    map(text(esc, term), function(t) return { type = 'text', text = t } end)
  )
end

function M.parse_elements(s)
  local ni, v = one_or_more(anything(TEXT_ESCAPE_CHARS, false))(s, 1)
  if not ni then return nil, s end
  if ni <= #s then return nil, sub(s, ni) end
  return v
end

local function is_alnum(cp)
  return U.category(cp) == U.WORD and cp ~= 95
end

local function case_convert(str, change)
  local out = {}
  if change == 'upcase' then
    for _, cp in U.chars(str) do
      out[#out + 1] = U.encode(U.upper(cp))
    end
  elseif change == 'downcase' then
    for _, cp in U.chars(str) do
      out[#out + 1] = U.encode(U.lower(cp))
    end
  elseif change == 'capitalize' then
    local first = true
    for _, cp in U.chars(str) do
      out[#out + 1] = U.encode(first and U.upper(cp) or cp)
      first = false
    end
  elseif change == 'pascalcase' then
    local at_start = true
    for _, cp in U.chars(str) do
      if not is_alnum(cp) then
        at_start = true
      elseif at_start then
        at_start = false
        out[#out + 1] = U.encode(U.upper(cp))
      else
        out[#out + 1] = U.encode(cp)
      end
    end
  elseif change == 'camelcase' then
    local first, at_start = true, false
    for _, cp in U.chars(str) do
      if not is_alnum(cp) then
        at_start = true
      elseif first then
        out[#out + 1] = U.encode(U.lower(cp))
        first = false
      elseif at_start then
        at_start = false
        out[#out + 1] = U.encode(U.upper(cp))
      else
        out[#out + 1] = U.encode(U.lower(cp))
      end
    end
  end
  return table.concat(out)
end

local LAST_TABSTOP_IDX = 2 ^ 53
M.LAST_TABSTOP_IDX = LAST_TABSTOP_IDX

local function elaborate_idx(n)
  if n == 0 then return LAST_TABSTOP_IDX end
  return n - 1
end

local Transform = {}
Transform.__index = Transform

function Transform.new(t)
  local ci, ml, global = false, false, false
  for c in t.options:gmatch('.') do
    if c == 'i' then
      ci = true
    elseif c == 'm' then
      ml = true
    elseif c == 'g' then
      global = true
    end
  end
  local re = require('hx.regex').new(t.regex, { ci = ci, ml = ml })
  if not re then return nil end
  return setmetatable({ regex = re, regex_str = t.regex, global = global, replacement = t.replacement }, Transform)
end

function Transform:apply(str)
  local buf = {}
  local last = 0
  local pos = 0
  while pos <= #str do
    local s, e, caps = self.regex:find(str, pos, #str)
    if not s then break end
    buf[#buf + 1] = str:sub(last + 1, s)
    last = e
    local function group(i)
      if i == 0 then return str:sub(s + 1, e) end
      local a, b = caps[i * 2 - 1], caps[i * 2]
      if not a then return nil end
      return str:sub(a, b - 1)
    end
    for _, fmt in ipairs(self.replacement) do
      if fmt.type == 'text' then
        buf[#buf + 1] = fmt.text
      elseif fmt.type == 'capture' then
        local g = group(fmt.n)
        if g then buf[#buf + 1] = g end
      elseif fmt.type == 'case' then
        local g = group(fmt.n)
        if g and g ~= '' then buf[#buf + 1] = case_convert(g, fmt.change) end
      elseif fmt.type == 'cond' then
        local g = group(fmt.n)
        if g == nil or g == '' then
          buf[#buf + 1] = fmt.else_
        else
          buf[#buf + 1] = fmt.if_
        end
      end
    end
    if not self.global then break end
    if e == s then
      if e >= #str then break end
      pos = e + U.seq_len(byte(str, e + 1))
    else
      pos = e
    end
  end
  buf[#buf + 1] = str:sub(last + 1)
  return table.concat(buf)
end

local Snippet = {}
Snippet.__index = Snippet
M.Snippet = Snippet

local function elaborate(self, default, parent)
  local out = {}
  for _, val in ipairs(default) do
    local t = val.type
    if t == 'tabstop' and not val.transform then
      out[#out + 1] = { type = 'tabstop', idx = self:elaborate_placeholder(val.tabstop, parent, {}) }
    elseif t == 'tabstop' then
      out[#out + 1] = { type = 'tabstop', idx = self:elaborate_transform(val.tabstop, parent, val.transform) }
    elseif t == 'placeholder' then
      out[#out + 1] = { type = 'tabstop', idx = self:elaborate_placeholder(val.tabstop, parent, val.value) }
    elseif t == 'choice' then
      out[#out + 1] = { type = 'tabstop', idx = self:elaborate_choice(val.tabstop, parent, val.choices) }
    elseif t == 'variable' then
      out[#out + 1] = {
        type = 'variable',
        name = val.name,
        default = val.default and elaborate(self, val.default, parent) or nil,
        transform = val.transform and Transform.new(val.transform) or nil,
      }
    else
      out[#out + 1] = { type = 'text', text = val.text }
    end
  end
  return out
end

function Snippet:elaborate_choice(n, parent, choices)
  local idx = elaborate_idx(n)
  table.insert(self.tabstops, { idx = idx, parent = parent, kind = { type = 'choice', choices = choices } })
  return idx
end

function Snippet:elaborate_placeholder(n, parent, default)
  local idx = elaborate_idx(n)
  if idx == LAST_TABSTOP_IDX and #default > 0 then default = {} end
  local d = elaborate(self, default, idx)
  table.insert(self.tabstops, { idx = idx, parent = parent, kind = { type = 'placeholder', default = d } })
  return idx
end

function Snippet:elaborate_transform(n, parent, transform)
  local idx = elaborate_idx(n)
  local t = Transform.new(transform)
  if t then
    table.insert(self.tabstops, { idx = idx, parent = parent, kind = { type = 'transform', transform = t } })
  else
    table.insert(self.tabstops, { idx = idx, parent = parent, kind = { type = 'empty' } })
  end
  return idx
end

local function stable_sort(list, key)
  for i, v in ipairs(list) do
    v.__ord = i
  end
  table.sort(list, function(a, b)
    local ka, kb = key(a), key(b)
    if ka ~= kb then return ka < kb end
    return a.__ord < b.__ord
  end)
  for _, v in ipairs(list) do
    v.__ord = nil
  end
end

function Snippet:fixup_tabstops()
  stable_sort(self.tabstops, function(t) return t.idx end)
  local out = {}
  for _, t in ipairs(self.tabstops) do
    local prev = out[#out]
    if prev and prev.idx == t.idx then
      if prev.kind.type == 'empty' then out[#out] = t end
    else
      out[#out + 1] = t
    end
  end
  self.tabstops = out
end

function Snippet:ensure_last_tabstop()
  local last = self.tabstops[#self.tabstops]
  if last and last.idx == LAST_TABSTOP_IDX then return end
  table.insert(self.tabstops, { idx = LAST_TABSTOP_IDX, parent = nil, kind = { type = 'empty' } })
  table.insert(self.elements, { type = 'tabstop', idx = LAST_TABSTOP_IDX })
end

local function position_of(tabstops, idx)
  local lo, hi = 1, #tabstops
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local v = tabstops[mid].idx
    if v == idx then return mid end
    if v < idx then lo = mid + 1 else hi = mid - 1 end
  end
  error('all tabstops have been resolved')
end

local function renumber_in(tabstops, elements)
  for _, e in ipairs(elements) do
    if e.type == 'tabstop' then
      e.idx = position_of(tabstops, e.idx)
    elseif e.type == 'variable' and e.default then
      renumber_in(tabstops, e.default)
    end
  end
end

function Snippet:renumber_tabstops()
  renumber_in(self.tabstops, self.elements)
  local renumbered = {}
  for _, t in ipairs(self.tabstops) do
    if t.parent then t.parent = position_of(self.tabstops, t.parent) end
    if t.kind.type == 'placeholder' and not renumbered[t.kind.default] then
      renumbered[t.kind.default] = true
      renumber_in(self.tabstops, t.kind.default)
    end
  end
  for i, t in ipairs(self.tabstops) do
    t.idx = i
  end
end

function Snippet.new(elements)
  local self = setmetatable({ elements = {}, tabstops = {} }, Snippet)
  self.elements = elaborate(self, elements, nil)
  self:fixup_tabstops()
  self:ensure_last_tabstop()
  self:renumber_tabstops()
  return self
end

function M.parse(s)
  local elements = M.parse_elements(s)
  if not elements then return nil end
  return Snippet.new(elements)
end

local Rendered = {}
Rendered.__index = Rendered
M.RenderedSnippet = Rendered

local function tabstop_has_placeholder(t)
  return t.kind.type == 'choice' or t.kind.type == 'placeholder'
end
M.tabstop_has_placeholder = tabstop_has_placeholder

local function tabstop_selection(t, direction, primary_idx, snippet_ranges)
  local ranges = {}
  for i, r in ipairs(t.ranges) do
    local rr = SL.R(r[1], r[2])
    if direction == 'backward' then rr = SL.R(r[2], r[1]) end
    ranges[i] = rr
  end
  local per = math.floor(#t.ranges / snippet_ranges)
  return SL.Selection.new(ranges, primary_idx * per + 1)
end

function Rendered:first_selection(direction, primary_idx)
  return tabstop_selection(self.tabstops[1], direction, primary_idx, #self.ranges)
end

function Snippet:prepare_render()
  local tabstops = {}
  for i, t in ipairs(self.tabstops) do
    local kind
    if t.kind.type == 'choice' then
      kind = { type = 'choice', choices = t.kind.choices }
    elseif t.kind.type == 'transform' then
      kind = { type = 'transform', transform = t.kind.transform }
    else
      kind = { type = 'empty' }
    end
    tabstops[i] = { ranges = {}, parent = t.parent, kind = kind }
  end
  return setmetatable({ tabstops = tabstops, ranges = {} }, Rendered)
end

local function visual_width(s, tab_width)
  local col = 0
  for _, cp in U.chars(s) do
    if cp == 9 then
      col = col + (tab_width - col % tab_width)
    else
      col = col + math.max(1, vim.fn.strdisplaywidth(U.encode(cp)))
    end
  end
  return col
end

local function normalize_indentation(prefix, line, dst, indent_style, tab_width)
  local off = visual_width(prefix, tab_width)
  local len, original = 0, 0
  for k = 1, #line do
    local c = byte(line, k)
    if c == 9 then
      len = len + (tab_width - (len + off) % tab_width)
    elseif c == 32 then
      len = len + 1
    else
      break
    end
    original = original + 1
  end
  if indent_style == 'tabs' then
    dst[#dst + 1] = string.rep('\t', math.floor(len / tab_width))
    len = len % tab_width
  end
  dst[#dst + 1] = string.rep(' ', len)
  return original
end

local Render = {}
Render.__index = Render

function Render:push_str(t, at_newline)
  if at_newline then
    local tmp = {}
    local old = normalize_indentation(self.indent, t, tmp, self.ctx.indent_style, self.ctx.tab_width)
    local ind = table.concat(tmp)
    self.text[#self.text + 1] = ind
    self.off = self.off + #ind
    t = t:sub(old + 1)
    if t == '' then
      self.at_newline = true
      return
    end
  end
  self.text[#self.text + 1] = t
  self.off = self.off + #t
end

function Render:push_newline()
  local le = self.ctx.line_ending
  self.off = self.off + #le + #self.indent
  self.text[#self.text + 1] = le
  self.text[#self.text + 1] = self.indent
end

function Render:push_multiline_str(t)
  local lines = vim.split(t, '\n', { plain = true })
  for i, l in ipairs(lines) do
    if l:sub(-1) == '\r' then lines[i] = l:sub(1, -2) end
  end
  self:push_str(lines[1], self.at_newline)
  for i = 2, #lines do
    self:push_newline()
    self:push_str(lines[i], true)
  end
end

function Render:render_tabstop(idx)
  local start = self.off
  local src = self.src.tabstops[idx]
  local stop = start
  if src.kind.type == 'placeholder' and #src.kind.default > 0 then
    self:render_elements(src.kind.default)
    self.dst.tabstops[idx].kind = { type = 'placeholder' }
    stop = self.off
  end
  table.insert(self.dst.tabstops[idx].ranges, { start, stop })
end

function Render:render_element(e)
  if e.type == 'tabstop' then
    self:render_tabstop(e.idx)
  elseif e.type == 'variable' then
    local val = self.ctx.resolve_var(e.name)
    if val then
      if e.transform then
        self:push_multiline_str(e.transform:apply(val))
      else
        self:push_multiline_str(val)
      end
    elseif e.default then
      self:render_elements(e.default)
    end
  else
    self:push_multiline_str(e.text)
  end
end

function Render:render_elements(elements)
  for _, e in ipairs(elements) do
    self:render_element(e)
  end
end

function Snippet:render_at(rendered, indent, at_newline, ctx, pos)
  local r = setmetatable({ dst = rendered, src = self, indent = indent, text = {}, off = pos, ctx = ctx,
    at_newline = at_newline }, Render)
  r:render_elements(self.elements)
  local stop = r.off
  table.insert(rendered.ranges, { pos, stop })
  return table.concat(r.text), stop - pos
end

local function rust_ws(cp)
  return U.rust_whitespace(cp)
end

function Snippet:render(text, sel, change_range, ctx)
  local rendered = self:prepare_render()
  local off = 0
  local tx, nsel = SL.Transaction.change_by_selection_ignore_overlapping(text, sel, change_range, function(rs, re)
    local row = text:line_of(rs)
    local ls = text:line_start(row)
    local prefix = text:slice(ls, rs)
    local indent_len = 0
    for p, cp in U.chars(prefix) do
      if not rust_ws(cp) then break end
      indent_len = p - 1 + #U.encode(cp)
    end
    local indent = prefix:sub(1, indent_len)
    local at_newline = indent_len == rs - ls
    local replacement, rlen = self:render_at(rendered, indent, at_newline, ctx, rs + off)
    off = off + rs - re + rlen
    return replacement
  end)
  return tx, nsel, rendered
end

function M.snippet_ctx(buf)
  local tab_width = vim.bo[buf].tabstop
  local style = vim.bo[buf].expandtab and 'spaces' or 'tabs'
  return {
    resolve_var = function() return nil end,
    tab_width = tab_width,
    indent_style = style,
    line_ending = '\n',
  }
end

local function direction_of(r)
  return r.head < r.anchor and 'backward' or 'forward'
end

function M.generate_transaction_from_snippet(text, sel, edit_offset, replace_mode, snippet, buf)
  local range_fn = require('hx.lsp.util').completion_range_fn(text, sel, edit_offset, replace_mode)
  local ctx = M.snippet_ctx(buf or vim.api.nvim_get_current_buf())
  local tx, mapped, rendered = snippet:render(text, sel, range_fn, ctx)
  tx = tx:with_selection(rendered:first_selection(direction_of(sel:prim()), mapped.primary - 1))
  return tx, rendered
end

local Active = {}
Active.__index = Active
M.ActiveSnippet = Active

local function copy_ranges(rs)
  local out = {}
  for i, r in ipairs(rs) do
    out[i] = { r[1], r[2] }
  end
  return out
end

function Active.new(rendered)
  local tabstops = {}
  for i, t in ipairs(rendered.tabstops) do
    tabstops[i] = { ranges = copy_ranges(t.ranges), parent = t.parent, kind = t.kind }
  end
  local self = setmetatable({
    ranges = copy_ranges(rendered.ranges),
    tabstops = tabstops,
    active = {},
    current = 1,
  }, Active)
  if #self.tabstops == 1 then return nil end
  return self
end

local function is_subset(super, subs)
  local i, j = 1, 1
  while true do
    local ra, rb = super[i], subs[j]
    if not rb then return true end
    if not ra then return false end
    if ra[2] <= rb[1] then
      i = i + 1
    elseif ra[1] <= rb[1] and rb[2] <= ra[2] then
      j = j + 1
    else
      return false
    end
  end
end

local function is_exact_subset(super, subs)
  local i, j = 1, 1
  local matched = true
  while true do
    local ra, rb = super[i], subs[j]
    if not rb then return super[i + 1] == nil end
    if not ra then return false end
    if ra[2] <= rb[1] and ra[1] < rb[1] then
      if not matched then return false end
      matched = false
      i = i + 1
    elseif ra[1] <= rb[1] and rb[2] <= ra[2] then
      matched = true
      j = j + 1
    else
      return false
    end
  end
end

local function sel_bounds(sel)
  local out = {}
  for i, r in ipairs(sel.ranges) do
    out[i] = { r:from(), r:to() }
  end
  return out
end

function Active:is_valid(sel)
  return is_subset(self.ranges, sel_bounds(sel))
end

function Active:delete_placeholder(text)
  local dels = {}
  for i, r in ipairs(self.tabstops[self.current].ranges) do
    dels[i] = { r[1], r[2] }
  end
  return SL.Transaction.delete(text, dels)
end

function Active:map(cs)
  local A = SL.Assoc
  for _, r in ipairs(self.ranges) do
    r[1] = cs:map_pos(r[1], A.After)
    r[2] = cs:map_pos(r[2], A.After)
  end
  local nsnip = #self.ranges
  for i, t in ipairs(self.tabstops) do
    if self.active[i] then
      for _, r in ipairs(t.ranges) do
        r[1] = cs:map_pos(r[1], A.After)
        r[2] = cs:map_pos(r[2], A.After)
      end
    else
      for _, r in ipairs(t.ranges) do
        local end_assoc = r[1] == r[2] and A.After or A.Before
        r[1] = cs:map_pos(r[1], A.After)
        r[2] = cs:map_pos(r[2], end_assoc)
      end
    end
    local prev = { 0, 0 }
    for _, r in ipairs(t.ranges) do
      if prev[2] > r[1] then
        r[1] = prev[2]
        r[2] = math.max(r[2], r[1])
      end
      prev = r
    end
    local _ = nsnip
  end
  for _, r in ipairs(self.ranges) do
    if r[2] > r[1] then return false end
  end
  return true
end

function Active:primary_idx(sel)
  local p = sel:prim()
  local from, to = p:from(), p:to()
  for i, r in ipairs(self.ranges) do
    if r[1] <= from and to <= r[2] + 1 then return i - 1 end
  end
  return 0
end

function Active:activate_tabstop()
  if self.current == #self.tabstops then return false end
  self.active = { [self.current] = true }
  local parent = self.tabstops[self.current].parent
  while parent do
    self.active[parent] = true
    parent = self.tabstops[parent].parent
  end
  return true
end

function Active:tabstop_selection(primary_idx, direction)
  return tabstop_selection(self.tabstops[self.current], direction, primary_idx, #self.ranges)
end

function Active:next_tabstop(sel)
  local pidx = self:primary_idx(sel)
  while self.current < #self.tabstops do
    self.current = self.current + 1
    if self:activate_tabstop() then
      return self:tabstop_selection(pidx, 'forward'), self.current == #self.tabstops
    end
  end
  return self:tabstop_selection(pidx, 'forward'), true
end

function Active:prev_tabstop(sel)
  local pidx = self:primary_idx(sel)
  while self.current ~= 1 do
    self.current = self.current - 1
    if self:activate_tabstop() then return self:tabstop_selection(pidx, 'forward') end
  end
  return nil
end

function Active:insert_subsnippet(rendered)
  if #rendered.ranges % #self.ranges ~= 0 or not is_exact_subset(self.ranges, rendered.ranges) then
    return Active.new(rendered)
  end
  local cur = self.current
  local parent = self.tabstops[cur].parent
  local new = {}
  for i, t in ipairs(rendered.tabstops) do
    local np
    if t.parent then np = t.parent + (cur - 1) else np = parent end
    new[i] = { ranges = copy_ranges(t.ranges), parent = np, kind = t.kind }
  end
  local tabstops = {}
  for i = 1, cur - 1 do
    tabstops[#tabstops + 1] = self.tabstops[i]
  end
  for _, t in ipairs(new) do
    tabstops[#tabstops + 1] = t
  end
  for i = cur + 1, #self.tabstops do
    local t = self.tabstops[i]
    tabstops[#tabstops + 1] = t
  end
  self.tabstops = tabstops
  self:activate_tabstop()
  return self
end

function Active:tabstop_list()
  return self.tabstops
end

function M.active(buf)
  return S.doc(buf).active_snippet
end

function M.activate(buf, rendered)
  local d = S.doc(buf)
  local existing = d.active_snippet
  d.active_snippet = nil
  if existing then
    d.active_snippet = existing:insert_subsnippet(rendered)
  else
    d.active_snippet = Active.new(rendered)
  end
  return d.active_snippet
end

function M.on_change(buf, cs)
  local d = S.doc(buf)
  local snip = d.active_snippet
  if snip and snip:map(cs) then d.active_snippet = nil end
end

function M.on_selection(buf, sel)
  local d = S.doc(buf)
  local snip = d.active_snippet
  if snip and sel and not snip:is_valid(sel) then d.active_snippet = nil end
end

function M.on_focus_lost(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then S.doc(buf).active_snippet = nil end
end

function M.placeholder_callback(ctx, key)
  local ch = require('hx.keys').char(key)
  if not ch then return end
  local E = require('hx.editor')
  local buf = E.buf()
  local snip = S.doc(buf).active_snippet
  if snip then
    require('hx.doc').apply(snip:delete_placeholder(require('hx.text').get(buf)), { win = E.win(), buf = buf })
  end
  require('hx.commands').insert_char(ctx, ch)
end

function M.delete_placeholder_and_insert(ctx, ch)
  local E = require('hx.editor')
  local buf = E.buf()
  local snip = S.doc(buf).active_snippet
  if snip then
    require('hx.doc').apply(snip:delete_placeholder(require('hx.text').get(buf)), { win = E.win(), buf = buf })
  end
  require('hx.commands').insert_char(ctx, ch)
end

function M.goto_tabstop(ctx, forward)
  local E = require('hx.editor')
  local buf = E.buf()
  local d = S.doc(buf)
  local snip = d.active_snippet
  d.active_snippet = nil
  if not snip then
    S.set_status('no snippet is currently active', 'error')
    return
  end
  local sel, last
  local cur = E.sel()
  if forward then
    sel, last = snip:next_tabstop(cur)
  else
    sel = snip:prev_tabstop(cur)
    last = false
  end
  if not sel then return end
  E.set_sel(sel)
  if not last then d.active_snippet = snip end
  if S.mode == 'insert' and ctx and ctx.on_next then ctx:on_next(M.placeholder_callback, 'fallback') end
end

return M
