local api = vim.api
local S = require('hx.state')
local U = require('hx.util')
local E = require('hx.editor')
local D = require('hx.doc')
local SL = require('hx.selection')
local Regs = require('hx.registers')

local M = {}

local Tok = {}
Tok.__index = Tok

local function tokenizer(input)
  return setmetatable({ s = input, pos = 1 }, Tok)
end

function Tok:skip_blanks()
  while true do
    local b = self.s:byte(self.pos)
    if b == 32 or b == 9 then
      self.pos = self.pos + 1
    else
      break
    end
  end
end

function Tok:rest()
  self:skip_blanks()
  if self.pos > #self.s then return nil end
  local start = self.pos
  self.pos = #self.s + 1
  return { kind = 'expand', content = self.s:sub(start), start = start - 1, terminated = false }
end

function Tok:parse_quoted(q)
  self.pos = self.pos + 1
  local out = {}
  while true do
    local i = self.s:find(q, self.pos, true)
    if not i then
      out[#out + 1] = self.s:sub(self.pos)
      self.pos = #self.s + 1
      return table.concat(out), false
    end
    if self.s:sub(i + 1, i + 1) == q then
      out[#out + 1] = self.s:sub(self.pos, i)
      self.pos = i + 2
    else
      out[#out + 1] = self.s:sub(self.pos, i - 1)
      self.pos = i + 1
      return table.concat(out), true
    end
  end
end

function Tok:parse_balanced(open, close)
  self.pos = self.pos + 1
  local start = self.pos
  local level = 1
  while self.pos <= #self.s do
    local c = self.s:sub(self.pos, self.pos)
    self.pos = self.pos + 1
    if c == open then
      level = level + 1
    elseif c == close then
      level = level - 1
      if level == 0 then return self.s:sub(start, self.pos - 2), true end
    end
  end
  return self.s:sub(start), false
end

local EXPANSION_KINDS = { [''] = 'var', sh = 'sh', u = 'u', reg = 'reg' }

function Tok:parse_percent()
  self.pos = self.pos + 1
  local ks = self.pos
  while true do
    local b = self.s:byte(self.pos)
    if b and b >= 97 and b <= 122 then
      self.pos = self.pos + 1
    else
      break
    end
  end
  local kind = self.s:sub(ks, self.pos - 1)
  local c = self.s:sub(self.pos, self.pos)
  local pairs_ = { ['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>', ["'"] = "'", ['"'] = '"', ['|'] = '|' }
  local close = pairs_[c]
  if not close then
    return { kind = 'kind', content = kind, start = ks - 1, terminated = false,
      error = kind == '' and "'%' was not properly escaped. Please use '%%'"
        or ("missing a string delimiter after '%" .. kind .. "'") }
  end
  local start = self.pos
  local content, term
  if c == close then
    content, term = self:parse_quoted(c)
  else
    content, term = self:parse_balanced(c, close)
  end
  local k = EXPANSION_KINDS[kind]
  return { kind = k or 'expand', content = content, start = start, terminated = term,
    error = (not k) and ("unknown expansion '" .. kind .. "'") or nil }
end

function Tok:next()
  self:skip_blanks()
  if self.pos > #self.s then return nil end
  local c = self.s:sub(self.pos, self.pos)
  if c == '"' or c == "'" or c == '`' then
    local start = self.pos
    local content, term = self:parse_quoted(c)
    return { kind = c == '"' and 'expand' or 'quoted', content = content, start = start, terminated = term, quote = c }
  end
  if c == '%' then return self:parse_percent() end
  local start = self.pos
  if c == '\\' and self.s:sub(self.pos + 1, self.pos + 1):match('["\'`%%]') then self.pos = self.pos + 1 end
  local out = {}
  local seg = self.pos
  while self.pos <= #self.s do
    local b = self.s:byte(self.pos)
    if b == 32 or b == 9 then
      if self.s:byte(self.pos - 1) == 92 then
        out[#out + 1] = self.s:sub(seg, self.pos - 2) .. string.char(b)
        seg = self.pos + 1
      else
        break
      end
    end
    self.pos = self.pos + 1
  end
  local stop = self.pos - 1
  if self.s:byte(stop) == 92 and self.pos > #self.s then stop = stop - 1 end
  out[#out + 1] = self.s:sub(seg, stop)
  return { kind = 'unquoted', content = table.concat(out), start = start - 1, terminated = false }
end
M.tokenizer = tokenizer

function M.split(line)
  local cmd, rest = line:match('^([^ \t]*)[ \t](.*)$')
  if not cmd then cmd, rest = line, '' end
  local complete_command = cmd == '' or (U.trim(rest) == '' and not line:match('[ \t]$'))
  return cmd, rest, complete_command
end

local function expand_variable(name)
  local text = E.text()
  local sel = E.sel()
  local r = sel:prim()
  if name == 'cursor_line' then return tostring(r:cursor_line(text) + 1) end
  if name == 'cursor_column' then
    local pos = r:cursor(text)
    local row = text:line_of(pos)
    return tostring(text:char_count(text:line_start(row), pos) + 1)
  end
  if name == 'buffer_name' then
    local n = api.nvim_buf_get_name(E.buf())
    if n == '' then return '[scratch]' end
    return vim.fn.fnamemodify(n, ':.')
  end
  if name == 'file_path_absolute' then
    local n = api.nvim_buf_get_name(E.buf())
    return n ~= '' and n or vim.fn.getcwd()
  end
  if name == 'line_ending' then return vim.bo[E.buf()].fileformat == 'dos' and '\r\n' or '\n' end
  if name == 'current_working_directory' then return vim.fn.getcwd() end
  if name == 'workspace_directory' then return (E.find_workspace()) end
  if name == 'language' then return E.language() end
  if name == 'selection' then return r:fragment(text) end
  if name == 'selection_line_start' then
    local s = r:line_range(text)
    return tostring(s + 1)
  end
  if name == 'selection_line_end' then
    local _, e = r:line_range(text)
    return tostring(e + 1)
  end
  error('unknown variable `' .. name .. '`')
end
M.VARIABLES = { 'cursor_line', 'cursor_column', 'buffer_name', 'file_path_absolute', 'line_ending',
  'current_working_directory', 'workspace_directory', 'language', 'selection', 'selection_line_start',
  'selection_line_end' }

local expand_token

local function expand_inner(content)
  local out = {}
  local i = 1
  while i <= #content do
    local j = content:find('%', i, true)
    if not j then
      out[#out + 1] = content:sub(i)
      break
    end
    out[#out + 1] = content:sub(i, j - 1)
    if content:sub(j + 1, j + 1) == '%' then
      out[#out + 1] = '%'
      i = j + 2
    else
      local t = tokenizer(content:sub(j))
      local tok = t:parse_percent()
      if tok.error then error(tok.error, 0) end
      if not tok.terminated then error('unterminated token ' .. tok.content, 0) end
      out[#out + 1] = expand_token(tok)
      i = j + t.pos - 1
    end
  end
  return table.concat(out)
end

local function shell_output(cmd)
  local shell = S.config.editor.shell
  local argv = { unpack(shell) }
  argv[#argv + 1] = cmd
  local res = vim.system(argv, { text = true }):wait()
  local out = res.stdout or ''
  if res.code ~= 0 then
    if res.stderr and res.stderr ~= '' then error(res.stderr) end
    error('Shell command failed: status ' .. res.code)
  end
  return (out:gsub('\n$', ''))
end

expand_token = function(tok)
  local k = tok.kind
  if k == 'unquoted' or k == 'quoted' then return tok.content end
  if k == 'expand' then return expand_inner(tok.content) end
  if k == 'var' then return expand_variable(tok.content) end
  if k == 'sh' then return shell_output(expand_inner(tok.content)) end
  if k == 'u' then
    local cp = tok.content:match('^%x+$') and tonumber(tok.content, 16)
    if not cp or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
      error(("could not interpret '%s' as a Unicode character code"):format(tok.content), 0)
    end
    return U.encode(cp)
  end
  if k == 'reg' then
    local content = tok.content
    if vim.fn.strchars(content) ~= 1 then
      error(('Invalid register `%s`: should only be a single character'):format(content), 0)
    end
    local vals = Regs.read(content) or {}
    return table.concat(vals, '')
  end
  return tok.content
end
M.expand_token = expand_token

local function parse_signature(cmd)
  local sig = cmd.signature_t
  if sig then return sig end
  sig = { min = 0, max = nil, raw_after = nil, flags = {} }
  local s = cmd.signature or ''
  local NAMED = {
    ['SHELL_SIGNATURE,'] = 'positionals: (1, Some(2)), raw_after: Some(1),',
    ['BUFFER_CLOSE_OTHERS_SIGNATURE,'] = 'positionals: (0, Some(0)), flags: &[Flag { name: "skip-visible", alias: Some(\'s\'), }]',
  }
  s = NAMED[s] or s
  local a, b = s:match('positionals: %((%d+), ([^)]+)%)')
  if a then
    sig.min = tonumber(a)
    local m = b:match('Some%((%d+)%)')
    sig.max = m and tonumber(m) or nil
  end
  local ra = s:match('raw_after: Some%((%d+)%)')
  if ra then sig.raw_after = tonumber(ra) end
  local consts = { WRITE_NO_FORMAT_FLAG = 'no-format', WRITE_NO_CODE_ACTIONS_FLAG = 'no-code-actions' }
  for c, n in pairs(consts) do
    if s:find(c, 1, true) then sig.flags[#sig.flags + 1] = { name = n } end
  end
  for name in s:gmatch('name: "([%w%-]+)"') do
    sig.flags[#sig.flags + 1] = { name = name }
  end
  for name, alias in s:gmatch('name: "([%w%-]+)",%s*alias: Some%(\'(%w)\'%)') do
    for _, f in ipairs(sig.flags) do
      if f.name == name then f.alias = alias end
    end
  end
  cmd.signature_t = sig
  return sig
end

M.parse_signature = parse_signature

local function parse_args(line, cmd, validate)
  local sig = parse_signature(cmd)
  local t = tokenizer(line)
  local args = { flags = {} }
  local only_positionals = false
  while true do
    local tok
    if sig.raw_after and #args >= sig.raw_after then
      only_positionals = true
      tok = t:rest()
    else
      tok = t:next()
    end
    if not tok then break end
    if validate and tok.error then error(tok.error) end
    if validate and (tok.kind == 'quoted' or tok.kind == 'expand') and tok.terminated == false and tok.kind ~= 'expand' then
      error('unterminated token ' .. tok.content)
    end
    local val = validate and expand_token(tok) or tok.content
    if not only_positionals and tok.kind == 'unquoted' and val:sub(1, 1) == '-' and #sig.flags > 0 then
      if val == '--' then
        only_positionals = true
      else
        local name = val:match('^%-%-(.+)$')
        local alias = val:match('^%-(%w)$')
        local found
        for _, f in ipairs(sig.flags) do
          if f.name == name or (alias and f.alias == alias) then found = f end
        end
        if found then
          args.flags[found.name] = true
        elseif validate then
          error('unknown flag \'' .. val .. '\'')
        end
      end
    else
      args[#args + 1] = val
    end
  end
  if validate then
    if #args < sig.min then
      error(('expected at least %d argument%s, got %d'):format(sig.min, sig.min == 1 and '' or 's', #args))
    end
    if sig.max and #args > sig.max then
      error(('expected at most %d argument%s, got %d'):format(sig.max, sig.max == 1 and '' or 's', #args))
    end
  end
  return args
end
M.parse_args = parse_args

local list = require('hx.typed_docs')
local map = {}
local impl = {}
M.list = list

local function index()
  map = {}
  for _, c in ipairs(list) do
    map[c.name] = c
    for _, a in ipairs(c.aliases or {}) do
      map[a] = c
    end
  end
end
index()

function M.register_plugin(name, fn, doc, signature)
  local c = map[name]
  if not c then
    c = { name = name, aliases = {}, doc = doc or 'Undocumented plugin command', plugin = true,
      signature = signature or 'Signature { positionals: (0, None), ..Signature::DEFAULT }' }
    list[#list + 1] = c
    map[name] = c
  end
  c.plugin_fn = fn
end

function M.lookup(name)
  return map[name]
end

local function strip_pos(e)
  if type(e) ~= 'string' then return tostring(e) end
  return (e:gsub('^[^\n]-%.lua:%d+: ', ''))
end

local function run_cmd(cmd, rest, event)
  local validate = event == 'validate'
  local ok, args = pcall(parse_args, rest, cmd, validate)
  if not ok then error(("'%s': %s"):format(cmd.name, strip_pos(args)), 0) end
  local f = cmd.plugin_fn or impl[cmd.fun]
  if not f then
    if validate then error(("'%s': not implemented"):format(cmd.name), 0) end
    return
  end
  local ok2, e2 = pcall(f, args, event)
  if not ok2 then error(("'%s': %s"):format(cmd.name, strip_pos(e2)), 0) end
end

function M.execute_command_line(input, event)
  local command, rest = M.split(input)
  if command == '' then return end
  if tonumber(command) and U.trim(rest) == '' then
    return run_cmd(map['goto'], command, event)
  end
  local cmd = map[command]
  if cmd then return run_cmd(cmd, rest, event) end
  if event == 'validate' then error(("no such command: '%s'"):format(command), 0) end
end

function M.execute_line(line, ctx, from_keymap)
  local ok, err = pcall(function()
    local name, rest = M.split(line)
    local cmd = map[name]
    if not cmd then error(("no such command: '%s'"):format(name), 0) end
    run_cmd(cmd, rest, 'validate')
  end)
  if not ok then S.set_status(tostring(err):gsub('^.-:%d+: ', ''), 'error') end
end

local function command_line_doc(input)
  local name = M.split(input)
  local cmd = map[name]
  if not cmd then return nil end
  local sig = parse_signature(cmd)
  if (#(cmd.aliases or {}) == 0) and #sig.flags == 0 then return cmd.doc end
  local doc = cmd.doc
  if #(cmd.aliases or {}) > 0 then doc = doc .. '\nAliases: ' .. table.concat(cmd.aliases, ', ') end
  if #sig.flags > 0 then
    doc = doc .. '\nFlags:'
    for _, f in ipairs(sig.flags) do
      doc = doc .. '\n  --' .. f.name .. (f.alias and ('/-' .. f.alias) or '')
    end
  end
  return doc
end

function M.command_mode()
  local Prompt = require('hx.ui.prompt')
  Prompt.open({
    prompt = ':',
    register = ':',
    completion = function(line)
      return require('hx.ui.completers').command_line(line)
    end,
    callback = function(input, event)
      local ok, err = pcall(M.execute_command_line, input, event)
      if not ok then S.set_status(tostring(err):gsub('^.-:%d+: ', ''), 'error') end
    end,
    doc = command_line_doc,
  })
end

local function v(event)
  return event == 'validate'
end

local function buffers_remaining()
  local modified = {}
  for _, b in ipairs(E.documents()) do
    if vim.bo[b].modified and not vim.b[b].hx_label then modified[#modified + 1] = b end
  end
  if #modified > 0 then
    local cur = E.buf()
    if not vim.tbl_contains(modified, cur) then E.switch_buffer(modified[1]) end
    local names = {}
    for _, b in ipairs(modified) do
      names[#names + 1] = '"' .. E.relative_path(b) .. '"'
    end
    error(('%d unsaved buffer%s remaining: [%s]'):format(#names, #names == 1 and '' or 's', table.concat(names, ', ')))
  end
end
M.buffers_remaining = buffers_remaining

local function editor_views()
  return vim.tbl_filter(function(w)
    return api.nvim_win_get_config(w).relative == ''
  end, api.nvim_tabpage_list_wins(0))
end

local function quit_impl(force)
  if #editor_views() == 1 and not force then buffers_remaining() end
  E.close_view(E.win(), force)
end

impl.quit = function(_, event)
  if not v(event) then return end
  quit_impl(false)
end
impl.force_quit = function(_, event)
  if not v(event) then return end
  quit_impl(true)
end

local function quit_all(force)
  if not force then buffers_remaining() end
  vim.cmd('qa!')
end
impl.quit_all = function(_, event)
  if v(event) then quit_all(false) end
end
impl.force_quit_all = function(_, event)
  if v(event) then quit_all(true) end
end
impl.cquit = function(args, event)
  if not v(event) then return end
  vim.cmd('cquit ' .. (args[1] or '1'))
end
impl.force_cquit = impl.cquit

local function parse_file(arg)
  local path, l, c = arg:match('^(.-):(%d+):(%d+)$')
  if not path then
    path, l = arg:match('^(.-):(%d+)$')
  end
  if path and path ~= '' then return path, tonumber(l), tonumber(c) end
  return arg
end

local function open_impl(args, action)
  for _, arg in ipairs(args) do
    local path, line, col = parse_file(arg)
    path = vim.fn.expand(path)
    if vim.fn.isdirectory(path) == 1 then
      vim.schedule(function()
        require('hx.ui.pickers').file_picker(path, { action = action })
        require('hx.input').after_key()
      end)
    else
      local buf = E.open(path, action)
      if buf and line then
        local text = E.text()
        local row = math.min(line - 1, text:len_lines() - 1)
        local pos = text:line_start(row) + math.max(0, (col or 1) - 1)
        E.set_sel(SL.Selection.point(math.min(pos, text:line_end(row))))
        require('hx.cmd.view_util').align_view(E.win(), 'center')
      end
    end
  end
end
M.open_impl = open_impl

impl.open = function(args, event)
  if v(event) then open_impl(args, 'replace') end
end

local function gather_paths(args)
  if #args == 0 then return { E.buf() } end
  local out, missing = {}, {}
  for _, a in ipairs(args) do
    local found
    for _, b in ipairs(E.documents()) do
      local n = api.nvim_buf_get_name(b)
      if n == a or vim.fn.fnamemodify(n, ':.') == a or n == vim.fn.fnamemodify(a, ':p') then found = b end
    end
    if found then
      out[#out + 1] = found
    else
      missing[#missing + 1] = "'" .. a .. "'"
    end
  end
  if #missing > 0 then S.set_status('cannot close non-existent buffers: ' .. table.concat(missing, ', '), 'error') end
  return out
end

local function close_by_ids(ids, force)
  local modified = {}
  for _, b in ipairs(ids) do
    local ok = E.close_buffer(b, force)
    if not ok then modified[#modified + 1] = b end
  end
  if #modified > 0 then
    if not vim.tbl_contains(modified, E.buf()) then E.switch_buffer(modified[1]) end
    local names = {}
    for _, b in ipairs(modified) do
      names[#names + 1] = '"' .. E.relative_path(b) .. '"'
    end
    error(('%d unsaved buffer%s remaining: [%s]'):format(#names, #names == 1 and '' or 's', table.concat(names, ', ')))
  end
end

impl.buffer_close = function(args, event)
  if v(event) then close_by_ids(gather_paths(args), false) end
end
impl.force_buffer_close = function(args, event)
  if v(event) then close_by_ids(gather_paths(args), true) end
end
local function others(skip_visible)
  local out = {}
  local visible = {}
  for _, w in ipairs(editor_views()) do
    visible[api.nvim_win_get_buf(w)] = true
  end
  local cur = E.buf()
  for _, b in ipairs(E.documents()) do
    if skip_visible then
      if not visible[b] then out[#out + 1] = b end
    elseif b ~= cur then
      out[#out + 1] = b
    end
  end
  return out
end
impl.buffer_close_others = function(args, event)
  if v(event) then close_by_ids(others(args.flags['skip-visible']), false) end
end
impl.force_buffer_close_others = function(args, event)
  if v(event) then close_by_ids(others(args.flags['skip-visible']), true) end
end
impl.buffer_close_all = function(_, event)
  if v(event) then close_by_ids(E.documents(), false) end
end
impl.force_buffer_close_all = function(_, event)
  if v(event) then close_by_ids(E.documents(), true) end
end
impl.buffer_next = function(_, event)
  if v(event) then require('hx.commands').run('goto_next_buffer') end
end
impl.buffer_previous = function(_, event)
  if v(event) then require('hx.commands').run('goto_previous_buffer') end
end

local function human_size(n)
  if n < 1024 then return n .. 'B' end
  local suffix = { 'B', 'KiB', 'MiB', 'GiB' }
  local i = 1
  local s = n
  while i < #suffix and s >= 1024 do
    s = s / 1024
    i = i + 1
  end
  return ('%.2f%s'):format(s, suffix[i])
end

local function save_buf(buf, path, force)
  local name = path or api.nvim_buf_get_name(buf)
  if name == '' then error('cannot write a buffer without a filename') end
  if path then
    path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
    pcall(api.nvim_buf_set_name, buf, path)
    name = path
  end
  local dir = vim.fn.fnamemodify(name, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    if force then
      vim.fn.mkdir(dir, 'p')
    else
      error("can't save file, parent directory does not exist (use :w! to create it)")
    end
  end
  local ok, err = pcall(api.nvim_buf_call, buf, function()
    vim.cmd('silent keepalt noautocmd write' .. (force and '!' or ''))
  end)
  if not ok then error(tostring(err):gsub('^Vim%(write%):', '')) end
  pcall(vim.api.nvim_exec_autocmds, 'BufWritePost', { buffer = buf })
  local lines = api.nvim_buf_line_count(buf)
  local size = vim.fn.getfsize(name)
  S.set_status(("'%s' written, %dL %s"):format(vim.fn.fnamemodify(name, ':.'), lines, human_size(math.max(0, size))))
  pcall(function()
    require('hx.lsp').did_save(buf)
  end)
end
M.save_buf = save_buf

local function write_impl(path, opts)
  opts = opts or {}
  local buf = E.buf()
  local cfg = S.config.editor
  if cfg['trim-trailing-whitespace'] then require('hx.cmd.view_util').trim_trailing_whitespace(buf) end
  D.checkpoint(buf)
  local auto_format = cfg['auto-format'] and opts.auto_format ~= false
  local after = opts.after
  if auto_format then
    require('hx.lsp.format').format_buffer(buf, function()
      local ok, err = pcall(save_buf, buf, path, opts.force)
      if not ok then S.set_status('Error saving: ' .. tostring(err):gsub('^.-:%d+: ', ''), 'error') end
      if ok and after then after() end
    end)
  else
    save_buf(buf, path, opts.force)
    if after then after() end
  end
end
M.write_impl = write_impl

impl.write = function(args, event)
  if v(event) then write_impl(args[1], { force = false, auto_format = not args.flags['no-format'] }) end
end
impl.force_write = function(args, event)
  if v(event) then write_impl(args[1], { force = true, auto_format = not args.flags['no-format'] }) end
end
impl.write_buffer_close = function(args, event)
  if not v(event) then return end
  local buf = E.buf()
  write_impl(args[1], { after = function() pcall(close_by_ids, { buf }, false) end })
end
impl.force_write_buffer_close = function(args, event)
  if not v(event) then return end
  local buf = E.buf()
  write_impl(args[1], { force = true, after = function() pcall(close_by_ids, { buf }, true) end })
end
impl.write_quit = function(args, event)
  if not v(event) then return end
  write_impl(args[1], { after = function() pcall(quit_impl, false) end })
end
impl.force_write_quit = function(args, event)
  if not v(event) then return end
  write_impl(args[1], { force = true, after = function() pcall(quit_impl, true) end })
end
local function write_all(force, quit)
  local errs = {}
  local pending = 0
  local function done()
    if pending == 0 and quit then
      if #errs == 0 or force then vim.cmd('qa!') end
    end
  end
  for _, b in ipairs(E.documents()) do
    if vim.bo[b].modified then
      if api.nvim_buf_get_name(b) == '' then
        if not force then errs[#errs + 1] = 'cannot write a buffer without a filename' end
      else
        pending = pending + 1
        local fn = function()
          local ok, err = pcall(save_buf, b, nil, force)
          if not ok then errs[#errs + 1] = tostring(err) end
          pending = pending - 1
          done()
        end
        if S.config.editor['auto-format'] then
          require('hx.lsp.format').format_buffer(b, fn)
        else
          fn()
        end
      end
    end
  end
  if #errs > 0 and not quit then error(vim.inspect(errs)) end
  done()
end
impl.write_all = function(_, event)
  if v(event) then write_all(false, false) end
end
impl.force_write_all = function(_, event)
  if v(event) then write_all(true, false) end
end
impl.write_all_quit = function(_, event)
  if v(event) then write_all(false, true) end
end
impl.force_write_all_quit = function(_, event)
  if v(event) then write_all(true, true) end
end
impl.exit = function(args, event)
  if not v(event) then return end
  if vim.bo[E.buf()].modified then
    write_impl(args[1], { auto_format = not args.flags['no-format'], after = function()
      local ok, err = pcall(quit_impl, false)
      if not ok then S.set_status(tostring(err):gsub('^.-:%d+: ', ''), 'error') end
    end })
  else
    quit_impl(false)
  end
end
impl.force_exit = function(args, event)
  if not v(event) then return end
  if vim.bo[E.buf()].modified then
    write_impl(args[1], { force = true, auto_format = not args.flags['no-format'], after = function()
      pcall(quit_impl, true)
    end })
  else
    quit_impl(true)
  end
end
impl.update = function(args, event)
  if v(event) and vim.bo[E.buf()].modified then write_impl(args[1]) end
end

impl.new_file = function(_, event)
  if v(event) then E.switch_buffer(E.new_scratch()) end
end

impl.format = function(_, event)
  if v(event) then require('hx.lsp.format').format_buffer(E.buf()) end
end

impl.set_indent_style = function(args, event)
  local buf = E.buf()
  if #args == 0 then
    if v(event) then
      if vim.bo[buf].expandtab then
        local n = vim.bo[buf].shiftwidth
        S.set_status(n .. ' space' .. (n == 1 and '' or 's'))
      else
        S.set_status('tabs')
      end
    end
    return
  end
  if not v(event) then return end
  local a = args[1]:lower()
  if a == 't' or a == 'tabs' then
    vim.bo[buf].expandtab = false
    vim.bo[buf].shiftwidth = 0
  else
    local n = tonumber(a)
    if not n or n < 1 or n > 16 then error('invalid indent style \'' .. args[1] .. '\'') end
    vim.bo[buf].expandtab = true
    vim.bo[buf].shiftwidth = n
  end
end

impl.set_line_ending = function(args, event)
  local buf = E.buf()
  if #args == 0 then
    if v(event) then S.set_status(vim.bo[buf].fileformat == 'dos' and 'crlf' or 'lf') end
    return
  end
  if not v(event) then return end
  local a = args[1]:lower()
  if a == 'crlf' then
    vim.bo[buf].fileformat = 'dos'
  elseif a == 'lf' then
    vim.bo[buf].fileformat = 'unix'
  else
    error('invalid line ending')
  end
end

impl.earlier = function(args, event)
  if not v(event) then return end
  local n, unit = (args[1] or '1'):match('^(%d+)(%a*)$')
  if not n then error('invalid undo kind') end
  local before = vim.fn.changenr()
  D.earlier(tonumber(n), unit ~= '' and unit or nil)
end
impl.later = function(args, event)
  if not v(event) then return end
  local n, unit = (args[1] or '1'):match('^(%d+)(%a*)$')
  if not n then error('invalid undo kind') end
  D.later(tonumber(n), unit ~= '' and unit or nil)
end

impl.theme = function(args, event)
  if event == 'abort' then return end
  if #args == 0 then
    if v(event) then S.set_status(vim.g.colors_name or 'spacemacs') end
    return
  end
  if v(event) then
    if args[1] ~= 'spacemacs' then error('could not load theme: theme not found') end
    S.set_status('spacemacs')
  end
end

local function yank_joined(args, event, reg)
  if not v(event) then return end
  local C = require('hx.commands')
  C.load()
  C.yank_joined_impl(args[1] or '\n', reg)
end
impl.yank_joined = function(args, event)
  yank_joined(args, event, S.config.editor['default-yank-register'] or '"')
end
impl.yank_main_selection_to_clipboard = function(_, event)
  if not v(event) then return end
  local C = require('hx.commands')
  C.load()
  C.yank_main_selection_to_register('+')
end
impl.yank_joined_to_clipboard = function(args, event) yank_joined(args, event, '+') end
impl.yank_main_selection_to_primary_clipboard = function(_, event)
  if not v(event) then return end
  local C = require('hx.commands')
  C.load()
  C.yank_main_selection_to_register('*')
end
impl.yank_joined_to_primary_clipboard = function(args, event) yank_joined(args, event, '*') end
local function paste(reg, action)
  return function(_, event)
    if not v(event) then return end
    require('hx.cmd.edit_paste').paste(reg, action, 1)
  end
end
impl.paste_clipboard_after = paste('+', 'after')
impl.paste_clipboard_before = paste('+', 'before')
impl.paste_primary_clipboard_after = paste('*', 'after')
impl.paste_primary_clipboard_before = paste('*', 'before')
impl.replace_selections_with_clipboard = function(_, event)
  if v(event) then require('hx.cmd.edit_paste').replace_selections_with_register('+', 1) end
end
impl.replace_selections_with_primary_clipboard = function(_, event)
  if v(event) then require('hx.cmd.edit_paste').replace_selections_with_register('*', 1) end
end
impl.show_clipboard_provider = function(_, event)
  if v(event) then S.set_status(Regs.provider_name()) end
end

local dir_stack = {}
local last_cwd
local function change_dir(dir)
  local prev = vim.fn.getcwd()
  if dir == '-' then
    if not last_cwd then error('No previous working directory') end
    dir = last_cwd
  end
  dir = vim.fn.expand(dir == nil and '~' or dir)
  local ok, err = pcall(vim.fn.chdir, dir)
  if not ok or vim.fn.getcwd() == prev and vim.fn.fnamemodify(dir, ':p'):gsub('/$', '') ~= prev then
    if not ok then error(("Couldn't change the current working directory: %s"):format(err)) end
  end
  last_cwd = prev
  S.set_status(('Current working directory is now %s'):format(vim.fn.getcwd()))
end
impl.change_current_directory = function(args, event)
  if v(event) then change_dir(args[1]) end
end
impl.show_current_directory = function(_, event)
  if not v(event) then return end
  local cwd = vim.fn.getcwd()
  local msg = 'Current working directory is ' .. cwd
  if vim.fn.isdirectory(cwd) == 1 then
    S.set_status(msg)
  else
    S.set_status(msg .. ' (deleted)', 'error')
  end
end
impl.show_directory_stack = function(_, event)
  if not v(event) then return end
  if #dir_stack == 0 then
    S.set_status('Stack is empty', 'error')
    return
  end
  local out = {}
  for i = #dir_stack, 1, -1 do
    out[#out + 1] = dir_stack[i]
  end
  S.set_status(table.concat(out, '\n'))
end
impl.push_directory = function(args, event)
  if not v(event) then return end
  table.insert(dir_stack, vim.fn.getcwd())
  change_dir(args[1])
end
impl.pop_directory = function(_, event)
  if not v(event) then return end
  local d = table.remove(dir_stack)
  if not d then
    S.set_status('Stack is empty', 'error')
    return
  end
  change_dir(d)
end

impl.set_encoding = function(args, event)
  local buf = E.buf()
  if #args == 0 then
    if v(event) then
      local enc = vim.bo[buf].fileencoding
      S.set_status(enc ~= '' and enc or 'utf-8')
    end
    return
  end
  if v(event) then vim.bo[buf].fileencoding = args[1] end
end

impl.get_character_info = function(_, event)
  if not v(event) then return end
  local text = E.text()
  local pos = E.sel():prim():cursor(text)
  local stop = text:next_grapheme(pos)
  if pos == stop then return end
  local g = text:slice(pos, stop)
  local printable = {}
  local cps = {}
  for _, cp in U.chars(g) do
    cps[#cps + 1] = cp
    if cp == 0 then
      printable[#printable + 1] = '\\0'
    elseif cp == 9 then
      printable[#printable + 1] = '\\t'
    elseif cp == 10 then
      printable[#printable + 1] = '\\n'
    elseif cp == 13 then
      printable[#printable + 1] = '\\r'
    else
      printable[#printable + 1] = U.encode(cp)
    end
  end
  local unicode = ''
  local enc = vim.bo[E.buf()].fileencoding
  if enc == '' or enc == 'utf-8' then
    local parts = {}
    for i, cp in ipairs(cps) do
      parts[i] = ('U+%04x'):format(cp)
    end
    unicode = ' (' .. table.concat(parts, ' ') .. ')'
  end
  local dec = #g == 1 and (' Dec ' .. g:byte(1)) or ''
  local hex = {}
  for i, cp in ipairs(cps) do
    if i ~= 1 then hex[#hex + 1] = ' +' end
    local bytes = U.encode(cp)
    for k = 1, #bytes do
      hex[#hex + 1] = (' %02x'):format(bytes:byte(k))
    end
  end
  S.set_status(('"%s"%s%s Hex%s'):format(table.concat(printable), unicode, dec, table.concat(hex)))
end

local function reload_buf(buf)
  local win = E.win()
  local sel = S.get_sel(win, buf)
  api.nvim_buf_call(buf, function()
    vim.cmd('silent! edit!')
  end)
  local text = require('hx.text').get(buf)
  local rs = {}
  for i, r in ipairs(sel.ranges) do
    rs[i] = SL.R(math.min(r.anchor, text:len()), math.min(r.head, text:len()))
  end
  S.set_sel(SL.Selection.new(rs, sel.primary):ensure_invariants(text), win, buf)
  require('hx.diff').reload(buf)
end
impl.reload = function(_, event)
  if not v(event) then return end
  local buf = E.buf()
  if vim.bo[buf].modified then
  end
  reload_buf(buf)
end
impl.reload_all = function(_, event)
  if not v(event) then return end
  for _, b in ipairs(E.documents()) do
    if api.nvim_buf_get_name(b) ~= '' then reload_buf(b) end
  end
end

impl.lsp_workspace_command = function(args, event)
  if v(event) then require('hx.lsp').workspace_command(args) end
end
impl.lsp_restart = function(args, event)
  if v(event) then require('hx.lsp').restart(args) end
end
impl.lsp_stop = function(args, event)
  if v(event) then require('hx.lsp').stop(args) end
end

impl.tree_sitter_scopes = function(_, event)
  if not v(event) then return end
  local text = E.text()
  local pos = E.sel():prim():cursor(text)
  local scopes = require('hx.indent').get_scopes(E.buf(), text, pos)
  local content = 'scopes: ' .. vim.inspect(scopes)
  require('hx.ui.popup').text('hover', content, {})
end
impl.tree_sitter_highlight_name = function(_, event)
  if not v(event) then return end
  local text = E.text()
  local pos = E.sel():prim():cursor(text)
  local caps = require('hx.syntax').scopes_at(E.buf(), pos)
  if #caps == 0 then return end
  S.set_status(caps[#caps])
end
impl.tree_sitter_layers = function(_, event)
  if not v(event) then return end
  local p = require('hx.syntax').parser(E.buf())
  if not p then error('Syntax information is not available') end
  local langs = {}
  p:for_each_tree(function(_, lt)
    langs[#langs + 1] = lt:lang()
  end)
  require('hx.ui.popup').text('hover', vim.inspect(langs), {})
end
impl.tree_sitter_subtree = function(_, event)
  if not v(event) then return end
  local Syn = require('hx.syntax')
  local root = Syn.root(E.buf())
  if not root then return end
  local r = E.sel():prim()
  local node = Syn.named_descendant_for_byte_range(E.buf(), r:from(), r:to())
  if node then
    require('hx.ui.popup').markdown('hover', '```tsq\n' .. node:sexpr() .. '\n```', {})
  end
end

impl.vsplit = function(args, event)
  if not v(event) then return end
  if #args == 0 then
    E.split('vsplit')
  else
    open_impl(args, 'vsplit')
  end
end
impl.hsplit = function(args, event)
  if not v(event) then return end
  if #args == 0 then
    E.split('hsplit')
  else
    open_impl(args, 'hsplit')
  end
end
impl.vsplit_new = function(_, event)
  if v(event) then E.split('vsplit', E.new_scratch()) end
end
impl.hsplit_new = function(_, event)
  if v(event) then E.split('hsplit', E.new_scratch()) end
end

impl.tutor = function(_, event)
  if v(event) then error('tutor is not available') end
end

impl.goto_line_number = function(args, event)
  local C = require('hx.commands')
  C.load()
  local win, buf = E.win(), E.buf()
  if event == 'abort' then
    if M._goto_snapshot then
      S.set_sel(M._goto_snapshot, win, buf)
      M._goto_snapshot = nil
    end
    return
  end
  if event == 'update' then
    if not M._goto_snapshot then M._goto_snapshot = E.sel():copy() end
    local n = tonumber(args[1] or '')
    if n then C.goto_line_without_jumplist(n, S.mode == 'select') end
    return
  end
  local n = tonumber(args[1] or '')
  if not n then error('expected a line number') end
  if M._goto_snapshot then
    local cur = E.sel()
    S.set_sel(M._goto_snapshot, win, buf)
    D.push_jump(win, buf)
    S.set_sel(cur, win, buf)
    M._goto_snapshot = nil
  else
    D.push_jump(win, buf)
  end
  C.goto_line_without_jumplist(n, S.mode == 'select')
end

impl.language = function(args, event)
  local buf = E.buf()
  if #args == 0 then
    if v(event) then S.set_status(E.language(buf)) end
    return
  end
  if not v(event) then return end
  local l = args[1] == 'text' and '' or args[1]
  vim.bo[buf].filetype = l
end

local function get_path(key)
  local cur = S.config.editor
  for part in key:gmatch('[^.]+') do
    if type(cur) ~= 'table' then return nil end
    cur = cur[part]
  end
  return cur
end

local function set_path(key, value)
  local parts = vim.split(key, '.', { plain = true })
  local cur = S.config.editor
  for i = 1, #parts - 1 do
    cur = cur[parts[i]]
    if type(cur) ~= 'table' then error('Unknown key `' .. key .. '`') end
  end
  cur[parts[#parts]] = value
end

local function apply_config_change()
  local cfg = S.config.editor
  S.config.cursorline = cfg.cursorline
  vim.o.wrap = cfg['soft-wrap'].enable
  vim.o.scrolloff = cfg.scrolloff
  vim.o.showtabline = cfg.bufferline == 'never' and 0 or 2
  for _, w in ipairs(editor_views()) do
    vim.wo[w].wrap = cfg['soft-wrap'].enable
  end
  require('hx.render').redraw()
  pcall(vim.cmd, 'redraw!')
end
M.apply_config_change = apply_config_change

local function parse_value(s, like)
  local ok, val = pcall(vim.json.decode, s)
  if not ok then val = s end
  if type(like) == 'boolean' and type(val) ~= 'boolean' then error('Could not parse field `' .. s .. '`') end
  if type(like) == 'number' and type(val) ~= 'number' then error('Could not parse field `' .. s .. '`') end
  return val
end

impl.set_option = function(args, event)
  if not v(event) then return end
  local key, arg = args[1], args[2]
  local cur = get_path(key)
  if cur == nil then error('Unknown key `' .. key .. '`') end
  set_path(key, parse_value(arg, cur))
  apply_config_change()
end

impl.get_option = function(args, event)
  if not v(event) then return end
  local val = get_path(args[1])
  if val == nil then error('Unknown key `' .. args[1] .. '`') end
  S.set_status(type(val) == 'table' and vim.json.encode(val) or tostring(val))
end

impl.toggle_option = function(args, event)
  if not v(event) then return end
  local key = args[1]
  local rest = {}
  for i = 2, #args do
    rest[#rest + 1] = args[i]
  end
  if #rest == 1 then rest = vim.split(rest[1], '%s+', { trimempty = true }) end
  local cur = get_path(key)
  if cur == nil then error('Unknown key `' .. key .. '`') end
  local new
  if type(cur) == 'boolean' then
    new = not cur
  elseif type(cur) == 'string' then
    if #rest == 0 then error('Need options to toggle between') end
    local idx = 0
    for i, r in ipairs(rest) do
      if r == cur then idx = i end
    end
    new = rest[(idx % #rest) + 1]
  elseif type(cur) == 'number' then
    if #rest == 0 then error('Need options to toggle between') end
    local idx = 0
    for i, r in ipairs(rest) do
      if tonumber(r) == cur then idx = i end
    end
    new = tonumber(rest[(idx % #rest) + 1])
  else
    error('Configuration ' .. key .. ' cannot be toggled')
  end
  set_path(key, new)
  apply_config_change()
  S.set_status(("'%s' is now set to %s"):format(key, type(new) == 'string' and ('"' .. new .. '"') or tostring(new)))
end

impl.sort = function(args, event)
  if not v(event) then return end
  local text = E.text()
  local sel = E.sel()
  if #sel.ranges < 2 then error('Sorting requires multiple selections. Hint: split selection first') end
  local frags = sel:fragments(text)
  local sorted = { unpack(frags) }
  local insensitive = args.flags['insensitive']
  table.sort(sorted, function(a, b)
    if insensitive then
      a, b = a:lower(), b:lower()
    end
    if args.flags['reverse'] then return a > b end
    return a < b
  end)
  local changes = {}
  for i, r in ipairs(sel.ranges) do
    changes[i] = { r:from(), r:to(), sorted[i] }
  end
  D.apply(SL.Transaction.change(text, changes), { win = E.win() })
end

impl.reflow = function(args, event)
  if not v(event) then return end
  local width = tonumber(args[1] or '') or S.config.editor['text-width'] or 80
  local text = E.text()
  local sel = E.sel()
  local changes = {}
  for _, r in ipairs(sel.ranges) do
    local frag = r:fragment(text)
    changes[#changes + 1] = { r:from(), r:to(), require('hx.ui.text').reflow_hard_wrap(frag, width) }
  end
  D.apply(SL.Transaction.change(text, changes), { win = E.win() })
end

impl.refresh_config = function(_, event)
  if not v(event) then return end
  package.loaded['hx.config'] = nil
  package.loaded['hx.languages'] = nil
  local root = require('hx').root
  local user = dofile(root .. '/lua/hx/config.lua')
  for k, val in pairs(user.editor) do
    if type(val) == 'table' and type(S.config.editor[k]) == 'table' and val[1] == nil then
      for k2, v2 in pairs(val) do
        S.config.editor[k][k2] = v2
      end
    else
      S.config.editor[k] = val
    end
  end
  S.config.keys = user.keys
  require('hx.keymap').build(S.config.keys)
  apply_config_change()
end

impl.open_config = function(_, event)
  if v(event) then E.open(require('hx').root .. '/lua/hx/config.lua') end
end
impl.open_workspace_config = function(_, event)
  if not v(event) then return end
  local ws = E.find_workspace()
  E.open(ws .. '/.helix/config.toml')
end
impl.open_log = function(_, event)
  if v(event) then E.open(vim.fn.stdpath('log') .. '/lsp.log') end
end

impl.insert_output = function(args, event)
  if v(event) then require('hx.shell').shell(table.concat(args, ' '), 'insert') end
end
impl.append_output = function(args, event)
  if v(event) then require('hx.shell').shell(table.concat(args, ' '), 'append') end
end
impl.pipe = function(args, event)
  if v(event) then require('hx.shell').shell(table.concat(args, ' '), 'replace') end
end
impl.pipe_to = function(args, event)
  if v(event) then require('hx.shell').shell(table.concat(args, ' '), 'ignore') end
end
impl.run_shell_command = function(args, event)
  if not v(event) then return end
  require('hx.shell').run_shell_command(table.concat(args, ' '))
end

impl.reset_diff_change = function(_, event)
  if not v(event) then return end
  local buf = E.buf()
  local Diff = require('hx.diff')
  local hunks = Diff.hunks(buf)
  local base = Diff.base_text(buf)
  if not hunks or not base then error('Diff is not available in the current buffer') end
  local text = E.text()
  local base_lines = vim.split(base, '\n', { plain = true })
  local changes = {}
  local count = 0
  for _, h in ipairs(hunks) do
    local hit = false
    for _, r in ipairs(E.sel().ranges) do
      local s, e = r:line_range(text)
      local hs, he = h.after_start, math.max(h.after_end - 1, h.after_start)
      if s <= he and e >= hs then hit = true end
    end
    if hit then
      local from = text:line_start(h.after_start)
      local to = text:line_start(math.min(h.after_end, text:len_lines() - 1))
      if h.after_end >= text:len_lines() - 1 then to = text:len() end
      local rep = {}
      for i = h.before_start + 1, h.before_end do
        rep[#rep + 1] = base_lines[i] .. '\n'
      end
      changes[#changes + 1] = { from, to, table.concat(rep) }
      count = count + 1
    end
  end
  if count == 0 then error('There are no changes under any selection') end
  D.apply(SL.Transaction.change(text, changes), { win = E.win() })
  S.set_status(('Reset %d change%s'):format(count, count == 1 and '' or 's'))
end

impl.clear_register = function(args, event)
  if not v(event) then return end
  if #args == 0 then
    Regs.clear()
    S.set_status('All registers cleared')
    return
  end
  local r = args[1]
  if #r ~= 1 then error('Invalid register ' .. r) end
  if Regs.remove(r) then
    S.set_status(('Register %s cleared'):format(r))
  else
    S.set_status(('Register %s not found'):format(r), 'error')
  end
end

impl.set_register = function(args, event)
  if not v(event) then return end
  local r = args[1]
  if not r or #r ~= 1 then error('Invalid register ' .. tostring(r)) end
  local vals = {}
  for i = 2, #args do
    vals[#vals + 1] = args[i]
  end
  local ok, err = Regs.write(r, vals)
  if not ok then error(err) end
end

impl.redraw = function(_, event)
  if v(event) then vim.cmd('redraw!') end
end

impl.move_buffer = function(args, event)
  if not v(event) then return end
  local buf = E.buf()
  local old = api.nvim_buf_get_name(buf)
  if old == '' then error('Scratch buffer cannot be moved. Use :write instead') end
  local new = vim.fn.fnamemodify(vim.fn.expand(args[1]), ':p')
  if vim.fn.isdirectory(new) == 1 then new = new .. '/' .. vim.fn.fnamemodify(old, ':t') end
  local ok, err = vim.uv.fs_rename(old, new)
  if not ok then error('Could not move file: ' .. tostring(err)) end
  api.nvim_buf_set_name(buf, new)
  pcall(api.nvim_buf_call, buf, function()
    vim.cmd('silent! write!')
  end)
end
impl.force_move_buffer = impl.move_buffer

impl.yank_diagnostic = function(args, event)
  if not v(event) then return end
  local r = args[1] or '+'
  if U.char_count(r) ~= 1 then error('Invalid register ' .. r) end
  local prim = E.sel():prim()
  local msgs = {}
  for _, d in ipairs(require('hx.lsp.diagnostics').doc_diagnostics(E.buf())) do
    if prim:overlaps(SL.R(d.s, d.e)) then msgs[#msgs + 1] = d.message end
  end
  local n = #msgs
  if n == 0 then error('No diagnostics under primary selection') end
  local ok, err = Regs.write(r, msgs)
  if not ok then error(err) end
  S.set_status(('Yanked %d diagnostic%s to register %s'):format(n, n == 1 and '' or 's', r))
end

impl.read = function(args, event)
  if not v(event) then return end
  local path = vim.fn.expand(args[1])
  if vim.fn.filereadable(path) == 0 then error(('path is not a file: "%s"'):format(path)) end
  local f = io.open(path, 'rb')
  local contents = f:read('*a')
  f:close()
  local text = E.text()
  D.apply(SL.Transaction.insert(text, E.sel(), contents), { win = E.win() })
end

impl.echo = function(args, event)
  if v(event) then S.set_status(table.concat(args, ' ')) end
end

impl.noop = function() end

local function unsupported(name)
  return function(_, event)
    if v(event) then error(name .. ' is not supported in this configuration') end
  end
end
impl.debug_start = unsupported('debugging')
impl.debug_remote = unsupported('debugging')
impl.debug_eval = unsupported('debugging')
impl.trust_workspace = function(_, event)
  if v(event) then S.set_status('workspace trusted') end
end
impl.untrust_workspace = function() end
impl.exclude_workspace = function() end

return M
