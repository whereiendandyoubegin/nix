local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')
local U = require('hx.util')

local M = {}

local function fuzzy_match(pattern, items, path)
  local out = {}
  local ok, res = pcall(require('hx.fuzzy').filter, pattern, items, path)
  if ok then out = res end
  return out
end

local function simple(names, input, path)
  local out = {}
  for _, n in ipairs(fuzzy_match(input, names, path)) do
    out[#out + 1] = { 0, n }
  end
  return out
end

function M.none()
  return {}
end

function M.buffer(input)
  local E = require('hx.editor')
  local names = {}
  for _, b in ipairs(E.documents()) do
    local n = api.nvim_buf_get_name(b)
    names[#names + 1] = n ~= '' and vim.fn.fnamemodify(n, ':.') or '[scratch]'
  end
  return simple(names, input, true)
end

function M.theme(input)
  local names = { 'base16_default', 'default', 'spacemacs' }
  return simple(names, input, false)
end

local setting_keys
local function get_keys(value, vec, scope)
  if type(value) ~= 'table' or vim.islist(value) then return end
  local keys = vim.tbl_keys(value)
  table.sort(keys)
  for _, k in ipairs(keys) do
    if not tostring(k):match('^_') then
      local key = scope and (scope .. '.' .. k) or k
      local v = value[k]
      get_keys(v, vec, key)
      if not (type(v) == 'table' and not vim.islist(v) and next(v) ~= nil) then vec[#vec + 1] = key end
    end
  end
end

function M.setting(input)
  if not setting_keys then
    setting_keys = {}
    get_keys(require('hx').default_editor_config and require('hx').default_editor_config() or S.config.editor,
      setting_keys, nil)
  end
  return simple(setting_keys, input, false)
end

function M.language(input)
  local L = require('hx.languages')
  local ids = {}
  for id in pairs(L.language or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  ids[#ids + 1] = 'text'
  return simple(ids, input, false)
end

function M.active_language_servers(input)
  local names = {}
  for _, c in ipairs(require('hx.lsp').buf_clients(require('hx.editor').buf())) do
    names[#names + 1] = c.name
  end
  return simple(names, input, false)
end

function M.configured_language_servers(input)
  return simple(require('hx.languages').servers_for(require('hx.editor').buf()), input, false)
end

function M.lsp_workspace_command(input)
  local cmds = {}
  for _, c in ipairs(require('hx.lsp').with_feature(require('hx.editor').buf(), 'workspace_command')) do
    local p = c.server_capabilities.executeCommandProvider
    for _, name in ipairs((type(p) == 'table' and p.commands) or {}) do
      cmds[#cmds + 1] = name
    end
  end
  return simple(cmds, input, false)
end

function M.register(input)
  local names = {}
  for _, e in ipairs(require('hx.registers').preview()) do
    local ch = e[1]
    if ch ~= '%' and ch ~= '#' and ch ~= '.' then names[#names + 1] = ch end
  end
  return simple(names, input, false)
end

local programs
function M.program(input)
  if not programs then
    local set = {}
    for dir in (os.getenv('PATH') or ''):gmatch('[^:]+') do
      local fs = vim.uv.fs_scandir(dir)
      if fs then
        while true do
          local name, typ = vim.uv.fs_scandir_next(fs)
          if not name then break end
          if typ == 'file' or typ == 'link' then set[name] = true end
        end
      end
    end
    programs = vim.tbl_keys(set)
    table.sort(programs)
  end
  return simple(programs, input, false)
end

local dir_cache = {}
local function list_dir(dir, git_ignore)
  local key = dir .. (git_ignore and '\0g' or '\0n')
  local c = dir_cache[key]
  local now = vim.uv.now()
  if c and now - c.at < 2000 then return c.items end
  local items = {}
  local ok, res = pcall(require('hx.walk').dir, dir,
    require('hx.walk').opts_from({ hidden = false, ['git-ignore'] = git_ignore }))
  if ok then
    for _, it in ipairs(res) do
      items[#items + 1] = { path = it[1], is_dir = it[2] }
    end
  end
  dir_cache[key] = { at = now, items = items }
  return items
end

local function filename_impl(input, git_ignore, filter)
  local is_tilde = input == '~'
  local path = input
  if path == '~' or path:sub(1, 2) == '~/' then path = (vim.uv.os_homedir() or '') .. path:sub(2) end
  local dir, file_name
  if input:sub(-1) == '/' then
    dir = path
  else
    local is_period = (input:sub(-2) == '/.' and #input > 2) or input == '.'
    if is_period then
      file_name = '.'
      dir = path
    else
      file_name = path:match('([^/]+)$')
      if file_name == '..' then file_name = nil end
      local parent = path:match('^(.*)/[^/]*$')
      if parent == '' and path:sub(1, 1) == '/' then parent = '/' end
      if not parent or parent == '' then parent = vim.fn.getcwd() end
      dir = parent
    end
  end
  local dir_style = T.get('ui.text.directory')
  local link_style = T.get('ui.text.symlink')
  local abs_dir = vim.fn.fnamemodify(dir, ':p')
  local files = {}
  for _, it in ipairs(list_dir(dir, git_ignore)) do
    local m = filter(it)
    if m ~= 'reject' then
      local rel
      if is_tilde then
        rel = it.path
      else
        local full = vim.fn.fnamemodify(it.path, ':p'):gsub('/$', '')
        local base = abs_dir:gsub('/$', '')
        if full:sub(1, #base + 1) == base .. '/' then
          rel = full:sub(#base + 2)
        else
          rel = it.path
        end
      end
      if m == 'incomplete' then rel = rel .. '/' end
      if rel ~= '' and rel ~= '/' then
        local lst = vim.uv.fs_lstat(it.path)
        local style
        if lst and lst.type == 'link' then
          style = link_style
        elseif it.is_dir then
          style = dir_style
        end
        files[#files + 1] = { text = rel, style = style }
      end
    end
  end
  local out = {}
  if file_name then
    local start = math.max(0, #input - #file_name)
    local texts, by_text = {}, {}
    for _, f in ipairs(files) do
      texts[#texts + 1] = f.text
      by_text[f.text] = f
    end
    for _, t in ipairs(fuzzy_match(file_name, texts, true)) do
      out[#out + 1] = { start, t, style = by_text[t].style }
    end
  else
    table.sort(files, function(a, b)
      return a.text < b.text
    end)
    for _, f in ipairs(files) do
      out[#out + 1] = { #input, f.text, style = f.style }
    end
  end
  return out
end

function M.filename(input)
  return filename_impl(input, true, function(it)
    return it.is_dir and 'incomplete' or 'accept'
  end)
end

function M.directory(input)
  return filename_impl(input, true, function(it)
    return it.is_dir and 'accept' or 'reject'
  end)
end

function M.repeating_filenames(input)
  local Ty = require('hx.typed')
  local t = Ty.tokenizer(input)
  local last
  while true do
    local tok = t:next()
    if not tok then break end
    last = tok
  end
  if not last then return M.filename(input) end
  local offset = last.start
  local res = M.filename(input:sub(offset + 1))
  for _, c in ipairs(res) do
    c[1] = c[1] + offset
  end
  return res
end

function M.shell(input)
  local Ty = require('hx.typed')
  local command, args, complete_command = Ty.split(input)
  if complete_command then return M.program(command) end
  local res = M.repeating_filenames(args)
  for _, c in ipairs(res) do
    c[1] = c[1] + #command + 1
  end
  return res
end

local NAMED = {
  ['SHELL_COMPLETER'] = { positional = { 'program', 'repeating_filenames' } },
}

local function parse_completer(spec)
  if NAMED[spec] then return NAMED[spec] end
  local all = spec and spec:match('CommandCompleter::all%(completers::([%w_]+)%)')
  if all then return { positional = {}, var = all } end
  local pos = spec and spec:match('CommandCompleter::positional%(&%[(.-)%]%)')
  if pos then
    local list = {}
    for name in pos:gmatch('completers::([%w_]+)') do
      list[#list + 1] = name
    end
    return { positional = list, var = 'none' }
  end
  return { positional = {}, var = 'none' }
end

local function for_argument_number(c, n)
  return c.positional[n + 1] or c.var or 'none'
end

local function quote_completion(tok, comp, offset)
  local start, text, style = comp[1], comp[2], comp.style
  if tok.kind == 'unquoted' and text:find('[ \t%%]') then
    local prefix = tok.content:sub(1, start):gsub("'", "''")
    return { offset + tok.start, "'" .. prefix .. text:gsub("'", "''") .. "'", style = style }
  elseif tok.kind == 'quoted' then
    local q = tok.quote or "'"
    local esc = q .. q
    return { start + offset + tok.start, (text:gsub(vim.pesc(q), esc)), style = style }
  elseif tok.kind == 'expand' then
    return { start + offset, (text:gsub('"', '""')), style = style }
  end
  return { start + offset + tok.start, text, style = style }
end

local VARIABLES = {
  'cursor_line', 'cursor_column', 'buffer_name', 'line_ending', 'current_working_directory',
  'workspace_directory', 'language', 'selection', 'selection_line_start', 'selection_line_end',
}
local EXPANSION_KINDS = { 'sh', 'u', 'reg' }

local function complete_list(content, names, offset)
  local out = {}
  for _, n in ipairs(fuzzy_match(content, names, false)) do
    out[#out + 1] = { offset, n }
  end
  return out
end

local complete_expand
complete_expand = function(tok, completer, offset)
  local Ty = require('hx.typed')
  local content = tok.content
  local start = 0
  while true do
    local idx = content:find('%', start + 1, true)
    if not idx then break end
    idx = idx - 1
    if content:sub(idx + 2, idx + 2) == '%' then
      start = idx + 2
    else
      local t = Ty.tokenizer(content:sub(idx + 1))
      local ptok = t:parse_percent()
      start = idx + t.pos - 1
      if ptok and not ptok.terminated then
        local local_offset = offset + idx + (ptok.start or 0)
        if ptok.kind == 'var' then
          return complete_list(ptok.content, VARIABLES, local_offset)
        elseif ptok.kind == 'sh' then
          return complete_expand(ptok, nil, local_offset)
        elseif ptok.kind == 'kind' then
          return complete_list(ptok.content, EXPANSION_KINDS, local_offset)
        end
      end
    end
  end
  if completer and start == 0 then
    local out = {}
    for _, c in ipairs(M[completer](content)) do
      out[#out + 1] = quote_completion(tok, c, offset)
    end
    return out
  end
  return {}
end

local function complete_command_args(cmd, input, offset)
  local Ty = require('hx.typed')
  local sig = Ty.parse_signature(cmd)
  local completer = parse_completer(cmd.completer)
  local t = Ty.tokenizer(input)
  local positionals = 0
  local final
  local is_last_token = true
  local only_positionals = false
  local in_flag = false
  while true do
    local tok
    if sig.raw_after and positionals >= sig.raw_after then
      tok = t:rest()
      if tok then tok.kind = 'expand' end
      only_positionals = true
    else
      tok = t:next()
    end
    if not tok then break end
    final = tok
    in_flag = false
    if not only_positionals and tok.kind == 'unquoted' and tok.content:sub(1, 1) == '-' and #sig.flags > 0 then
      if tok.content == '--' then
        only_positionals = true
      else
        in_flag = true
      end
    else
      positionals = positionals + 1
    end
    if t.pos - 1 >= #input then is_last_token = false end
  end
  local tok
  if is_last_token then
    tok = { kind = 'unquoted', content = '', start = #input, terminated = false }
    positionals = positionals + 1
    in_flag = false
  else
    tok = final
  end
  if tok.terminated then return {} end
  if tok.kind == 'unquoted' or tok.kind == 'quoted' then
    if in_flag then
      local names = {}
      for _, f in ipairs(sig.flags) do
        names[#names + 1] = f.name
      end
      local out = {}
      for _, n in ipairs(fuzzy_match(tok.content:gsub('^%-+', ''), names, false)) do
        out[#out + 1] = { offset + tok.start, '--' .. n }
      end
      return out
    end
    local name = for_argument_number(completer, positionals - 1)
    local fn = M[name] or M.none
    local out = {}
    for _, c in ipairs(fn(tok.content)) do
      out[#out + 1] = quote_completion(tok, c, offset)
    end
    return out
  elseif tok.kind == 'expand' or tok.kind == 'sh' then
    local name = (not in_flag) and for_argument_number(completer, positionals - 1) or nil
    return complete_expand(tok, name ~= 'none' and name or nil, offset + tok.start)
  elseif tok.kind == 'var' then
    return complete_list(tok.content, VARIABLES, offset + tok.start)
  elseif tok.kind == 'u' then
    return {}
  elseif tok.kind == 'reg' then
    local names = {}
    for _, e in ipairs(require('hx.registers').preview()) do
      names[#names + 1] = e[1]
    end
    return complete_list(tok.content, names, offset + tok.start)
  elseif tok.kind == 'kind' then
    return complete_list(tok.content, EXPANSION_KINDS, offset + tok.start)
  end
  return {}
end
M.complete_command_args = complete_command_args

function M.command_line(line)
  local Ty = require('hx.typed')
  local command, rest, complete_cmd = Ty.split(line)
  if complete_cmd then
    local names = {}
    for _, c in ipairs(Ty.list) do
      names[#names + 1] = c.name
    end
    local out = {}
    for _, n in ipairs(fuzzy_match(line, names, false)) do
      out[#out + 1] = { 0, n }
    end
    return out
  end
  local cmd = Ty.lookup(command)
  if not cmd then return {} end
  return complete_command_args(cmd, rest, #command + 1)
end

return M
