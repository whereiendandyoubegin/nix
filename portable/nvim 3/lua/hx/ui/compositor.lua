local api = vim.api
local M = {}

M.layers = {}
local editor_win = nil

function M.editor_win()
  if editor_win and api.nvim_win_is_valid(editor_win) then return editor_win end
  local cur = api.nvim_get_current_win()
  if api.nvim_win_get_config(cur).relative == '' then
    editor_win = cur
    return cur
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(w).relative == '' then
      editor_win = w
      return w
    end
  end
  return cur
end

function M.set_editor_win(win)
  editor_win = win
end

function M.push(layer)
  if layer.id then M.remove(layer.id) end
  table.insert(M.layers, layer)
  M.refocus()
  if layer.render then layer:render() end
  return layer
end

function M.find(id)
  for _, l in ipairs(M.layers) do
    if l.id == id then return l end
  end
end

function M.remove(id_or_layer)
  for i = #M.layers, 1, -1 do
    local l = M.layers[i]
    if l == id_or_layer or l.id == id_or_layer then
      table.remove(M.layers, i)
      if l.close then pcall(l.close, l) end
    end
  end
  M.refocus()
end

function M.top()
  return M.layers[#M.layers]
end

function M.has_focus_layer()
  for i = #M.layers, 1, -1 do
    if M.layers[i].focus_win then return true end
  end
  return false
end

function M.cursor_shape()
  for i = #M.layers, 1, -1 do
    local l = M.layers[i]
    if l.focus_win then return l.cursor_shape end
  end
end

function M.refocus()
  local target
  for i = #M.layers, 1, -1 do
    local l = M.layers[i]
    if l.focus_win and api.nvim_win_is_valid(l.focus_win) then
      target = l.focus_win
      break
    end
  end
  if not target then target = M.editor_win() end
  if target and api.nvim_win_is_valid(target) and api.nvim_get_current_win() ~= target then
    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    pcall(api.nvim_set_current_win, target)
    vim.o.eventignore = ei
  end
  require('hx.render').update_cursor_shape()
end

function M.handle_key(key)
  for i = #M.layers, 1, -1 do
    local l = M.layers[i]
    if l.handle_key then
      local consumed = l:handle_key(key)
      if consumed then return true end
    end
  end
  return false
end

function M.render_all()
  for _, l in ipairs(M.layers) do
    if l.render then pcall(l.render, l) end
  end
end

function M.close_all()
  for i = #M.layers, 1, -1 do
    M.remove(M.layers[i])
  end
end

return M
