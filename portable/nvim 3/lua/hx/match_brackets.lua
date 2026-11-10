local U = require('hx.util')
local M = {}

local MAX_PLAINTEXT_SCAN = 10000
local MATCH_LIMIT = 16

local function cp(s)
  return (U.decode(s, 1))
end

M.BRACKETS = {
  { cp('('), cp(')') }, { cp('{'), cp('}') }, { cp('['), cp(']') }, { cp('<'), cp('>') },
  { cp('‘'), cp('’') }, { cp('“'), cp('”') }, { cp('«'), cp('»') }, { cp('「'), cp('」') },
  { cp('（'), cp('）') },
}
M.PAIRS = {}
for _, p in ipairs(M.BRACKETS) do
  M.PAIRS[#M.PAIRS + 1] = p
end
for _, c in ipairs({ '"', "'", '`', '|' }) do
  M.PAIRS[#M.PAIRS + 1] = { cp(c), cp(c) }
end

local function in_list(list, f)
  for _, p in ipairs(list) do
    if f(p) then return p end
  end
end

function M.get_pair(ch)
  local p = in_list(M.PAIRS, function(p)
    return p[1] == ch or p[2] == ch
  end)
  if p then return p[1], p[2] end
  return ch, ch
end

function M.is_open_bracket(ch)
  return in_list(M.BRACKETS, function(p) return p[1] == ch end) ~= nil
end
function M.is_close_bracket(ch)
  return in_list(M.BRACKETS, function(p) return p[2] == ch end) ~= nil
end
function M.is_valid_bracket(ch)
  return in_list(M.BRACKETS, function(p) return p[1] == ch or p[2] == ch end) ~= nil
end
function M.is_open_pair(ch)
  return in_list(M.PAIRS, function(p) return p[1] == ch end) ~= nil
end
function M.is_close_pair(ch)
  return in_list(M.PAIRS, function(p) return p[2] == ch end) ~= nil
end
function M.is_valid_pair(ch)
  return in_list(M.PAIRS, function(p) return p[1] == ch or p[2] == ch end) ~= nil
end

function M.find_matching_bracket_plaintext(text, pos, lo, hi)
  lo = lo or 0
  hi = hi or text:len()
  if pos >= hi then return nil end
  local bracket = text:char(pos)
  if not bracket then return nil end
  local o, c = M.get_pair(bracket)
  local matching = (o == bracket) and c or o
  if not M.is_valid_bracket(bracket) then return nil end
  local fwd = M.is_open_bracket(bracket)
  local open_cnt = 1
  local p = pos
  for _ = 1, MAX_PLAINTEXT_SCAN do
    local cand
    if fwd then
      p = text:next_char(p)
      if p >= hi then return nil end
      cand = text:char(p)
    else
      if p <= lo then return nil end
      p = text:prev_char(p)
      cand = text:char(p)
    end
    if cand == bracket then
      open_cnt = open_cnt + 1
    elseif cand == matching then
      if open_cnt == 1 then return p end
      open_cnt = open_cnt - 1
    end
  end
  return nil
end

local function srange(node)
  local _, _, sb, _, _, eb = node:range(true)
  return sb, eb
end

local function as_char(text, node)
  local s, e = srange(node)
  if e - s ~= 1 then return nil end
  return s, text:char(s)
end

local function as_close_pair(text, node)
  local _, c = as_char(text, node)
  if not c then return nil end
  for _, p in ipairs(M.PAIRS) do
    if p[2] == c then return c, p[1] end
  end
end

local function as_open_pair(text, node)
  local _, o = as_char(text, node)
  if not o then return nil end
  for _, p in ipairs(M.PAIRS) do
    if p[1] == o then return o, p[2] end
  end
end

local function find_pair_end(text, node, start_char, end_char, forward)
  local depth = 0
  local n = node
  for _ = 1, MATCH_LIMIT do
    if not n then return nil end
    local pos, c = as_char(text, n)
    if c then
      if c == end_char then
        if depth == 0 then return pos end
        depth = depth - 1
      elseif c == start_char then
        depth = depth + 1
      end
    end
    if forward then
      n = n:next_sibling()
    else
      n = n:prev_sibling()
    end
  end
  return nil
end

local function descendant_for_byte(root, text, a, b)
  local function rc(p)
    local row = text:line_of(p)
    return row, p - text:line_start(row)
  end
  local sr, sc = rc(a)
  local er, ec = rc(b)
  return root:descendant_for_range(sr, sc, er, ec), root
end

local function find_pair(buf, text, pos_, traverse_parents)
  local Syn = require('hx.syntax')
  local root = Syn.root(buf)
  if not root then return nil end
  local pos = pos_
  local node = descendant_for_byte(root, text, pos, pos)
  if not node then return nil end
  while true do
    if node:named() and node:child_count() >= 2 then
      local open = node:child(0)
      local close = node:child(node:child_count() - 1)
      local sp, oc = as_char(text, open)
      local ep, cc = as_char(text, close)
      if sp and ep then
        local is_pair = false
        for _, p in ipairs(M.PAIRS) do
          if p[1] == oc and p[2] == cc then is_pair = true end
        end
        if is_pair and sp <= pos_ and pos_ <= ep then
          if ep == pos_ then return sp end
          if traverse_parents or sp == pos_ then return ep end
        end
      end
    end
    do
      local sc, ec = as_close_pair(text, node)
      if sc then
        local r = find_pair_end(text, node:prev_sibling(), sc, ec, false)
        if r then return r end
      end
    end
    do
      local sc, ec = as_open_pair(text, node)
      if sc then
        local r = find_pair_end(text, node:next_sibling(), sc, ec, true)
        if r then return r end
      end
    end
    if traverse_parents then
      local sib = node:next_sibling()
      for _ = 1, MATCH_LIMIT do
        if not sib then break end
        local sc, ec = as_close_pair(text, sib)
        if sc then
          if find_pair_end(text, sib:prev_sibling(), sc, ec, false) then
            local s = srange(sib)
            return s
          end
        end
        sib = sib:next_sibling()
      end
    elseif node:named() then
      break
    end
    local parent = node:parent()
    if not parent then break end
    node = parent
  end
  local function rc(p)
    local row = text:line_of(p)
    return row, p - text:line_start(row)
  end
  local sr, sc = rc(pos)
  local er, ec = rc(math.min(pos + 1, text:len()))
  local n2 = root:named_descendant_for_range(sr, sc, er, ec)
  if not n2 or n2:child_count() ~= 0 then return nil end
  local ns, ne = srange(n2)
  return M.find_matching_bracket_plaintext(text, pos_, ns, ne)
end

function M.find_matching_bracket(buf, text, pos)
  if pos >= text:len() then return nil end
  local ch = text:char(pos)
  if not ch or not M.is_valid_pair(ch) then return nil end
  if not require('hx.syntax').has_tree(buf) then return nil end
  return find_pair(buf, text, pos, false)
end

function M.find_matching_bracket_fuzzy(buf, text, pos)
  return find_pair(buf, text, pos, true)
end

return M
