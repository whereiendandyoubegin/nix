local U = require('hx.util')
local S = require('hx.selection')
local Range, Selection, Transaction = S.Range, S.Selection, S.Transaction

local M = {}

M.DEFAULT_COMMENT_TOKEN = '#'

local function block_token(start, end_)
  return { start = start, end_ = end_ }
end
M.block_token = block_token

function M.default_block_token()
  return block_token('/*', '*/')
end

local function tok_start(t)
  return t.start or t[1]
end
local function tok_end(t)
  return t.end_ or t['end'] or t[2]
end

local function starts_with(s, p)
  return s:sub(1, #p) == p
end

local function first_non_ws(s)
  for i, cp in U.chars(s) do
    if not U.rust_whitespace(cp) then return i - 1 end
  end
  return nil
end

local function last_non_ws(s)
  local i = #s
  while i > 0 do
    local j = U.prev_boundary(s, i)
    local cp = U.decode(s, j + 1)
    if not U.rust_whitespace(cp) then return j, i end
    i = j
  end
  return nil
end

function M.get_comment_token(text, tokens, line_num)
  if not tokens then return nil end
  local line = text:line(line_num)
  local start = first_non_ws(line)
  if not start then return nil end
  local rest = line:sub(start + 1)
  local best
  for _, token in ipairs(tokens) do
    if starts_with(rest, token) and (not best or #token >= #best) then
      best = token
    end
  end
  return best
end

function M.find_line_comment(token, text, lines)
  local commented = true
  local to_change = {}
  local min = math.huge
  local margin = 1
  local token_len = #token
  for _, line in ipairs(lines) do
    local l = text:line(line)
    local pos = first_non_ws(l)
    if pos then
      min = math.min(min, pos)
      local fragment = l:sub(pos + 1, pos + token_len)
      if fragment ~= token then commented = false end
      if l:sub(pos + token_len + 1, pos + token_len + 1) ~= ' ' then margin = 0 end
      to_change[#to_change + 1] = line
    end
  end
  return commented, to_change, min, margin
end

function M.toggle_line_comments(text, selection, token)
  token = token or M.DEFAULT_COMMENT_TOKEN
  local comment = token .. ' '
  local lines = {}
  local min_next_line = 0
  local len_lines = text:len_lines()
  for _, r in ipairs(selection.ranges) do
    local s, e = r:line_range(text)
    s = math.max(min_next_line, math.min(s, len_lines))
    e = math.min(e + 1, len_lines)
    for l = s, e - 1 do
      lines[#lines + 1] = l
    end
    min_next_line = e
  end
  local commented, to_change, min, margin = M.find_line_comment(token, text, lines)
  local changes = {}
  for _, line in ipairs(to_change) do
    local pos = text:line_start(line) + min
    if not commented then
      changes[#changes + 1] = { pos, pos, comment }
    else
      changes[#changes + 1] = { pos, pos + #token + margin, nil }
    end
  end
  return Transaction.change(text, changes)
end

function M.find_block_comments(tokens, text, selection)
  local commented = true
  local only_whitespace = true
  local comment_changes = {}
  local default_tokens = tokens[1] or M.default_block_token()
  local def_start, def_end = tok_start(default_tokens), tok_end(default_tokens)
  local start_token, end_token = def_start, def_end

  local sorted = {}
  for i, t in ipairs(tokens) do
    sorted[i] = { start = tok_start(t), end_ = tok_end(t), i = i }
  end
  table.sort(sorted, function(a, b)
    if #a.start == #b.start then
      if #a.end_ ~= #b.end_ then return #a.end_ > #b.end_ end
      return a.i < b.i
    end
    return #a.start > #b.start
  end)

  for _, range in ipairs(selection.ranges) do
    local slice = range:fragment(text)
    local start_pos = first_non_ws(slice)
    local end_pos, end_next = last_non_ws(slice)
    if start_pos and end_pos then
      local line_commented = false
      local after_start, before_end = 0, 0
      local len = end_next - start_pos
      for _, t in ipairs(sorted) do
        local s, e = t.start, t.end_
        after_start = start_pos + #s
        before_end = math.max(0, end_next - #e - 1)
        if len >= #s + #e then
          local start_fragment = slice:sub(start_pos + 1, after_start)
          local end_fragment = slice:sub(end_next - #e + 1, end_next)
          if start_fragment == s and end_fragment == e then
            start_token, end_token = s, e
            line_commented = true
            break
          end
        end
      end
      if not line_commented then
        comment_changes[#comment_changes + 1] = {
          kind = 'Uncommented', range = range, start_pos = start_pos, end_pos = end_pos,
          end_next = end_next, start_token = def_start, end_token = def_end,
        }
        commented = false
      else
        comment_changes[#comment_changes + 1] = {
          kind = 'Commented', range = range, start_pos = start_pos, end_pos = end_pos,
          end_next = end_next,
          start_margin = slice:sub(after_start + 1, after_start + 1) == ' ',
          end_margin = after_start ~= before_end and slice:sub(before_end + 1, before_end + 1) == ' ',
          start_token = start_token, end_token = end_token,
        }
      end
      only_whitespace = false
    else
      comment_changes[#comment_changes + 1] = { kind = 'Whitespace', range = range }
    end
  end
  if only_whitespace then commented = false end
  return commented, comment_changes
end

function M.create_block_comment_transaction(text, selection, commented, comment_changes)
  local changes = {}
  local ranges = {}
  local offs = 0
  for _, ch in ipairs(comment_changes) do
    if commented then
      if ch.kind == 'Commented' then
        local from = ch.range:from()
        changes[#changes + 1] = {
          from + ch.start_pos,
          from + ch.start_pos + #ch.start_token + (ch.start_margin and 1 or 0),
          nil,
        }
        changes[#changes + 1] = {
          from + ch.end_next - #ch.end_token - (ch.end_margin and 1 or 0),
          from + ch.end_next,
          nil,
        }
      end
    else
      if ch.kind == 'Uncommented' then
        local from = ch.range:from()
        changes[#changes + 1] = { from + ch.start_pos, from + ch.start_pos, ch.start_token .. ' ' }
        changes[#changes + 1] = { from + ch.end_next, from + ch.end_next, ' ' .. ch.end_token }
        local offset = #ch.start_token + #ch.end_token + 2
        ranges[#ranges + 1] = Range.new(from + offs, from + offs + ch.end_next + offset)
          :with_direction(ch.range:forward())
        offs = offs + offset
      else
        ranges[#ranges + 1] = Range.new(ch.range:from() + offs, ch.range:to() + offs)
      end
    end
  end
  return Transaction.change(text, changes), ranges
end

function M.toggle_block_comments(text, selection, tokens)
  local commented, comment_changes = M.find_block_comments(tokens, text, selection)
  local tx, ranges = M.create_block_comment_transaction(text, selection, commented, comment_changes)
  if not commented then
    tx = tx:with_selection(Selection.new(ranges, selection.primary))
  end
  return tx
end

function M.split_lines_of_selection(text, selection)
  local ranges = {}
  for _, r in ipairs(selection.ranges) do
    local ls, le = r:line_range(text)
    for row = ls, le do
      ranges[#ranges + 1] = Range.new(text:line_start(row), text:line_next(row))
    end
    if text:has_eol(le) then
      local p = text:line_next(le)
      ranges[#ranges + 1] = Range.new(p, p)
    end
  end
  return Selection.new(ranges, 1)
end

function M.resolve_line_token(text, tokens, cursor_line)
  if not tokens then return nil end
  return M.get_comment_token(text, tokens, cursor_line) or tokens[1]
end

function M.toggle_comments(text, selection, line_token, block_tokens)
  if line_token and not block_tokens then
    return M.toggle_line_comments(text, selection, line_token)
  end
  local split_lines = M.split_lines_of_selection(text, selection)
  local tokens = block_tokens or { M.default_block_token() }
  local line_commented, line_changes = M.find_block_comments(tokens, text, split_lines)
  if line_commented then
    return (M.create_block_comment_transaction(text, split_lines, line_commented, line_changes))
  end
  local block_commented, changes = M.find_block_comments(tokens, text, selection)
  if block_commented then
    return (M.create_block_comment_transaction(text, selection, block_commented, changes))
  end
  if not line_token and block_tokens then
    return (M.create_block_comment_transaction(text, split_lines, line_commented, line_changes))
  end
  return M.toggle_line_comments(text, selection, line_token)
end

function M.toggle_line_comments_cmd(text, selection, line_token, block_tokens)
  if not line_token and block_tokens then
    return M.toggle_block_comments(text, M.split_lines_of_selection(text, selection), block_tokens)
  end
  return M.toggle_line_comments(text, selection, line_token)
end

function M.toggle_block_comments_cmd(text, selection, line_token, block_tokens)
  if line_token and not block_tokens then
    return M.toggle_line_comments(text, selection, line_token)
  end
  return M.toggle_block_comments(text, selection, block_tokens or { M.default_block_token() })
end

return M
