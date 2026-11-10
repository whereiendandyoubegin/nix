local api = vim.api
local S = require('hx.state')
local LB = require('hx.plugins.labelled')

local M = {}

M.FILE_TREE = 'github.com/mattwparas/helix-config/file-tree'
local side = 'left'

local file_tree = {}
local directories = {}
local ignore = { target = true, ['.git'] = true }
local extension_map = { rs = '\u{e68b} ', scm = '\u{f0627} ' }
local DEFAULT_SYMBOL = '\u{f15b} '

local function E()
  return require('hx.editor')
end

local function stat(p)
  return vim.uv.fs_stat(p)
end
local function is_dir(p)
  local st = p and stat(p)
  return st ~= nil and st.type == 'directory'
end
local function is_file(p)
  local st = p and stat(p)
  return st ~= nil and st.type == 'file'
end

local function file_name(p)
  return p:match('([^/]+)/*$') or p
end

local function format_dir(path)
  if directories[path] ~= nil then return directories[path] and '>  ' or 'v  ' end
  return '>  '
end

local function path_symbol(path)
  local ext = path:match('%.([^./]+)$')
  if ext then return extension_map[ext] or DEFAULT_SYMBOL end
  return DEFAULT_SYMBOL
end

local function read_dir(path)
  local out = {}
  local fs = vim.uv.fs_scandir(path)
  if not fs then return out end
  while true do
    local name = vim.uv.fs_scandir_next(fs)
    if not name then break end
    out[#out + 1] = (path:sub(-1) == '/' and path or (path .. '/')) .. name
  end
  table.sort(out)
  return out
end

local function tree(root)
  local lines, paths = {}, {}
  local function rec(path, padding)
    local name = file_name(path)
    if ignore[name] then return end
    lines[#lines + 1] = padding .. (is_dir(path) and format_dir(path) or path_symbol(path)) .. name
    if is_file(path) then
      paths[#paths + 1] = path
    elseif is_dir(path) then
      paths[#paths + 1] = path
      if directories[path] == nil then
        directories[path] = true
      elseif directories[path] == false then
        for _, child in ipairs(read_dir(path)) do
          rec(child, padding .. '    ')
        end
      end
    else
      paths[#paths + 1] = false
    end
  end
  rec(root, '')
  return lines, paths
end

local function current_line()
  local text = E().text()
  return E().sel():prim():cursor_line(text)
end

local function write_tree(keep_selection)
  local buf = E().buf()
  local win = E().win()
  local old_sel = E().sel()
  local lines, paths = tree(E().find_workspace())
  file_tree = paths
  local Text = require('hx.text')
  local SL = require('hx.selection')
  local text = Text.get(buf)
  local content = table.concat(lines, '\n') .. '\n'
  local tx = SL.Transaction.change(text, { { 0, text:len(), content } })
  local ntext_len = #content
  tx = tx:with_selection(keep_selection and old_sel or SL.Selection.point(ntext_len))
  require('hx.doc').apply(tx, { win = win, buf = buf })
end

function M.set_side(s)
  if s ~= 'left' and s ~= 'right' then error("file-tree-set-side! requires either the 'left or 'right") end
  side = s
end

function M.create_file_tree()
  local doc = LB.maybe_fetch_doc_id(M.FILE_TREE)
  if not doc then LB.make_new(M.FILE_TREE, side) end
  if not LB.doc_exists(LB.fetch_doc_id(M.FILE_TREE)) then LB.make_new(M.FILE_TREE, side) end
  LB.temporarily_switch_focus(function()
    LB.open(M.FILE_TREE)
    if side == 'left' then
      vim.cmd('wincmd H')
    elseif side == 'right' then
      vim.cmd('wincmd L')
    end
    vim.cmd('wincmd H')
    write_tree(false)
  end)
end

local function update_file_tree()
  local last_mode = S.mode
  write_tree(true)
  S.set_mode(last_mode)
end

local function refresh_file_tree()
  LB.temporarily_switch_focus(function()
    LB.open(M.FILE_TREE)
    update_file_tree()
  end)
end

local function open_path(p)
  if not p then error('expected a path', 0) end
  require('hx.typed').execute_line("open '" .. p .. "'")
end

function M.open_file_from_picker()
  if not LB.currently_in(M.FILE_TREE) then return end
  open_path(file_tree[current_line() + 1])
end

function M.fold_directory()
  if not LB.currently_in(M.FILE_TREE) then return end
  local d = file_tree[current_line() + 1]
  if d and is_dir(d) then
    directories[d] = not directories[d]
    update_file_tree()
  end
end

local function helix_prompt(prompt, cb)
  require('hx.ui.prompt').open({
    prompt = prompt,
    callback = function(input, event)
      if event == 'validate' then cb(input) end
    end,
  })
end

function M.create_file()
  if not LB.currently_in(M.FILE_TREE) then return end
  local cur = file_tree[current_line() + 1] or ''
  local prompt
  if is_dir(cur) then
    prompt = 'New file: ' .. cur .. '/'
  else
    prompt = 'New file: ' .. cur:sub(1, #cur - #file_name(cur))
  end
  helix_prompt(prompt, function(result)
    local fname = prompt:gsub('^New file: ', '') .. result
    LB.temporarily_switch_focus(function()
      local w = E().split('vsplit', E().new_scratch())
      local buf = E().open(fname, 'replace')
      if buf then
        vim.fn.mkdir(vim.fn.fnamemodify(fname, ':h'), 'p')
        if not vim.uv.fs_stat(fname) then
          local f = io.open(fname, 'w')
          if f then f:close() end
        end
        vim.bo[buf].modified = false
      end
      E().close_view(w)
    end)
    vim.schedule(refresh_file_tree)
  end)
end

function M.create_directory()
  if not LB.currently_in(M.FILE_TREE) then return end
  local cur = file_tree[current_line() + 1] or ''
  local prompt
  if is_dir(cur) then
    prompt = 'New directory: ' .. cur .. '/'
  else
    prompt = 'New directory: ' .. cur:sub(1, #cur - #file_name(cur))
  end
  helix_prompt(prompt, function(result)
    local dname = prompt:gsub('^New directory: ', '') .. result
    vim.fn.mkdir(dname, 'p')
    vim.schedule(refresh_file_tree)
  end)
end

function M.fold_all()
  if not LB.currently_in(M.FILE_TREE) then return end
  for k in pairs(directories) do
    directories[k] = true
  end
  require('hx.input').exec_cmd('goto_file_start', require('hx.input').new_ctx())
  refresh_file_tree()
end

function M.unfold_all_one_level()
  if not LB.currently_in(M.FILE_TREE) then return end
  for k in pairs(directories) do
    directories[k] = false
  end
  refresh_file_tree()
end

function M.reveal(path)
  if not path or path == '' then error('expected a path', 0) end
  path = vim.fn.fnamemodify(path, ':p')
  local root = E().find_workspace()
  local dir = vim.fn.fnamemodify(path, ':h')
  while dir and #dir >= #root do
    directories[dir] = false
    if dir == root then break end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then break end
    dir = parent
  end
  directories[root] = false
  M.create_file_tree()
  LB.open(M.FILE_TREE)
  for i, p in ipairs(file_tree) do
    if p == path then
      local Text = require('hx.text')
      local text = Text.get(E().buf())
      local s = text:line_start(i - 1)
      E().set_sel(require('hx.selection').Selection.single(s, text:next_grapheme(s)))
      require('hx.cmd.view_util').align_view(E().win(), 'center')
      break
    end
  end
end

function M.setup()
  local reg = require('hx.typed').register_plugin
  local SIG0 = 'Signature { positionals: (0, Some(0)), ..Signature::DEFAULT }'
  reg('open-file-from-picker', function(_, ev)
    if ev == 'validate' then M.open_file_from_picker() end
  end, 'Open the currently selected line', SIG0)
  reg('create-file', function(_, ev)
    if ev == 'validate' then M.create_file() end
  end, 'Create a file under wherever we are', SIG0)
  reg('fold-directory', function(_, ev)
    if ev == 'validate' then M.fold_directory() end
  end, "Fold the directory that we're currently hovering over", SIG0)
  reg('create-directory', function(_, ev)
    if ev == 'validate' then M.create_directory() end
  end, 'Create a new directory', SIG0)
  reg('fold-all', function(_, ev)
    if ev == 'validate' then M.fold_all() end
  end, 'Fold all of the directories', SIG0)
  reg('unfold-all-one-level', function(_, ev)
    if ev == 'validate' then M.unfold_all_one_level() end
  end, 'Unfold all of the currently open directories one level.', SIG0)
  reg('file-tree-reveal', function(args, ev)
    if ev == 'validate' then M.reveal(args[1]) end
  end, 'Open the file tree and reveal the given path in it',
    'Signature { positionals: (1, Some(1)), ..Signature::DEFAULT }')
end

return M
