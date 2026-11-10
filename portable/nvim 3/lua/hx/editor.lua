local api = vim.api
local S = require('hx.state')
local Text = require('hx.text')
local SL = require('hx.selection')

local E = {}

function E.win()
  return require('hx.ui.compositor').editor_win()
end

function E.buf()
  return api.nvim_win_get_buf(E.win())
end

function E.text(buf)
  return Text.get(buf or E.buf())
end

function E.sel(win, buf)
  win = win or E.win()
  return S.get_sel(win, buf or api.nvim_win_get_buf(win))
end

function E.set_sel(sel, win, buf)
  win = win or E.win()
  buf = buf or api.nvim_win_get_buf(win)
  require('hx.doc').set_selection(sel, win, buf)
end

function E.is_doc(buf)
  if not api.nvim_buf_is_valid(buf) then return false end
  if not vim.bo[buf].buflisted then return false end
  local bt = vim.bo[buf].buftype
  return bt == '' or bt == 'acwrite' or vim.b[buf].hx_labelled ~= nil
end

function E.documents()
  local out = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    if E.is_doc(b) then out[#out + 1] = b end
  end
  return out
end

function E.display_name(buf)
  local name = api.nvim_buf_get_name(buf)
  local label = vim.b[buf].hx_label
  if label then return label end
  if name == '' then return '[scratch]' end
  return name
end

function E.relative_path(buf)
  local name = api.nvim_buf_get_name(buf)
  if vim.b[buf].hx_label then return vim.b[buf].hx_label end
  if name == '' then return '[scratch]' end
  local rel = vim.fn.fnamemodify(name, ':~:.')
  return rel
end

function E.is_modified(buf)
  return vim.bo[buf].modified
end

local function record_access(win, from_buf, to_buf)
  if from_buf == to_buf then return end
  local v = S.view(win)
  for i = #v.access, 1, -1 do
    if v.access[i] == from_buf then table.remove(v.access, i) end
  end
  table.insert(v.access, from_buf)
end

function E.switch_buffer(buf, win)
  win = win or E.win()
  local cur = api.nvim_win_get_buf(win)
  if cur == buf then return end
  record_access(win, cur, buf)
  local ok, err = pcall(api.nvim_win_set_buf, win, buf)
  if ok then
    local snip = package.loaded['hx.snippet']
    if snip then snip.on_focus_lost(cur) end
  end
  if not ok then
    S.set_status(tostring(err), 'error')
    return
  end
  require('hx.doc').attach(buf)
  S.dirty = true
end

function E.open(path, action)
  action = action or 'replace'
  path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
  local buf = vim.fn.bufadd(path)
  vim.bo[buf].buflisted = true
  if not api.nvim_buf_is_loaded(buf) then
    local ok, err = pcall(vim.fn.bufload, buf)
    if not ok then
      S.set_status(tostring(err), 'error')
      return nil
    end
  end
  if action == 'load' then return buf end
  if action == 'hsplit' then
    E.split('hsplit')
  elseif action == 'vsplit' then
    E.split('vsplit')
  end
  E.switch_buffer(buf, E.win())
  return buf
end

function E.new_scratch()
  local buf = api.nvim_create_buf(true, false)
  vim.bo[buf].buflisted = true
  return buf
end

function E.split(kind, new_doc)
  local win = E.win()
  local buf = api.nvim_win_get_buf(win)
  local sel = S.get_sel(win, buf)
  api.nvim_set_current_win(win)
  if kind == 'vsplit' then
    vim.cmd('rightbelow vsplit')
  else
    vim.cmd('rightbelow split')
  end
  local nwin = api.nvim_get_current_win()
  require('hx.ui.compositor').set_editor_win(nwin)
  if new_doc then
    api.nvim_win_set_buf(nwin, new_doc)
  else
    S.view(nwin).sels[buf] = sel:copy()
  end
  vim.cmd('wincmd =')
  return nwin
end

function E.close_view(win, force)
  win = win or E.win()
  local wins = vim.tbl_filter(function(w)
    return api.nvim_win_get_config(w).relative == ''
  end, api.nvim_tabpage_list_wins(0))
  if #wins <= 1 then
    if not force then
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].modified then
        S.set_status('cannot close the last view while buffers are modified', 'error')
        return false
      end
    end
    vim.cmd('qa' .. (force and '!' or ''))
    return true
  end
  api.nvim_win_close(win, force or false)
  S.views[win] = nil
  local nw = api.nvim_get_current_win()
  if api.nvim_win_get_config(nw).relative ~= '' then
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_config(w).relative == '' then
        nw = w
        break
      end
    end
  end
  require('hx.ui.compositor').set_editor_win(nw)
  vim.cmd('wincmd =')
  return true
end

function E.close_buffer(buf, force)
  if not force and vim.bo[buf].modified then
    return false, ('buffer %s is modified'):format(E.relative_path(buf))
  end
  local docs = E.documents()
  local alt
  for i = #docs, 1, -1 do
    if docs[i] ~= buf then
      alt = docs[i]
      break
    end
  end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative == '' and api.nvim_win_get_buf(w) == buf then
      if alt then
        api.nvim_win_set_buf(w, alt)
      else
        alt = E.new_scratch()
        api.nvim_win_set_buf(w, alt)
      end
    end
  end
  for _, v in pairs(S.views) do
    v.sels[buf] = nil
    for i = #v.access, 1, -1 do
      if v.access[i] == buf then table.remove(v.access, i) end
    end
  end
  S.docs[buf] = nil
  pcall(api.nvim_buf_delete, buf, { force = true })
  return true
end

function E.find_workspace()
  local cwd = vim.fn.getcwd()
  local dir = cwd
  while dir and dir ~= '' do
    for _, marker in ipairs({ '.git', '.svn', '.jj', '.helix' }) do
      if vim.uv.fs_stat(dir .. '/' .. marker) then return dir, false end
    end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then break end
    dir = parent
  end
  return cwd, true
end

function E.language(buf)
  local ft = vim.bo[buf or E.buf()].filetype
  if ft == '' then return 'text' end
  return ft
end

function E.ensure_cursor_in_view()
  require('hx.render').sync_cursor(E.win())
end

return E
