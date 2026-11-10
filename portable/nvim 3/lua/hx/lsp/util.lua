local api = vim.api
local SL = require('hx.selection')
local Text = require('hx.text')

local M = {}

function M.lsp_pos_to_pos(text, pos, encoding)
  local nlines = text:len_lines()
  if pos.line >= nlines then return nil end
  local line = text:line(pos.line)
  local col
  if encoding == 'utf-8' then
    col = math.min(pos.character, #line)
  else
    local ok, c = pcall(vim.str_byteindex, line, encoding or 'utf-16', pos.character, false)
    col = ok and c or #line
  end
  return text:line_start(pos.line) + math.min(col, #line + (text:has_eol(pos.line) and 1 or 0))
end

function M.lsp_range_to_range(text, range, encoding)
  local rs, re_ = range.start, range['end']
  if rs.line > re_.line or (rs.line == re_.line and rs.character > re_.character) then
    range = { start = re_, ['end'] = re_ }
  end
  local s = M.lsp_pos_to_pos(text, range.start, encoding)
  local e = M.lsp_pos_to_pos(text, range['end'], encoding)
  if not s or not e then return nil end
  return SL.R(s, e)
end

function M.pos_to_lsp_pos(text, pos, encoding)
  local row = text:line_of(pos)
  local col = pos - text:line_start(row)
  local line = text:line(row)
  local character = col
  if encoding ~= 'utf-8' then
    character = vim.str_utfindex(line, encoding or 'utf-16', math.min(col, #line), false)
    if col > #line then character = character + (col - #line) end
  end
  return { line = row, character = character }
end

function M.range_to_lsp_range(text, r, encoding)
  return { start = M.pos_to_lsp_pos(text, r:from(), encoding), ['end'] = M.pos_to_lsp_pos(text, r:to(), encoding) }
end

local function split_keep(s)
  local lines, starts = {}, {}
  local i = 1
  while i <= #s do
    local j = s:find('\n', i, true)
    local e = j or #s
    starts[#starts + 1] = i - 1
    lines[#lines + 1] = s:sub(i, e)
    i = e + 1
  end
  starts[#starts + 1] = #s
  return lines, starts
end

local function chars_of(s)
  local out = {}
  for p, cp in require('hx.util').chars(s) do
    out[#out + 1] = { p, cp }
  end
  return out
end

function M.compare_texts(text, new)
  local old = text:all()
  local changes = {}
  if old == new then return SL.Transaction.change(text, changes) end
  local la, sa = split_keep(old)
  local lb, sb = split_keep(new)
  local ok, hunks = pcall(vim.diff, old, new, { result_type = 'indices', algorithm = 'histogram', indent_heuristic = true })
  if not ok or not hunks then
    return SL.Transaction.change(text, { { 0, #old, new } })
  end
  for _, h in ipairs(hunks) do
    local a0, ac, b0, bc = h[1], h[2], h[3], h[4]
    local as = ac == 0 and a0 or a0 - 1
    local bs = bc == 0 and b0 or b0 - 1
    local abyte_s, abyte_e = sa[as + 1], sa[as + ac + 1]
    local bbyte_s, bbyte_e = sb[bs + 1], sb[bs + bc + 1]
    local before = old:sub(abyte_s + 1, abyte_e)
    local after = new:sub(bbyte_s + 1, bbyte_e)
    if ac == 0 or bc == 0 or bc > 5 * ac or (5 * bc < ac and ac > 10) or ac + bc > 200 then
      changes[#changes + 1] = { abyte_s, abyte_e, after }
    else
      local ca, cb = chars_of(before), chars_of(after)
      local ta, tb = {}, {}
      for i, c in ipairs(ca) do
        ta[i] = tostring(c[2])
      end
      for i, c in ipairs(cb) do
        tb[i] = tostring(c[2])
      end
      local ch = vim.diff(table.concat(ta, '\n') .. '\n', table.concat(tb, '\n') .. '\n',
        { result_type = 'indices', algorithm = 'myers' })
      for _, c in ipairs(ch or {}) do
        local x0, xc, y0, yc = c[1], c[2], c[3], c[4]
        local xs = xc == 0 and x0 or x0 - 1
        local ys = yc == 0 and y0 or y0 - 1
        local function boff(list, idx, total)
          local e = list[idx + 1]
          return e and e[1] or total
        end
        local fs = abyte_s + boff(ca, xs, #before)
        local fe = abyte_s + boff(ca, xs + xc, #before)
        local ts_ = boff(cb, ys, #after)
        local te = boff(cb, ys + yc, #after)
        changes[#changes + 1] = { fs, fe, after:sub(ts_ + 1, te) }
      end
    end
  end
  table.sort(changes, function(x, y)
    return x[1] < y[1]
  end)
  local _ = la
  local _ = lb
  return SL.Transaction.change(text, changes)
end

function M.transaction_from_edits(text, edits, encoding)
  if #edits == 1 then
    local e = edits[1]
    local s = M.lsp_pos_to_pos(text, e.range.start, encoding)
    local en = M.lsp_pos_to_pos(text, e.range['end'], encoding)
    if s == 0 and en == text:len() then return M.compare_texts(text, e.newText) end
  end
  local changes = {}
  for _, e in ipairs(edits) do
    local r = M.lsp_range_to_range(text, e.range, encoding)
    if r then changes[#changes + 1] = { r:from(), r:to(), e.newText } end
  end
  table.sort(changes, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  local out = {}
  local last = -1
  for _, c in ipairs(changes) do
    if c[1] >= last then
      out[#out + 1] = c
      last = c[2]
    end
  end
  return SL.Transaction.change(text, out)
end

local function buf_for_uri(uri)
  local buf = vim.uri_to_bufnr(uri)
  if not api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  vim.bo[buf].buflisted = true
  return buf
end

function M.apply_text_edits(buf, edits, encoding)
  local text = Text.get(buf)
  local tx = M.transaction_from_edits(text, edits, encoding)
  local win
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == buf and api.nvim_win_get_config(w).relative == '' then win = w end
  end
  require('hx.doc').apply(tx, { buf = buf, win = win or require('hx.editor').win() })
end

function M.apply_workspace_edit(edit, encoding)
  if edit.documentChanges then
    for _, ch in ipairs(edit.documentChanges) do
      if ch.kind == 'create' then
        local path = vim.uri_to_fname(ch.uri)
        if not vim.uv.fs_stat(path) or (ch.options and ch.options.overwrite) then
          vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
          local f = io.open(path, 'w')
          if f then f:close() end
        end
      elseif ch.kind == 'rename' then
        vim.uv.fs_rename(vim.uri_to_fname(ch.oldUri), vim.uri_to_fname(ch.newUri))
      elseif ch.kind == 'delete' then
        os.remove(vim.uri_to_fname(ch.uri))
      else
        local buf = buf_for_uri(ch.textDocument.uri)
        M.apply_text_edits(buf, ch.edits, encoding)
      end
    end
  elseif edit.changes then
    for uri, edits in pairs(edit.changes) do
      local buf = buf_for_uri(uri)
      M.apply_text_edits(buf, edits, encoding)
    end
  end
end

function M.jump_to_location(path, range, encoding, action)
  local E = require('hx.editor')
  require('hx.doc').push_jump()
  local buf = E.open(path, action or 'replace')
  if not buf then
    require('hx.state').set_status(('failed to open path: "%s"'):format(path), 'error')
    return
  end
  local text = Text.get(buf)
  local r = M.lsp_range_to_range(text, range, encoding)
  if not r then return end
  E.set_sel(SL.Selection.single(r.head, r.anchor))
  require('hx.cmd.view_util').align_view(E.win(), 'center')
end

local U = require('hx.util')

local function is_word_at(text, pos)
  local cp = text:char(pos)
  return cp ~= nil and U.is_word(cp)
end

function M.find_completion_range(text, replace_mode, cursor)
  local start = cursor
  while start > 0 do
    local p = text:prev_char(start)
    if not is_word_at(text, p) then break end
    start = p
  end
  local stop = cursor
  if replace_mode then
    while stop < text:len() and is_word_at(text, stop) do
      stop = text:next_char(stop)
    end
  end
  return start, stop
end

function M.completion_range(text, edit_offset, replace_mode, cursor)
  if edit_offset then
    local s = cursor + edit_offset[1]
    if s < 0 then return nil end
    local e = cursor + edit_offset[2]
    if e > text:len() then return nil end
    return s, e
  end
  return M.find_completion_range(text, replace_mode, cursor)
end

function M.completion_range_fn(text, sel, edit_offset, replace_mode)
  local ps, pe = M.completion_range(text, edit_offset, replace_mode, sel:prim():cursor(text))
  assert(ps, 'transaction must be valid for primary selection')
  local removed = text:slice(ps, pe)
  return function(r)
    local cursor = r:cursor(text)
    local s, e = M.completion_range(text, edit_offset, replace_mode, cursor)
    if s and text:slice(s, e) == removed then return s, e end
    return M.find_completion_range(text, replace_mode, cursor)
  end
end

function M.generate_transaction_from_completion_edit(text, sel, edit_offset, replace_mode, new_text)
  local range_fn = M.completion_range_fn(text, sel, edit_offset, replace_mode)
  local replacement = new_text ~= '' and new_text or nil
  local tx, nsel = SL.Transaction.change_by_selection_ignore_overlapping(text, sel, range_fn, function()
    return replacement
  end)
  if tx.cs:is_empty() then return tx end
  nsel = SL.map_selection(nsel, tx.cs)
  return tx:with_selection(nsel)
end

return M
