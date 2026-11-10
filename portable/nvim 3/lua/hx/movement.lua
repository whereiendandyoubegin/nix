local U = require('hx.util')
local SL = require('hx.selection')
local R = SL.R

local M = {}

local cat = U.category
local is_eol = U.is_line_ending
local rws = U.rust_whitespace

function M.move_horizontally(text, range, forward, count, extend)
  local pos = range:cursor(text)
  local new_pos
  if forward then
    new_pos = text:next_grapheme(pos, count)
  else
    new_pos = text:prev_grapheme(pos, count)
  end
  return range:put_cursor(text, new_pos, extend)
end

local function visual_col_in_line(text, row, pos, ts)
  return text:visual_col(pos, ts)
end

local function pos_at_visual_col(text, row, col, ts, allow_newline)
  local l = text:line(row)
  local ls = text:line_start(row)
  local w = 0
  local i = 1
  while i <= #l do
    local cp, n = U.decode(l, i)
    local cw
    if cp == 9 then
      cw = ts - w % ts
    else
      cw = vim.api.nvim_strwidth(l:sub(i, i + n - 1))
    end
    if w + cw > col then return ls + i - 1 end
    w = w + cw
    i = i + n
  end
  if allow_newline then return ls + #l end
  return ls + #l
end

function M.move_vertically(text, range, forward, count, extend, ts)
  ts = ts or vim.bo.tabstop
  local pos = range:cursor(text)
  local line = text:line_of(pos)
  local vcol = visual_col_in_line(text, line, pos, ts)
  local new_col = range.ovp and range.ovp[2] or vcol
  local nlines = text:len_lines()
  local new_line
  if forward then
    new_line = line + count
  else
    new_line = math.max(0, line - count)
  end
  local new_pos
  if new_line >= nlines - 1 then
    new_line = nlines - 1
    new_pos = pos_at_visual_col(text, new_line, new_col, ts, true)
    if text:line_start(new_line) >= text:len() then new_pos = text:len() end
  else
    local l = text:line(new_line)
    local ls = text:line_start(new_line)
    new_pos = pos_at_visual_col(text, new_line, new_col, ts, false)
    if new_pos > ls + #l then new_pos = ls + #l end
    if new_pos == ls + #l and #l > 0 then
      new_pos = ls + #l
    end
  end
  if extend and #text:line(new_line) == 0 and not text:has_eol(new_line) then return range end
  local nr = range:put_cursor(text, new_pos, extend)
  nr.ovp = { 0, new_col }
  return nr
end

function M.move_vertically_visual(text, range, forward, count, extend, win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.wo[win].wrap then
    return M.move_vertically(text, range, forward, count, extend, vim.bo[vim.api.nvim_win_get_buf(win)].tabstop)
  end
  local ts = vim.bo[vim.api.nvim_win_get_buf(win)].tabstop
  local pos = range:cursor(text)
  local row = text:line_of(pos)
  local width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
  if width <= 0 then width = 1 end
  local function line_breaks(r)
    local starts = { 0 }
    local l = text:line(r)
    if #l == 0 then return starts end
    local ok, res = pcall(function()
      local out = { 0 }
      local last_row = nil
      local buf = vim.api.nvim_win_get_buf(win)
      local i = 1
      local w = 0
      local brk = vim.o.breakat
      local lb = vim.wo[win].linebreak
      local last_break_i, last_break_w = nil, nil
      local avail = width
      local sbr = vim.wo[win].showbreak ~= '' and vim.wo[win].showbreak or vim.o.showbreak
      local cont_avail = width - vim.api.nvim_strwidth(sbr)
      local bri = vim.wo[win].breakindent
      local indent_w = 0
      if bri then
        local ind = l:match('^[ \t]*')
        indent_w = vim.fn.strdisplaywidth(ind)
        if indent_w > 40 then indent_w = 40 end
      end
      while i <= #l do
        local cp, n = U.decode(l, i)
        local ch = l:sub(i, i + n - 1)
        local cw = cp == 9 and (ts - w % ts) or vim.api.nvim_strwidth(ch)
        if w + cw > avail then
          local start
          if lb and last_break_i and last_break_i > out[#out] + 1 then
            start = last_break_i
          else
            start = i
          end
          out[#out + 1] = start - 1
          avail = cont_avail - indent_w
          w = 0
          i = start
          last_break_i = nil
        else
          w = w + cw
          if lb and brk:find(ch, 1, true) then last_break_i = i + n end
          i = i + n
        end
      end
      return out
    end)
    if ok then return res end
    return starts
  end
  local function visual_offset(r, p)
    local starts = line_breaks(r)
    local col = p - text:line_start(r)
    local vr = 1
    for k = 1, #starts do
      if starts[k] <= col then vr = k end
    end
    local l = text:line(r)
    local seg_start = starts[vr]
    local vc = vim.fn.strdisplaywidth(l:sub(seg_start + 1, col))
    return vr - 1, vc, starts
  end
  local vrow, vcol, starts = visual_offset(row, pos)
  local new_col = range.ovp and range.ovp[2] or vcol
  local steps = count
  local r = row
  local vr = vrow
  local cur_starts = starts
  if forward then
    while steps > 0 do
      if vr + 1 < #cur_starts then
        vr = vr + 1
      else
        if r + 1 >= text:len_lines() - (text.is_string and 0 or 1) then break end
        r = r + 1
        cur_starts = line_breaks(r)
        vr = 0
      end
      steps = steps - 1
    end
  else
    while steps > 0 do
      if vr > 0 then
        vr = vr - 1
      else
        if r == 0 then break end
        r = r - 1
        cur_starts = line_breaks(r)
        vr = #cur_starts - 1
      end
      steps = steps - 1
    end
  end
  local l = text:line(r)
  local ls = text:line_start(r)
  local seg_start = cur_starts[vr + 1] or 0
  local seg_end = cur_starts[vr + 2] or #l
  local i = seg_start + 1
  local w = 0
  local new_pos = ls + seg_end
  while i <= seg_end do
    local cp, n = U.decode(l, i)
    local cw = cp == 9 and (ts - w % ts) or vim.api.nvim_strwidth(l:sub(i, i + n - 1))
    if w + cw > new_col then
      new_pos = ls + i - 1
      break
    end
    w = w + cw
    i = i + n
  end
  if i > seg_end then
    if cur_starts[vr + 2] then
      new_pos = text:prev_char(ls + seg_end)
    else
      new_pos = ls + #l
    end
  end
  if extend and #text:line(r) == 0 and not text:has_eol(r) then return range end
  local nr = range:put_cursor(text, new_pos, extend)
  nr.ovp = { 0, new_col }
  return nr
end

local function is_word_boundary(a, b)
  return cat(a) ~= cat(b)
end

local function is_long_word_boundary(a, b)
  local ca, cb = cat(a), cat(b)
  if (ca == U.WORD and cb == U.PUNCT) or (ca == U.PUNCT and cb == U.WORD) then return false end
  return ca ~= cb
end

local function is_sub_word_boundary(a, b, forward)
  local ca, cb = cat(a), cat(b)
  if ca == U.WORD and cb == U.WORD then
    if (a == 95) ~= (b == 95) then return true end
    if forward then return U.is_lower(a) and U.is_upper(b) end
    return U.is_upper(a) and U.is_lower(b)
  end
  return ca ~= cb
end

local T = {
  NextWordStart = 1, NextWordEnd = 2, PrevWordStart = 3, PrevWordEnd = 4,
  NextLongWordStart = 5, NextLongWordEnd = 6, PrevLongWordStart = 7, PrevLongWordEnd = 8,
  NextSubWordStart = 9, NextSubWordEnd = 10, PrevSubWordStart = 11, PrevSubWordEnd = 12,
}
M.Target = T

local function is_prev(t)
  return t == T.PrevWordStart or t == T.PrevLongWordStart or t == T.PrevSubWordStart
    or t == T.PrevWordEnd or t == T.PrevLongWordEnd or t == T.PrevSubWordEnd
end

local function reached_target(t, p, n)
  if t == T.NextWordStart or t == T.PrevWordEnd then
    return is_word_boundary(p, n) and (is_eol(n) or not rws(n))
  elseif t == T.NextWordEnd or t == T.PrevWordStart then
    return is_word_boundary(p, n) and (not rws(p) or is_eol(n))
  elseif t == T.NextLongWordStart or t == T.PrevLongWordEnd then
    return is_long_word_boundary(p, n) and (is_eol(n) or not rws(n))
  elseif t == T.NextLongWordEnd or t == T.PrevLongWordStart then
    return is_long_word_boundary(p, n) and (not rws(p) or is_eol(n))
  elseif t == T.NextSubWordStart then
    return is_sub_word_boundary(p, n, true) and (is_eol(n) or not (rws(n) or n == 95))
  elseif t == T.PrevSubWordEnd then
    return is_sub_word_boundary(p, n, false) and (is_eol(n) or not (rws(n) or n == 95))
  elseif t == T.NextSubWordEnd then
    return is_sub_word_boundary(p, n, true) and (not (rws(p) or p == 95) or is_eol(n))
  elseif t == T.PrevSubWordStart then
    return is_sub_word_boundary(p, n, false) and (not (rws(p) or p == 95) or is_eol(n))
  end
  return false
end

local function range_to_target(text, target, origin)
  local prev = is_prev(target)
  local anchor, head = origin.anchor, origin.head
  local it = origin.head
  local len = text:len()
  local function nxt()
    if prev then
      if it <= 0 then return nil end
      it = text:prev_char(it)
      return (text:char(it))
    else
      if it >= len then return nil end
      local cp = text:char(it)
      it = text:next_char(it)
      return cp
    end
  end
  local function back()
    if prev then
      if it >= len then return nil end
      local cp = text:char(it)
      it = text:next_char(it)
      return cp
    else
      if it <= 0 then return nil end
      it = text:prev_char(it)
      return (text:char(it))
    end
  end
  local function advance(h)
    if prev then
      if h <= 0 then return 0 end
      return text:prev_char(h)
    end
    return text:next_char(h)
  end
  local prev_ch
  do
    local ch = back()
    if ch then nxt() end
    prev_ch = ch
  end
  while true do
    local ch = nxt()
    if ch == nil then break end
    if is_eol(ch) then
      prev_ch = ch
      head = advance(head)
    else
      back()
      break
    end
  end
  if prev_ch and is_eol(prev_ch) then anchor = head end
  local head_start = head
  while true do
    local next_ch = nxt()
    if next_ch == nil then break end
    if prev_ch == nil or reached_target(target, prev_ch, next_ch) then
      if head == head_start then
        anchor = head
      else
        break
      end
    end
    prev_ch = next_ch
    head = advance(head)
  end
  return R(anchor, head)
end

local function word_move(text, range, count, target)
  local p = is_prev(target)
  if (p and range.head == 0) or (not p and range.head == text:len()) then return range end
  local start
  if p then
    if range.anchor < range.head then
      start = R(range.head, text:prev_grapheme(range.head))
    else
      start = R(text:next_grapheme(range.head), range.head)
    end
  else
    if range.anchor < range.head then
      start = R(text:prev_grapheme(range.head), range.head)
    else
      start = R(range.head, text:next_grapheme(range.head))
    end
  end
  local r = start
  for _ = 1, count do
    local nr = range_to_target(text, target, r)
    if nr.anchor == r.anchor and nr.head == r.head then break end
    r = nr
  end
  return r
end
M.word_move = word_move

for name, t in pairs({
  move_next_word_start = T.NextWordStart, move_next_word_end = T.NextWordEnd,
  move_prev_word_start = T.PrevWordStart, move_prev_word_end = T.PrevWordEnd,
  move_next_long_word_start = T.NextLongWordStart, move_next_long_word_end = T.NextLongWordEnd,
  move_prev_long_word_start = T.PrevLongWordStart, move_prev_long_word_end = T.PrevLongWordEnd,
  move_next_sub_word_start = T.NextSubWordStart, move_next_sub_word_end = T.NextSubWordEnd,
  move_prev_sub_word_start = T.PrevSubWordStart, move_prev_sub_word_end = T.PrevSubWordEnd,
}) do
  M[name] = function(text, range, count)
    return word_move(text, range, count, t)
  end
end

local function line_empty(text, row)
  return #text:line(row) == 0 and text:has_eol(row)
end

function M.move_prev_paragraph(text, range, count, extend)
  local line = range:cursor_line(text)
  local first_char = text:line_start(line) == range:cursor(text)
  local prev_line_empty = line_empty(text, math.max(0, line - 1))
  local curr_line_empty = line_empty(text, line)
  local prev_empty_to_line = prev_line_empty and not curr_line_empty
  if prev_empty_to_line and not first_char then line = line + 1 end
  local idx = line - 1
  local function peek()
    if idx < 0 then return nil end
    return line_empty(text, idx)
  end
  local last_line = line
  for _ = 1, count do
    while peek() == true do
      idx = idx - 1
      line = line - 1
    end
    while peek() == false do
      idx = idx - 1
      line = line - 1
    end
    if line == last_line then break end
    last_line = line
  end
  local head = text:line_start(line)
  local anchor
  if not extend then
    if prev_empty_to_line and first_char then
      anchor = range:cursor(text)
    else
      anchor = range.head
    end
  else
    anchor = range:put_cursor(text, head, true).anchor
  end
  return R(anchor, head)
end

function M.move_next_paragraph(text, range, count, extend)
  local line = range:cursor_line(text)
  local last_char = text:prev_grapheme(text:line_next(line)) == range:cursor(text)
  local curr_line_empty = line_empty(text, line)
  local next_line_empty = line_empty(text, math.min(text:len_lines() - 1, line + 1))
  local curr_empty_to_line = curr_line_empty and not next_line_empty
  if curr_empty_to_line and last_char then line = line + 1 end
  local idx = line
  local nl = text:len_lines()
  local function peek()
    if idx >= nl then return nil end
    return line_empty(text, idx)
  end
  local last_line = line
  for _ = 1, count do
    while peek() == false do
      idx = idx + 1
      line = line + 1
    end
    while peek() == true do
      idx = idx + 1
      line = line + 1
    end
    if line == last_line then break end
    last_line = line
  end
  local head = text:line_start(line)
  local anchor
  if not extend then
    if curr_empty_to_line and last_char then
      anchor = range.head
    else
      anchor = range:cursor(text)
    end
  else
    anchor = range:put_cursor(text, head, true).anchor
  end
  return R(anchor, head)
end

function M.skip_while(text, pos, f)
  local p = pos
  local len = text:len()
  while p < len do
    local cp = text:char(p)
    if not f(cp) then return p end
    p = text:next_char(p)
  end
  return nil
end

function M.backwards_skip_while(text, pos, f)
  local p = pos
  while p > 0 do
    local q = text:prev_char(p)
    local cp = text:char(q)
    if not f(cp) then return p end
    p = q
  end
  return nil
end

local function find_parent_start(node)
  local start = node:start()
  local _, _, sb = node:start()
  local n = node
  while true do
    local _, _, nb = n:start()
    if not (nb >= sb or not n:named()) then break end
    local p = n:parent()
    if not p then return nil end
    n = p
  end
  return n
end

function M.move_parent_node_end(buf, text, sel, forward, extend)
  local TS = require('hx.syntax')
  return sel:transform(function(range)
    local node = TS.named_descendant_for_byte_range(buf, range:from(), range:to())
    if not node then return range end
    local end_head
    if forward then
      local _, _, eb = node:end_()
      end_head = eb
    else
      local _, _, sb = node:start()
      end_head = sb
      if end_head == range:cursor(text) then
        node = find_parent_start(node) or node
        local _, _, sb2 = node:start()
        end_head = sb2
      end
    end
    if not extend then
      if range:forward() then return R(end_head, end_head + 1) end
      return R(end_head + 1, end_head)
    end
    if end_head >= range.anchor then end_head = end_head + 1 end
    return R(range.anchor, end_head)
  end)
end

function M.goto_treesitter_object(buf, text, range, object, forward, count)
  local TS = require('hx.syntax')
  local function get_range(r)
    local byte_pos = r:cursor(text)
    local nodes = TS.capture_nodes_any(buf, 'textobjects',
      { object .. '.movement', object .. '.around', object .. '.inside' })
    if not nodes then return nil end
    local best
    for _, n in ipairs(nodes) do
      local s, e = n.s, n.e
      if forward then
        if s > byte_pos then
          if not best or s < best.s or (s == best.s and e > best.e) then best = n end
        end
      else
        if e < byte_pos then
          if not best or e > best.e or (e == best.e and s < best.s) then best = n end
        end
      end
    end
    if not best then return nil end
    local len = text:len()
    if best.s >= len or best.e >= len then return nil end
    return R(best.s, best.e)
  end
  local last = range
  for _ = 1, count do
    local r = get_range(last)
    if r and not (r.anchor == last.anchor and r.head == last.head) then
      last = r
    else
      break
    end
  end
  return last
end

return M
