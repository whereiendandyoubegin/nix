local M = {}
local api = vim.api

M.mode = 'normal'
M.status = nil
M.config = nil

M.views = {}
M.docs = {}

function M.view(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local v = M.views[win]
  if not v then
    v = { sels = {}, jumps = {}, jump_idx = 0, access = {}, last_modified = {} }
    M.views[win] = v
  end
  return v
end

function M.doc(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local d = M.docs[buf]
  if not d then
    d = {
      restore_cursor = false,
      before_sel = {},
      after_sel = {},
      session = nil,
      last_edit_pos = nil,
      diag_cache = nil,
    }
    M.docs[buf] = d
  end
  return d
end

function M.get_sel(win, buf)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  buf = (buf == nil or buf == 0) and api.nvim_win_get_buf(win) or buf
  local v = M.view(win)
  local s = v.sels[buf]
  if not s then
    local Sel = require('hx.selection').Selection
    local Text = require('hx.text')
    local t = Text.get(buf)
    local ok, cur = pcall(api.nvim_win_get_cursor, win)
    local pos = 0
    if ok then
      local row = math.min(cur[1] - 1, t:len_lines() - 1)
      pos = math.min(t:line_start(row) + cur[2], t:len())
    end
    s = Sel.single(pos, t:next_grapheme(pos))
    v.sels[buf] = s
  end
  return s
end

function M.set_sel(sel, win, buf)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  buf = (buf == nil or buf == 0) and api.nvim_win_get_buf(win) or buf
  local v = M.view(win)
  v.sels[buf] = sel
  M.dirty = true
end

function M.set_status(msg, severity)
  M.status = { msg = msg, severity = severity or 'info', time = vim.uv.now() }
  M.dirty = true
  vim.schedule(function()
    pcall(vim.cmd.redrawstatus)
    require('hx.ui.cmdline').render()
  end)
end

function M.clear_status()
  M.status = nil
end

function M.set_mode(m)
  if M.mode == m then return end
  M.mode = m
  M.dirty = true
  require('hx.render').update_cursor_shape()
  vim.schedule(function()
    pcall(vim.cmd.redrawstatus)
  end)
end

return M
