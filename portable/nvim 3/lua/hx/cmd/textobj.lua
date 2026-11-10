local S = require('hx.state')
local SL = require('hx.selection')
local U = require('hx.util')
local Syn = require('hx.syntax')
local R = SL.R
local Sel = SL.Selection
local Tx = SL.Transaction

local M_text = {}

local function find_word_boundary(text, pos, forward, long)
  local cat = U.category
  local prev_cat
  if forward then
    prev_cat = pos == 0 and U.WHITESPACE or cat(text:char(text:prev_char(pos)))
  else
    prev_cat = pos == text:len() and U.WHITESPACE or cat(text:char(pos))
  end
  local len = text:len()
  if forward then
    local p = pos
    while p < len do
      local c = cat(text:char(p))
      if c == U.EOL or c == U.WHITESPACE then return p end
      if not long and c ~= prev_cat and p ~= 0 and p ~= len then return p end
      p = text:next_char(p)
      prev_cat = c
    end
    return p
  else
    local p = pos
    while p > 0 do
      local q = text:prev_char(p)
      local c = cat(text:char(q))
      if c == U.EOL or c == U.WHITESPACE then return p end
      if not long and c ~= prev_cat and p ~= 0 and p ~= len then return p end
      p = q
      prev_cat = c
    end
    return p
  end
end

function M_text.textobject_word(text, range, inside, long)
  local pos = range:cursor(text)
  local word_start = find_word_boundary(text, pos, false, long)
  local cp = text:char(pos)
  local word_end
  if not cp or U.category(cp) == U.WHITESPACE or U.category(cp) == U.EOL then
    word_end = pos
  else
    word_end = find_word_boundary(text, text:next_char(pos), true, long)
  end
  if word_start == word_end then return R(word_start, word_end) end
  if inside then return R(word_start, word_end) end
  local p = word_end
  local len = text:len()
  while p < len and U.is_whitespace(text:char(p)) do
    p = text:next_char(p)
  end
  if p > word_end then return R(word_start, p) end
  local q = word_start
  while q > 0 do
    local pq = text:prev_char(q)
    if U.is_whitespace(text:char(pq)) then
      q = pq
    else
      break
    end
  end
  return R(q, word_end)
end

local function line_empty(text, row)
  return #text:line(row) == 0 and text:has_eol(row)
end

function M_text.textobject_paragraph(text, range, inside, count)
  local nl = text:len_lines()
  local line = range:cursor_line(text)
  local prev_line_empty = line_empty(text, math.max(0, line - 1))
  local curr_line_empty = line_empty(text, line)
  local next_line_empty = line + 1 >= nl or line_empty(text, line + 1)
  local last_char = text:prev_grapheme(text:line_next(line)) == range:cursor(text)
  local prev_empty_to_line = prev_line_empty and not curr_line_empty
  local curr_empty_to_line = curr_line_empty and not next_line_empty
  local line_back = line
  if prev_empty_to_line or curr_empty_to_line then line_back = line_back + 1 end
  local function back_walk(lb)
    local idx = lb - 1
    while idx >= 0 and line_empty(text, idx) do
      idx = idx - 1
      lb = lb - 1
    end
    while idx >= 0 and not line_empty(text, idx) do
      idx = idx - 1
      lb = lb - 1
    end
    return lb
  end
  if not (curr_empty_to_line and last_char) then line_back = back_walk(line_back) end
  if curr_empty_to_line and last_char then line = line + 1 end
  local idx = line
  local count_done = 0
  for _ = 1, count do
    local done = false
    while idx < nl and not line_empty(text, idx) do
      idx = idx + 1
      line = line + 1
      done = true
    end
    while idx < nl and line_empty(text, idx) do
      idx = idx + 1
      line = line + 1
    end
    if done then count_done = count_done + 1 end
  end
  local last_paragraph = count_done ~= count and idx >= nl
  if last_paragraph then line_back = back_walk(line_back) end
  if inside then
    local j = line - 1
    while j >= 0 and line_empty(text, j) do
      j = j - 1
      line = line - 1
    end
  end
  return R(text:line_start(line_back), text:line_start(math.min(line, nl)))
end

function M_text.textobject_treesitter(buf, text, range, inside, obj)
  local byte_pos = range:cursor(text)
  local nodes = Syn.capture_nodes(buf, 'textobjects', obj .. (inside and '.inside' or '.around'))
  if not nodes then return range end
  local best
  for _, n in ipairs(nodes) do
    if n.s <= byte_pos and byte_pos < n.e then
      if not best or (n.e - n.s) < (best.e - best.s) then best = n end
    end
  end
  if not best then return range end
  local len = text:len()
  if best.s >= len or best.e >= len then return range end
  return R(best.s, best.e)
end

function M_text.textobject_pair_surround(buf, text, range, inside, ch, count)
  local SUR = require('hx.surround')
  local a, h
  if ch then
    a, h = SUR.find_nth_pairs_pos(buf, text, ch, range, count)
  else
    a, h = SUR.find_nth_closest_pairs_pos(buf, text, range, count)
  end
  if not a or type(a) ~= 'number' then return range end
  if inside then
    if a < h then return R(text:next_grapheme(a), h) end
    return R(a, text:next_grapheme(h))
  end
  if a < h then return R(a, text:next_grapheme(h)) end
  return R(text:next_grapheme(a), h)
end

return function(C, H)
  local reg = C.register
  local Info = function()
    return require('hx.ui.info')
  end
  local I = function()
    return require('hx.input')
  end
  C.textobject = M_text

  local function select_textobject(ctx, inside)
    local count = ctx:get_count()
    ctx:on_next(function(_, key)
      I().autoinfo = nil
      local K = require('hx.keys')
      local ch = K.char(key)
      if not ch then return end
      local buf = H.buf()
      local has_tree = Syn.has_tree(buf)
      local motion = function()
        local text = H.text()
        if ch == 'g' then
          local ok, diff = pcall(require, 'hx.diff')
          if not ok or not diff.hunks(buf) then
            H.status('Diff is not available in current buffer')
            return
          end
        end
        local function ts(obj, r)
          if not has_tree then return r end
          return M_text.textobject_treesitter(buf, text, r, inside, obj)
        end
        local cp = U.decode(ch, 1)
        local sel = H.sel():transform(function(r)
          if ch == 'w' then return M_text.textobject_word(text, r, inside, false) end
          if ch == 'W' then return M_text.textobject_word(text, r, inside, true) end
          if ch == 't' then return ts('class', r) end
          if ch == 'f' then return ts('function', r) end
          if ch == 'a' then return ts('parameter', r) end
          if ch == 'c' then return ts('comment', r) end
          if ch == 'T' then return ts('test', r) end
          if ch == 'e' then return ts('entry', r) end
          if ch == 'x' then return ts('xml-element', r) end
          if ch == 'p' then return M_text.textobject_paragraph(text, r, inside, count) end
          if ch == 'm' then
            return M_text.textobject_pair_surround(has_tree and buf or nil, text, r, inside, nil, count)
          end
          if ch == 'g' then
            local diff = require('hx.diff')
            local line = r:cursor_line(text)
            local h = diff.hunk_at(buf, line)
            if not h then return r end
            return R(text:line_start(h.after_start), text:line_start(h.after_end)):with_direction(r:forward())
          end
          if not ch:match('^%w$') then
            return M_text.textobject_pair_surround(has_tree and buf or nil, text, r, inside, cp, count)
          end
          return r
        end)
        H.set_sel(sel)
      end
      H.apply_motion(motion)
    end)
    local title = inside and 'Match inside' or 'Match around'
    I().autoinfo = Info().new(title, {
      { 'w', 'Word' },
      { 'W', 'WORD' },
      { 'p', 'Paragraph' },
      { 't', 'Type definition (tree-sitter)' },
      { 'f', 'Function (tree-sitter)' },
      { 'a', 'Argument/parameter (tree-sitter)' },
      { 'c', 'Comment (tree-sitter)' },
      { 'T', 'Test (tree-sitter)' },
      { 'e', 'Data structure entry (tree-sitter)' },
      { 'm', 'Closest surrounding pair (tree-sitter)' },
      { 'g', 'Change' },
      { 'x', '(X)HTML element (tree-sitter)' },
      { ' ', '... or any character acting as a pair' },
    })
  end
  reg('select_textobject_around', function(ctx) select_textobject(ctx, false) end)
  reg('select_textobject_inner', function(ctx) select_textobject(ctx, true) end)

  local SURROUND_HELP = {
    { 'm', 'Nearest matching pair' },
    { '( or )', 'Parentheses' },
    { '{ or }', 'Curly braces' },
    { '< or >', 'Angled brackets' },
    { '[ or ]', 'Square brackets' },
    { ' ', '... or any character' },
  }
  local function help_from(i)
    local out = {}
    for k = i, #SURROUND_HELP do
      out[#out + 1] = SURROUND_HELP[k]
    end
    return out
  end

  reg('surround_add', function(ctx)
    ctx:on_next(function(_, key)
      I().autoinfo = nil
      local K = require('hx.keys')
      local ch = K.char(key)
      local open, close, len
      if ch then
        local MB = require('hx.match_brackets')
        local o, c = MB.get_pair(U.decode(ch, 1))
        open, close = U.encode(o), U.encode(c)
        len = #open + #close
      elseif key == 'ret' then
        open, close, len = '\n', '\n', 2
      else
        return
      end
      local text = H.text()
      local sel = H.sel()
      local changes, ranges = {}, {}
      local offs = 0
      for _, r in ipairs(sel.ranges) do
        changes[#changes + 1] = { r:from(), r:from(), open }
        changes[#changes + 1] = { r:to(), r:to(), close }
        ranges[#ranges + 1] = R(offs + r:from(), offs + r:to() + len):with_direction(r:forward())
        offs = offs + len
      end
      H.apply(Tx.change(text, changes):with_selection(Sel.new(ranges, sel.primary)))
      H.exit_select_mode()
    end)
    I().autoinfo = Info().new('Surround selections with', help_from(2))
  end)

  local function get_surround_pos(ch, count)
    local SUR = require('hx.surround')
    local buf = H.buf()
    local text = H.text()
    local has_tree = Syn.has_tree(buf)
    return SUR.get_surround_pos(has_tree and buf or nil, text, H.sel(), ch and U.decode(ch, 1) or nil, count)
  end

  reg('surround_replace', function(ctx)
    local count = ctx:get_count()
    ctx:on_next(function(c2, key)
      I().autoinfo = nil
      local K = require('hx.keys')
      local ch = K.char(key)
      if not ch then return end
      local surround_ch = ch ~= 'm' and ch or nil
      local positions, err = get_surround_pos(surround_ch, count)
      if not positions then
        local SUR = require('hx.surround')
        H.error(SUR.error_message and SUR.error_message(err) or tostring(err))
        return
      end
      local sel = H.sel():copy()
      local ranges = {}
      for _, p in ipairs(positions) do
        ranges[#ranges + 1] = SL.Range.point(p)
      end
      require('hx.state').set_sel(Sel.new(ranges, (sel.primary - 1) * 2 + 1), H.win(), H.buf())
      c2:on_next(function(_, key2)
        I().autoinfo = nil
        local to = K.char(key2)
        if not to then
          require('hx.state').set_sel(sel, H.win(), H.buf())
          return
        end
        local MB = require('hx.match_brackets')
        local o, c = MB.get_pair(U.decode(to, 1))
        local sorted = {}
        for i = 1, #positions, 2 do
          sorted[#sorted + 1] = { positions[i], U.encode(o) }
          sorted[#sorted + 1] = { positions[i + 1], U.encode(c) }
        end
        table.sort(sorted, function(a, b) return a[1] < b[1] end)
        local text = H.text()
        local changes = {}
        for _, sp in ipairs(sorted) do
          changes[#changes + 1] = { sp[1], text:next_char(sp[1]), sp[2] }
        end
        require('hx.state').set_sel(sel, H.win(), H.buf())
        H.apply(Tx.change(text, changes))
        H.exit_select_mode()
      end)
      I().autoinfo = Info().new('Replace with a pair of', help_from(2))
    end)
    I().autoinfo = Info().new('Replace surrounding pair of', SURROUND_HELP)
  end)

  reg('surround_delete', function(ctx)
    local count = ctx:get_count()
    ctx:on_next(function(_, key)
      I().autoinfo = nil
      local K = require('hx.keys')
      local ch = K.char(key)
      if not ch then return end
      local surround_ch = ch ~= 'm' and ch or nil
      local positions, err = get_surround_pos(surround_ch, count)
      if not positions then
        local SUR = require('hx.surround')
        H.error(SUR.error_message and SUR.error_message(err) or tostring(err))
        return
      end
      table.sort(positions)
      local text = H.text()
      local changes = {}
      for _, p in ipairs(positions) do
        changes[#changes + 1] = { p, text:next_char(p), nil }
      end
      H.apply(Tx.change(text, changes))
      H.exit_select_mode()
    end)
    I().autoinfo = Info().new('Delete surrounding pair of', SURROUND_HELP)
  end)
end
