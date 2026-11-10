local api = vim.api
local S = require('hx.state')
local Text = require('hx.text')
local SL = require('hx.selection')
local Sel = SL.Selection

local M = {}

local applying = {}
local attached = {}

local function map_bytes(p, start, old_len, new_len, after)
  if p < start then return p end
  if p >= start + old_len then
    if p == start and old_len == 0 and not after then return p end
    return p + new_len - old_len
  end
  if p == start then return after and start + new_len or start end
  return start + new_len
end

local function map_sel_bytes(sel, start, old_len, new_len)
  local rs = {}
  for i, r in ipairs(sel.ranges) do
    local a, h
    if r.anchor <= r.head then
      a = map_bytes(r.anchor, start, old_len, new_len, r.anchor == r.head)
      h = map_bytes(r.head, start, old_len, new_len, true)
      if r.anchor ~= r.head and r.head > start and r.head <= start + old_len then
        h = start + new_len
      end
    else
      h = map_bytes(r.head, start, old_len, new_len, false)
      a = map_bytes(r.anchor, start, old_len, new_len, false)
    end
    rs[i] = SL.R(a, h)
  end
  return setmetatable({ ranges = rs, primary = sel.primary }, Sel)
end

local function each_view_sel(buf, f)
  for win, v in pairs(S.views) do
    if v.sels[buf] then f(win, v) end
  end
end

function M.attach(buf)
  if attached[buf] then return end
  attached[buf] = true
  api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, b, _, _, _, start_byte, _, _, old_len, _, _, new_len)
      Text.invalidate(b)
      if applying[b] then return end
      each_view_sel(b, function(_, v)
        v.sels[b] = map_sel_bytes(v.sels[b], start_byte, old_len, new_len)
        for _, j in ipairs(v.jumps) do
          if j.buf == b then j.sel = map_sel_bytes(j.sel, start_byte, old_len, new_len) end
        end
      end)
      local d = S.docs and S.docs[b]
      if d and d.active_snippet then
        local new_total = Text.get(b):len()
        local old_total = new_total - new_len + old_len
        local ok, cs = pcall(SL.ChangeSet.from_changes, old_total,
          { { start_byte, start_byte + old_len, string.rep(' ', new_len) } })
        if ok then require('hx.snippet').on_change(b, cs) else d.active_snippet = nil end
      end
      S.dirty = true
    end,
    on_detach = function(_, b)
      attached[b] = nil
    end,
    on_reload = function(_, b)
      Text.invalidate(b)
    end,
  })
end

local function changenr(buf)
  if buf == api.nvim_get_current_buf() then return vim.fn.changenr() end
  local n
  api.nvim_buf_call(buf, function()
    n = vim.fn.changenr()
  end)
  return n
end

local function rc(text, pos)
  local nl = text.nlines
  if pos >= text:len() then
    local last = nl - 1
    return last, #text:line(last), true
  end
  local row = text:line_of(pos)
  return row, pos - text:line_start(row), false
end

local function apply_changes(buf, text, changes)
  local ops = {}
  local total = text:len()
  for i, c in ipairs(changes) do
    local from, to, rep = c[1], c[2], c[3] or ''
    if from == to and rep == '' then goto continue end
    if to >= total and total > 0 then
      if from >= total then
        local r, col = rc(text, total - 1)
        local ins = rep
        if ins:sub(-1) == '\n' then
          ins = '\n' .. ins:sub(1, -2)
        else
          ins = '\n' .. ins
        end
        ops[#ops + 1] = { r, col, r, col, ins }
        goto continue
      end
      local fr, fc = rc(text, from)
      local lr, lc = rc(text, total - 1)
      if fc == 0 and from > 0 then
        local pr, pc = rc(text, from - 1)
        local ins = rep
        if ins ~= '' then
          if ins:sub(-1) == '\n' then
            ins = '\n' .. ins:sub(1, -2)
          else
            ins = '\n' .. ins
          end
        end
        ops[#ops + 1] = { pr, pc, lr, lc, ins }
      else
        local ins = rep
        if ins:sub(-1) == '\n' then ins = ins:sub(1, -2) end
        ops[#ops + 1] = { fr, fc, lr, lc, ins }
      end
      goto continue
    end
    do
      local fr, fc = rc(text, from)
      local tr, tc = rc(text, to)
      ops[#ops + 1] = { fr, fc, tr, tc, rep }
    end
    ::continue::
  end
  applying[buf] = true
  local ok, err = pcall(function()
    for i = #ops, 1, -1 do
      local o = ops[i]
      local lines = vim.split(o[5], '\n', { plain = true })
      api.nvim_buf_set_text(buf, o[1], o[2], o[3], o[4], lines)
    end
  end)
  applying[buf] = nil
  Text.invalidate(buf)
  if not ok then error(err) end
end

function M.apply(tx, opts)
  opts = opts or {}
  local win = opts.win or api.nvim_get_current_win()
  local buf = opts.buf or api.nvim_win_get_buf(win)
  M.attach(buf)
  local cs = tx.cs
  local d = S.doc(buf)
  if not vim.bo[buf].modifiable then
    S.set_status('Cannot modify a read-only buffer', 'error')
    return false
  end
  if cs:is_empty() and not tx.selection then return true end
  local text = Text.get(buf)
  local old_sel = S.get_sel(win, buf)
  local seq_before = changenr(buf)
  if not cs:is_empty() then
    local session = d.session
    if session and session.seq and seq_before == session.seq then
      api.nvim_buf_call(buf, function()
        pcall(vim.cmd, 'silent! undojoin')
      end)
    end
    apply_changes(buf, text, cs.changes)
    if session then
      session.changes[#session.changes + 1] = cs
    end
    local first = cs.changes[1]
    if first then d.last_edit_pos = cs:map_pos(first[1], SL.Assoc.After) end
  end
  local ntext = Text.get(buf)
  each_view_sel(buf, function(w, v)
    if w ~= win then
      v.sels[buf] = SL.map_selection(v.sels[buf], cs):ensure_invariants(ntext)
    end
    for _, j in ipairs(v.jumps) do
      if j.buf == buf then j.sel = SL.map_selection(j.sel, cs) end
    end
  end)
  if d.active_snippet and not cs:is_empty() then require('hx.snippet').on_change(buf, cs) end
  local new_sel
  if tx.selection then
    new_sel = tx.selection
  else
    new_sel = SL.map_selection(old_sel, cs)
  end
  new_sel = new_sel:ensure_invariants(ntext)
  S.set_sel(new_sel, win, buf)
  if tx.selection and d.active_snippet then require('hx.snippet').on_selection(buf, new_sel) end
  if not cs:is_empty() then
    local seq_after = changenr(buf)
    if seq_after ~= seq_before then
      local before = old_sel
      if d.session and d.session.start_sel and not d.session.recorded then
        before = d.session.start_sel
        d.session.recorded = true
      end
      d.before_sel[seq_after] = before
      if d.session then d.session.seq = seq_after end
    end
    d.after_sel[seq_after] = new_sel
    local v = S.view(win)
    if v.last_modified[1] ~= buf then
      v.last_modified = { buf, v.last_modified[1] }
    end
  end
  S.dirty = true
  return true
end

function M.set_selection(sel, win, buf)
  win = win or api.nvim_get_current_win()
  buf = buf or api.nvim_win_get_buf(win)
  local text = Text.get(buf)
  local nsel = sel:ensure_invariants(text)
  S.set_sel(nsel, win, buf)
  local d = S.docs and S.docs[buf]
  if d and d.active_snippet then require('hx.snippet').on_selection(buf, nsel) end
end

function M.begin_session(buf, start_sel)
  local d = S.doc(buf)
  d.session = { changes = {}, start_sel = start_sel, seq = nil }
end

function M.end_session(buf)
  local d = S.doc(buf)
  local s = d.session
  d.session = nil
  return s
end

function M.checkpoint(buf)
  local d = S.doc(buf)
  if d.session then
    d.session.seq = nil
    d.session.recorded = true
    d.session.start_sel = nil
  end
end

local function restore(buf, win, sel)
  if not sel then return end
  local text = Text.get(buf)
  local len = text:len()
  local rs = {}
  for i, r in ipairs(sel.ranges) do
    rs[i] = SL.R(math.min(r.anchor, len), math.min(r.head, len))
  end
  S.set_sel(Sel.new(rs, sel.primary):ensure_invariants(text), win, buf)
end

function M.undo(count)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  local d = S.doc(buf)
  local changed = false
  for _ = 1, count or 1 do
    local seq = vim.fn.changenr()
    local ut = vim.fn.undotree()
    if ut.seq_cur == 0 then break end
    vim.cmd('silent! undo')
    changed = true
    restore(buf, win, d.before_sel[seq])
  end
  if not changed then S.set_status('Already at oldest change', 'info') end
  S.dirty = true
end

function M.redo(count)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  local d = S.doc(buf)
  local changed = false
  for _ = 1, count or 1 do
    local before = vim.fn.changenr()
    vim.cmd('silent! redo')
    local after = vim.fn.changenr()
    if after == before then break end
    changed = true
    restore(buf, win, d.after_sel[after])
  end
  if not changed then S.set_status('Already at newest change', 'info') end
  S.dirty = true
end

function M.earlier(count, unit)
  local buf = api.nvim_get_current_buf()
  local d = S.doc(buf)
  local seq = vim.fn.changenr()
  vim.cmd('silent! earlier ' .. (count or 1) .. (unit or ''))
  local nseq = vim.fn.changenr()
  if nseq == seq then
    S.set_status('Already at oldest change', 'info')
    return
  end
  restore(buf, api.nvim_get_current_win(), d.after_sel[nseq] or d.before_sel[seq])
end

function M.later(count, unit)
  local buf = api.nvim_get_current_buf()
  local d = S.doc(buf)
  local seq = vim.fn.changenr()
  vim.cmd('silent! later ' .. (count or 1) .. (unit or ''))
  local nseq = vim.fn.changenr()
  if nseq == seq then
    S.set_status('Already at newest change', 'info')
    return
  end
  restore(buf, api.nvim_get_current_win(), d.after_sel[nseq])
end

local JUMPLIST_SIZE = 30

function M.push_jump(win, buf)
  win = win or api.nvim_get_current_win()
  buf = buf or api.nvim_win_get_buf(win)
  local v = S.view(win)
  local sel = S.get_sel(win, buf)
  for i = #v.jumps, v.jump_idx + 1, -1 do
    table.remove(v.jumps, i)
  end
  local last = v.jumps[#v.jumps]
  if last and last.buf == buf and last.sel:eq(sel) then
    v.jump_idx = #v.jumps
    return
  end
  for i = #v.jumps, 1, -1 do
    local j = v.jumps[i]
    if j.buf == buf and j.sel:eq(sel) then table.remove(v.jumps, i) end
  end
  v.jumps[#v.jumps + 1] = { buf = buf, sel = sel:copy() }
  if #v.jumps > JUMPLIST_SIZE then table.remove(v.jumps, 1) end
  v.jump_idx = #v.jumps
end

local function goto_jump(win, j)
  if not api.nvim_buf_is_valid(j.buf) then return false end
  if api.nvim_win_get_buf(win) ~= j.buf then require('hx.editor').switch_buffer(j.buf, win) end
  restore(j.buf, win, j.sel)
  return true
end

function M.jump_backward(count)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  local v = S.view(win)
  for _ = 1, count or 1 do
    if v.jump_idx == #v.jumps then
      local sel = S.get_sel(win, buf)
      local last = v.jumps[#v.jumps]
      if not (last and last.buf == buf and last.sel:eq(sel)) then
        v.jumps[#v.jumps + 1] = { buf = buf, sel = sel:copy() }
        v.jump_idx = #v.jumps
      end
    end
    if v.jump_idx <= 1 then break end
    v.jump_idx = v.jump_idx - 1
    goto_jump(win, v.jumps[v.jump_idx])
  end
end

function M.jump_forward(count)
  local win = api.nvim_get_current_win()
  local v = S.view(win)
  for _ = 1, count or 1 do
    if v.jump_idx >= #v.jumps then break end
    v.jump_idx = v.jump_idx + 1
    goto_jump(win, v.jumps[v.jump_idx])
  end
end

return M
