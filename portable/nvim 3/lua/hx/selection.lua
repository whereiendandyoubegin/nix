local U = require('hx.util')

local M = {}

local Range = {}
Range.__index = Range
M.Range = Range

function Range.new(anchor, head, ovp)
  return setmetatable({ anchor = anchor, head = head, ovp = ovp }, Range)
end
local R = Range.new
M.R = R

function Range.point(p)
  return R(p, p)
end

function Range:from()
  return self.anchor < self.head and self.anchor or self.head
end
function Range:to()
  return self.anchor > self.head and self.anchor or self.head
end
function Range:len()
  return self:to() - self:from()
end
function Range:is_empty()
  return self.anchor == self.head
end
function Range:forward()
  return self.head >= self.anchor
end
function Range:flip()
  return R(self.head, self.anchor, self.ovp)
end
function Range:with_direction(forward)
  if self:forward() == forward then return self end
  return self:flip()
end
function Range:eq(o)
  return self.anchor == o.anchor and self.head == o.head
end
function Range:overlaps(o)
  return self:from() == o:from() or (self:to() > o:from() and o:to() > self:from())
end
function Range:contains_range(o)
  return self:from() <= o:from() and self:to() >= o:to()
end
function Range:contains(pos)
  return self:from() <= pos and pos < self:to()
end

function Range:extend(from, to)
  if self.anchor <= self.head then
    return R(math.min(self.anchor, from), math.max(self.head, to))
  end
  return R(math.max(self.anchor, to), math.min(self.head, from))
end

function Range:merge(o)
  if self.anchor > self.head and o.anchor > o.head then
    return R(math.max(self.anchor, o.anchor), math.min(self.head, o.head))
  end
  return R(math.min(self:from(), o:from()), math.max(self:to(), o:to()))
end

function Range:fragment(text)
  return text:slice(self:from(), self:to())
end

function Range:cursor(text)
  if self.head > self.anchor then return text:prev_grapheme(self.head) end
  return self.head
end

function Range:cursor_line(text)
  return text:line_of(self:cursor(text))
end

function Range:put_cursor(text, pos, extend)
  if extend then
    local anchor
    if self.head >= self.anchor and pos < self.anchor then
      anchor = text:next_grapheme(self.anchor)
    elseif self.head < self.anchor and pos >= self.anchor then
      anchor = text:prev_grapheme(self.anchor)
    else
      anchor = self.anchor
    end
    if anchor <= pos then return R(anchor, text:next_grapheme(pos)) end
    return R(anchor, pos)
  end
  return R(pos, pos)
end

function Range:line_range(text)
  local from = self:from()
  local to
  if self:is_empty() then
    to = self:to()
  else
    to = math.max(text:prev_grapheme(self:to()), from)
  end
  return text:line_of(from), text:line_of(to)
end

local function ensure_boundary_prev(text, pos)
  while pos > 0 and not text:is_grapheme_boundary(pos) do
    pos = text:prev_char(pos)
  end
  return pos
end
local function ensure_boundary_next(text, pos)
  while pos < text:len() and not text:is_grapheme_boundary(pos) do
    pos = text:next_char(pos)
  end
  return pos
end

function Range:grapheme_aligned(text)
  local a, h
  if self.anchor == self.head then
    a = ensure_boundary_prev(text, self.anchor)
    h = a
  elseif self.anchor < self.head then
    a = ensure_boundary_prev(text, self.anchor)
    h = ensure_boundary_next(text, self.head)
  else
    a = ensure_boundary_next(text, self.anchor)
    h = ensure_boundary_prev(text, self.head)
  end
  return R(a, h, a == self.anchor and self.ovp or nil)
end

function Range:min_width_1(text)
  if self.anchor == self.head then return R(self.anchor, text:next_grapheme(self.head), self.ovp) end
  return self
end

function Range:is_single_grapheme(text)
  return text:next_grapheme(self:from()) == self:to()
end

local Sel = {}
Sel.__index = Sel
M.Selection = Sel

function Sel.new(ranges, primary)
  assert(#ranges > 0, 'empty selection')
  local s = setmetatable({ ranges = ranges, primary = primary or 1 }, Sel)
  return s:normalize()
end

local function raw(ranges, primary)
  return setmetatable({ ranges = ranges, primary = primary }, Sel)
end

function Sel.single(anchor, head)
  return raw({ R(anchor, head) }, 1)
end

function Sel.point(pos)
  return Sel.single(pos, pos)
end

function Sel:prim()
  return self.ranges[self.primary]
end

function Sel:len()
  return #self.ranges
end

function Sel:copy()
  local r = {}
  for i, x in ipairs(self.ranges) do
    r[i] = R(x.anchor, x.head, x.ovp)
  end
  return raw(r, self.primary)
end

function Sel:normalize()
  if #self.ranges < 2 then
    self.primary = 1
    return self
  end
  local primary = self.ranges[self.primary]
  local idx = {}
  for i, r in ipairs(self.ranges) do
    idx[i] = { r = r, i = i }
  end
  table.sort(idx, function(a, b)
    local fa, fb = a.r:from(), b.r:from()
    if fa ~= fb then return fa < fb end
    return a.i < b.i
  end)
  local out = {}
  for _, e in ipairs(idx) do
    local cur = e.r
    local prev = out[#out]
    if prev and prev:overlaps(cur) then
      local nr = cur:merge(prev)
      if prev == primary or cur == primary then primary = nr end
      out[#out] = nr
    else
      out[#out + 1] = cur
    end
  end
  local pi = 1
  for i, r in ipairs(out) do
    if r == primary then
      pi = i
      break
    end
  end
  self.ranges = out
  self.primary = pi
  return self
end

function Sel:into_single()
  return raw({ self:prim() }, 1)
end

function Sel:push(r)
  local rs = { unpack(self.ranges) }
  rs[#rs + 1] = r
  return Sel.new(rs, #rs)
end

function Sel:remove(i)
  assert(#self.ranges > 1, "can't remove the last range from a selection!")
  local rs = { unpack(self.ranges) }
  table.remove(rs, i)
  local p = self.primary
  if i < p or p == #rs + 1 then p = p - 1 end
  return raw(rs, math.max(1, p))
end

function Sel:replace(i, r)
  local rs = { unpack(self.ranges) }
  rs[i] = r
  return Sel.new(rs, self.primary)
end

function Sel:transform(f)
  local rs = {}
  for i, r in ipairs(self.ranges) do
    rs[i] = f(r, i)
  end
  return Sel.new(rs, self.primary)
end

function Sel:transform_iter(f)
  local rs = {}
  local primary_r
  for i, r in ipairs(self.ranges) do
    local list = f(r, i)
    for _, x in ipairs(list) do
      rs[#rs + 1] = x
      if i == self.primary and not primary_r then primary_r = #rs end
    end
  end
  if #rs == 0 then return self end
  return Sel.new(rs, primary_r or 1)
end

function Sel:ensure_invariants(text)
  return self:transform(function(r)
    return r:min_width_1(text):grapheme_aligned(text)
  end)
end

function Sel:cursors(text)
  return self:transform(function(r)
    return Range.point(r:cursor(text))
  end)
end

function Sel:merge_ranges()
  local first, last = self.ranges[1], self.ranges[#self.ranges]
  return raw({ first:merge(last) }, 1)
end

function Sel:merge_consecutive_ranges()
  local primary = self.ranges[self.primary]
  local out = {}
  for _, cur in ipairs(self.ranges) do
    local prev = out[#out]
    if prev and prev:to() == cur:from() then
      local nr = cur:merge(prev)
      if prev == primary or cur == primary then primary = nr end
      out[#out] = nr
    else
      out[#out + 1] = cur
    end
  end
  local pi = 1
  for i, r in ipairs(out) do
    if r == primary then pi = i end
  end
  return raw(out, pi)
end

function Sel:line_ranges(text)
  local res = {}
  local i = 1
  local rs = self.ranges
  while i <= #rs do
    local s, e = rs[i]:line_range(text)
    i = i + 1
    while i <= #rs do
      local ns, ne = rs[i]:line_range(text)
      if ns - e <= 1 then
        e = ne
        i = i + 1
      else
        break
      end
    end
    res[#res + 1] = { s, e }
  end
  return res
end

function Sel:fragments(text)
  local out = {}
  for i, r in ipairs(self.ranges) do
    out[i] = r:fragment(text)
  end
  return out
end

function Sel:eq(o)
  if #self.ranges ~= #o.ranges or self.primary ~= o.primary then return false end
  for i, r in ipairs(self.ranges) do
    if not r:eq(o.ranges[i]) then return false end
  end
  return true
end

function Sel:serialize()
  local out = { primary = self.primary }
  for i, r in ipairs(self.ranges) do
    out[i] = { r.anchor, r.head }
  end
  return out
end

function Sel.deserialize(t)
  local rs = {}
  for i, p in ipairs(t) do
    rs[i] = R(p[1], p[2])
  end
  return raw(rs, t.primary or 1)
end

local CS = {}
CS.__index = CS
M.ChangeSet = CS

M.Assoc = {
  Before = 1, After = 2, AfterWord = 3, BeforeWord = 4, BeforeSticky = 5, AfterSticky = 6,
}
local A = M.Assoc

local function stay_at_gaps(assoc)
  return assoc ~= A.BeforeWord and assoc ~= A.AfterWord
end

local function leading_word_bytes(s)
  local n = 0
  for i, cp, len in U.chars(s) do
    if not U.is_word(cp) then break end
    n = i + len - 1
  end
  return n
end

local function trailing_word_bytes(s)
  local n = 0
  local i = #s
  while i > 0 do
    local j = U.prev_boundary(s, i)
    local cp = U.decode(s, j + 1)
    if not U.is_word(cp) then break end
    n = n + (i - j)
    i = j
  end
  return n
end

local function insert_offset(assoc, s)
  if assoc == A.After or assoc == A.AfterSticky then return #s end
  if assoc == A.AfterWord then return leading_word_bytes(s) end
  if assoc == A.Before or assoc == A.BeforeSticky then return 0 end
  return #s - trailing_word_bytes(s)
end

local function is_sticky(assoc)
  return assoc == A.BeforeSticky or assoc == A.AfterSticky
end

function CS.from_changes(len, changes)
  local ops = {}
  local last = 0
  local function retain(n)
    if n <= 0 then return end
    local p = ops[#ops]
    if p and p[1] == 'r' then
      p[2] = p[2] + n
    else
      ops[#ops + 1] = { 'r', n }
    end
  end
  local function delete(n)
    if n <= 0 then return end
    local p = ops[#ops]
    if p and p[1] == 'd' then
      p[2] = p[2] + n
    else
      ops[#ops + 1] = { 'd', n }
    end
  end
  local function insert(s)
    if s == '' then return end
    local p = ops[#ops]
    if p and p[1] == 'i' then
      p[2] = p[2] .. s
    elseif p and p[1] == 'd' then
      local q = ops[#ops - 1]
      if q and q[1] == 'i' then
        q[2] = q[2] .. s
      else
        ops[#ops] = { 'i', s }
        ops[#ops + 1] = p
      end
    else
      ops[#ops + 1] = { 'i', s }
    end
  end
  local norm = {}
  for _, c in ipairs(changes) do
    local from, to, text = c[1], c[2], c[3]
    if from < last then
    else
      retain(from - last)
      if text and text ~= '' then insert(text) end
      delete(to - from)
      last = to
      norm[#norm + 1] = { from, to, text or '' }
    end
  end
  retain(len - last)
  local cs = setmetatable({ ops = ops, len = len, changes = norm }, CS)
  return cs
end

function CS:is_empty()
  return #self.changes == 0 or (#self.ops <= 1 and (self.ops[1] == nil or self.ops[1][1] == 'r'))
end

function CS:map_pos(pos, assoc)
  local old_pos, new_pos = 0, 0
  local ops = self.ops
  local i = 1
  while i <= #ops do
    local op = ops[i]
    local kind = op[1]
    if kind == 'r' then
      local old_end = old_pos + op[2]
      if old_end > pos then return new_pos + (pos - old_pos) end
      new_pos = new_pos + op[2]
      old_pos = old_end
    elseif kind == 'd' then
      local old_end = old_pos + op[2]
      if old_end > pos then return new_pos end
      old_pos = old_end
    else
      local s = op[2]
      local nxt = ops[i + 1]
      if nxt and nxt[1] == 'd' then
        i = i + 1
        local dlen = nxt[2]
        local old_end = old_pos + dlen
        if old_end > pos then
          if pos == old_pos and stay_at_gaps(assoc) then return new_pos end
          local ins = insert_offset(assoc, s)
          if dlen == ins and is_sticky(assoc) then return new_pos + (pos - old_pos) end
          return new_pos + ins
        end
        new_pos = new_pos + #s
        old_pos = old_end
      else
        if pos == old_pos then return new_pos + insert_offset(assoc, s) end
        new_pos = new_pos + #s
      end
    end
    i = i + 1
  end
  if pos == old_pos then return new_pos end
  return new_pos + math.max(0, pos - old_pos)
end

function CS:len_after()
  local n = self.len
  for _, c in ipairs(self.changes) do
    n = n + #c[3] - (c[2] - c[1])
  end
  return n
end

function M.map_range(r, cs)
  if cs:is_empty() then return r end
  if r.anchor == r.head then
    local a = cs:map_pos(r.anchor, A.AfterSticky)
    return R(a, a)
  elseif r.anchor < r.head then
    return R(cs:map_pos(r.anchor, A.AfterSticky), cs:map_pos(r.head, A.BeforeSticky))
  end
  return R(cs:map_pos(r.anchor, A.BeforeSticky), cs:map_pos(r.head, A.AfterSticky))
end

function M.map_selection(sel, cs, no_normalize)
  local rs = {}
  for i, r in ipairs(sel.ranges) do
    rs[i] = M.map_range(r, cs)
  end
  if no_normalize then return raw(rs, sel.primary) end
  return Sel.new(rs, sel.primary)
end

local Tx = {}
Tx.__index = Tx
M.Transaction = Tx

function Tx.change(text, changes)
  return setmetatable({ cs = CS.from_changes(text:len(), changes) }, Tx)
end

function Tx:with_selection(sel)
  self.selection = sel
  return self
end

function Tx.delete(text, deletions)
  local changes = {}
  local last = 0
  for _, d in ipairs(deletions) do
    local from, to = d[1], d[2]
    if last > to then goto continue end
    if last > from then from = last end
    changes[#changes + 1] = { from, to, nil }
    last = to
    ::continue::
  end
  return Tx.change(text, changes)
end

function Tx.change_by_selection(text, sel, f)
  local changes = {}
  for i, r in ipairs(sel.ranges) do
    changes[i] = f(r, i)
  end
  return Tx.change(text, changes)
end

function Tx.change_by_and_with_selection(text, sel, f)
  local end_ranges = {}
  local offset = 0
  local changes = {}
  for i, r in ipairs(sel.ranges) do
    local change, end_range = f(r, i)
    local from, to, rep = change[1], change[2], change[3]
    local size = rep and (#rep - (to - from)) or -(to - from)
    local nr = end_range
    if not nr then
      local cs = CS.from_changes(text:len(), { change })
      nr = M.map_range(r, cs)
    end
    end_ranges[i] = R(nr.anchor + offset, nr.head + offset)
    offset = offset + size
    changes[i] = change
  end
  local tx = Tx.change(text, changes)
  return tx:with_selection(Sel.new(end_ranges, sel.primary))
end

function Tx.delete_by_and_with_selection(text, sel, f)
  local end_ranges = {}
  local offset = 0
  local last = 0
  local dels = {}
  for i, r in ipairs(sel.ranges) do
    local del, end_range = f(r, i)
    local from, to = del[1], del[2]
    local size = last > from and (to - last) or (to - from)
    if size < 0 then size = 0 end
    local nr = end_range
    if not nr then
      local cs = CS.from_changes(text:len(), { { from, to } })
      nr = M.map_range(r, cs)
    end
    end_ranges[i] = R(math.max(0, nr.anchor - offset), math.max(0, nr.head - offset))
    offset = offset + size
    last = math.max(last, to)
    dels[i] = { from, to }
  end
  local tx = Tx.delete(text, dels)
  return tx:with_selection(Sel.new(end_ranges, sel.primary))
end

function Tx.insert(text, sel, s)
  return Tx.change_by_selection(text, sel, function(r)
    return { r.head, r.head, s }
  end)
end

function Tx.change_by_selection_ignore_overlapping(text, sel, change_range, create)
  local last_idx, new_primary
  local ranges = {}
  local changes = {}
  local last = 0
  for idx, r in ipairs(sel.ranges) do
    local s, e = change_range(r)
    if s >= last then
      if idx == sel.primary then
        new_primary = idx
      elseif not new_primary then
        if idx > sel.primary then
          new_primary = last_idx
        else
          last_idx = idx
        end
      end
      ranges[#ranges + 1] = r
      changes[#changes + 1] = { s, e, create(s, e) }
      last = e
    end
  end
  local tx = Tx.change(text, changes)
  local np = 1
  if new_primary then
    for i, r in ipairs(ranges) do
      if r == sel.ranges[new_primary] then np = i end
    end
  end
  return tx, Sel.new(ranges, np)
end

function M.keep_or_remove_matches(text, sel, regex, remove)
  local subject = text:all()
  local res = {}
  for _, r in ipairs(sel.ranges) do
    local m = regex:find(subject, r:from(), r:to())
    if (m ~= nil) ~= remove then res[#res + 1] = r end
  end
  if #res > 0 then return Sel.new(res, 1) end
  return nil
end

function M.select_on_matches(text, sel, regex)
  local subject = text:all()
  local res = {}
  for _, r in ipairs(sel.ranges) do
    for s, e in regex:find_iter(subject, r:from(), r:to()) do
      local nr = R(s, e)
      if not (nr.anchor == r:to() and nr.head == r:to()) then res[#res + 1] = nr end
    end
  end
  if #res > 0 then return Sel.new(res, 1) end
  return nil
end

function M.split_on_newline(text, sel)
  local res = {}
  for _, r in ipairs(sel.ranges) do
    if r:from() == r:to() then
      res[#res + 1] = r
    else
      local start = r:from()
      local sel_end = r:to()
      local frag = text:slice(start, sel_end)
      local i = 1
      while true do
        local nl = frag:find('\n', i, true)
        if not nl then break end
        local line_end = start + (nl - i + 1)
        res[#res + 1] = R(start, line_end - 1)
        start = line_end
        i = nl + 1
      end
      if start < sel_end then res[#res + 1] = R(start, sel_end) end
    end
  end
  return Sel.new(res, 1)
end

function M.split_on_matches(text, sel, regex)
  local subject = text:all()
  local res = {}
  for _, r in ipairs(sel.ranges) do
    if r:from() == r:to() then
      res[#res + 1] = r
    else
      local start = r:from()
      local sel_end = r:to()
      for s, e in regex:find_iter(subject, start, sel_end) do
        res[#res + 1] = R(start, s)
        start = e
      end
      if start < sel_end then res[#res + 1] = R(start, sel_end) end
    end
  end
  if #res == 0 then return sel end
  return Sel.new(res, 1)
end

return M
