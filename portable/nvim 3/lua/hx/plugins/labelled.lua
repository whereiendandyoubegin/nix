local api = vim.api
local S = require('hx.state')

local M = {}

local buffers = {}

local function E()
  return require('hx.editor')
end

local function focus(win)
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
    require('hx.ui.compositor').set_editor_win(win)
  end
end

local function find_view(buf)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(w).relative == '' and api.nvim_win_get_buf(w) == buf then return w end
  end
end

function M.maybe_fetch_doc_id(label)
  return buffers[label]
end

function M.fetch_doc_id(label)
  local b = buffers[label]
  if not b then error('label not found: ' .. label) end
  return b
end

function M.doc_exists(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

function M.make_new(label, side)
  local last_win = E().win()
  local last_mode = S.mode
  local buf = E().new_scratch()
  local win = E().split('vsplit', buf)
  vim.b[buf].hx_label = '[' .. label .. ']'
  vim.b[buf].hx_labelled = label
  if side == 'left' then
    api.nvim_win_call(win, function()
      vim.cmd('wincmd H')
    end)
  elseif side == 'right' then
    api.nvim_win_call(win, function()
      vim.cmd('wincmd L')
    end)
  end
  buffers[label] = buf
  focus(last_win)
  S.set_mode(last_mode)
  return buf
end

function M.temporarily_switch_focus(thunk)
  local last_win = E().win()
  local last_mode = S.mode
  local ok, err = pcall(thunk)
  focus(last_win)
  S.set_mode(last_mode)
  if not ok then error(err, 0) end
end

function M.open_or_switch_focus(buf)
  local w = find_view(buf)
  if w then
    focus(w)
  else
    E().switch_buffer(buf)
  end
end

function M.open(label)
  M.open_or_switch_focus(buffers[label])
end

function M.currently_in(label)
  local b = buffers[label]
  return b ~= nil and b == E().buf()
end

return M
