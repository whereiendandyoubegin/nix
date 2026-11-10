local U = require('hx.util')
local MB = require('hx.match_brackets')
local Sel = require('hx.selection')
local Range = Sel.Range

local M = {}

M.Error = {
  PairNotFound = 'PairNotFound',
  CursorOverlap = 'CursorOverlap',
  RangeExceedsText = 'RangeExceedsText',
  CursorOnAmbiguousPair = 'CursorOnAmbiguousPair',
}
local E = M.Error

local MESSAGES = {
  PairNotFound = 'Surround pair not found around all cursors',
  CursorOverlap = 'Cursors overlap for a single surround pair range',
  RangeExceedsText = 'Cursor range exceeds text length',
  CursorOnAmbiguousPair = 'Cursor on ambiguous surround pair',
}
function M.error_message(err)
  return MESSAGES[err] or tostring(err)
end

local function to_cp(ch)
  if type(ch) == 'string' then return (U.decode(ch, 1)) end
  return ch
end

local function syntax_of(syntax)
  if syntax == nil or syntax == false then return nil end
  local ok, has = pcall(function()
    return require('hx.syntax').root(syntax) ~= nil
  end)
  if ok and has then return syntax end
  return nil
end

local function find_nth_char(n, text, ch, pos, forward)
  if n == 0 then return nil end
  if pos > text:len() then return nil end
  if forward then
    while true do
      if pos >= text:len() then return nil end
      if text:char(pos) == ch then
        n = n - 1
        if n == 0 then return pos end
      end
      pos = text:next_char(pos)
    end
  else
    while true do
      if pos <= 0 then return nil end
      pos = text:prev_char(pos)
      if text:char(pos) == ch then
        n = n - 1
        if n == 0 then return pos end
      end
    end
  end
end
M.find_nth_char = find_nth_char

local function find_nth_open_pair(text, open, close, pos, n)
  if pos >= text:len() then return nil end
  if text:char(pos) == open then return pos end
  for _ = 1, n do
    local step_over = 0
    while true do
      if pos <= 0 then return nil end
      pos = text:prev_char(pos)
      local c = text:char(pos)
      if c == close then
        step_over = step_over + 1
      elseif c == open then
        if step_over == 0 then break end
        step_over = math.max(0, step_over - 1)
      end
    end
  end
  return pos
end

local function find_nth_close_pair(text, open, close, pos, n)
  if pos >= text:len() then return nil end
  if text:char(pos) == close then return pos end
  for _ = 1, n do
    local step_over = 0
    while true do
      pos = text:next_char(pos)
      if pos >= text:len() then return nil end
      local c = text:char(pos)
      if c == open then
        step_over = step_over + 1
      elseif c == close then
        if step_over == 0 then break end
        step_over = math.max(0, step_over - 1)
      end
    end
  end
  return pos
end
M.find_nth_open_pair = find_nth_open_pair
M.find_nth_close_pair = find_nth_close_pair

local function last_char_of(text, range)
  local to = range:to()
  if to <= 0 then return -1 end
  return text:prev_char(to)
end

local function find_nth_closest_pairs_ts(syntax, text, range, skip)
  local opening = range:from()
  local closing = range:to()
  local last = last_char_of(text, range)
  while skip > 0 do
    closing = MB.find_matching_bracket_fuzzy(syntax, text, closing)
    if not closing then return nil, E.PairNotFound end
    opening = MB.find_matching_bracket(syntax, text, closing)
    if not opening then return nil, E.PairNotFound end
    if closing < opening then
      opening, closing = closing, opening
    end
    if range:from() < opening or closing < last then
      closing = text:next_grapheme(closing)
    else
      skip = skip - 1
      if skip ~= 0 then closing = text:next_grapheme(closing) end
    end
  end
  if range:forward() then return opening, closing end
  return closing, opening
end

local function find_nth_closest_pairs_plain(text, range, skip)
  local stack = {}
  local pos = range:from()
  local upper = pos < text:len() and text:next_char(pos) or pos + 1
  local last = math.max(0, last_char_of(text, range))
  local close_pos = pos
  while close_pos < text:len() do
    local ch = text:char(close_pos)
    if MB.is_open_bracket(ch) then
      stack[#stack + 1] = ch
    elseif MB.is_close_bracket(ch) then
      local open, close = MB.get_pair(ch)
      if stack[#stack] == open then
        stack[#stack] = nil
      else
        local open_pos = find_nth_open_pair(text, open, close, close_pos, 1)
        if open_pos and open_pos <= upper and close_pos >= last then
          if skip > 1 then
            skip = skip - 1
          else
            if range:forward() then return open_pos, close_pos end
            return close_pos, open_pos
          end
        end
      end
    end
    close_pos = text:next_char(close_pos)
  end
  return nil, E.PairNotFound
end

function M.find_nth_closest_pairs_pos(syntax, text, range, skip)
  syntax = syntax_of(syntax)
  if syntax then return find_nth_closest_pairs_ts(syntax, text, range, skip) end
  return find_nth_closest_pairs_plain(text, range, skip)
end

function M.find_nth_pairs_pos(syntax, text, ch, range, n)
  syntax = syntax_of(syntax)
  ch = to_cp(ch)
  if text:len() == 0 or text:next_char(0) >= text:len() then return nil, E.PairNotFound end
  if range:to() >= text:len() then return nil, E.RangeExceedsText end

  local open, close = MB.get_pair(ch)
  local pos = range:cursor(text)
  local o, c
  if open == close then
    if text:char(pos) == open then
      local m
      if syntax then
        m = MB.find_matching_bracket_fuzzy(syntax, text, pos)
      else
        m = MB.find_matching_bracket_plaintext(text, pos)
      end
      if not m then return nil, E.CursorOnAmbiguousPair end
      if m > pos then
        o, c = pos, m
      else
        o, c = m, pos
      end
    else
      o = find_nth_char(n, text, open, pos, false)
      c = find_nth_char(n, text, close, pos, true)
    end
  else
    o = find_nth_open_pair(text, open, close, pos, n)
    c = find_nth_close_pair(text, open, close, pos, n)
  end
  if not (o and c) then return nil, E.PairNotFound end
  if range:forward() then return o, c end
  return c, o
end

function M.get_surround_pos(syntax, text, selection, ch, skip)
  local change_pos = {}
  local seen = {}
  for _, range in ipairs(selection.ranges) do
    local a, b
    if ch ~= nil then
      a, b = M.find_nth_pairs_pos(syntax, text, ch, range, skip)
    else
      a, b = M.find_nth_closest_pairs_pos(syntax, text, range, skip)
    end
    if not a then return nil, b end
    local open_pos, close_pos = math.min(a, b), math.max(a, b)
    if seen[open_pos] or seen[close_pos] then return nil, E.CursorOverlap end
    change_pos[#change_pos + 1] = open_pos
    change_pos[#change_pos + 1] = close_pos
    seen[open_pos] = true
    seen[close_pos] = true
  end
  return change_pos
end

local function pair_surround_impl(syntax, text, range, objtype, ch, count)
  local anchor, head
  if ch ~= nil then
    anchor, head = M.find_nth_pairs_pos(syntax, text, ch, range, count)
  else
    anchor, head = M.find_nth_closest_pairs_pos(syntax, text, range, count)
  end
  if not anchor then return range end
  local inside = objtype == 'inside' or objtype == 'Inside' or objtype == 'i'
  if inside then
    if anchor < head then return Range.new(text:next_grapheme(anchor), head) end
    return Range.new(anchor, text:next_grapheme(head))
  end
  if anchor < head then return Range.new(anchor, text:next_grapheme(head)) end
  return Range.new(text:next_grapheme(anchor), head)
end

function M.textobject_pair_surround(syntax, text, range, objtype, ch, count)
  return pair_surround_impl(syntax, text, range, objtype, ch, count)
end

function M.textobject_pair_surround_closest(syntax, text, range, objtype, count)
  return pair_surround_impl(syntax, text, range, objtype, nil, count)
end

function M.surround_add_tx(text, selection, ch, opts)
  local o, c
  if opts and opts.open then
    o, c = opts.open, opts.close
  else
    local oc, cc = MB.get_pair(to_cp(ch))
    o, c = U.encode(oc), U.encode(cc)
  end
  local surround_len = #o + #c
  local changes, ranges = {}, {}
  local offs = 0
  for _, r in ipairs(selection.ranges) do
    changes[#changes + 1] = { r:from(), r:from(), o }
    changes[#changes + 1] = { r:to(), r:to(), c }
    ranges[#ranges + 1] = Range.new(offs + r:from(), offs + r:to() + surround_len):with_direction(r:forward())
    offs = offs + surround_len
  end
  return Sel.Transaction.change(text, changes):with_selection(Sel.Selection.new(ranges, selection.primary))
end

function M.surround_replace_tx(text, change_pos, to)
  local oc, cc = MB.get_pair(to_cp(to))
  local sorted = {}
  for i = 1, #change_pos, 2 do
    sorted[#sorted + 1] = { change_pos[i], oc }
    sorted[#sorted + 1] = { change_pos[i + 1], cc }
  end
  table.sort(sorted, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  local changes = {}
  for _, p in ipairs(sorted) do
    changes[#changes + 1] = { p[1], text:next_char(p[1]), U.encode(p[2]) }
  end
  return Sel.Transaction.change(text, changes)
end

function M.surround_delete_tx(text, change_pos)
  local ps = { unpack(change_pos) }
  table.sort(ps)
  local changes = {}
  for _, p in ipairs(ps) do
    changes[#changes + 1] = { p, text:next_char(p), nil }
  end
  return Sel.Transaction.change(text, changes)
end

return M
