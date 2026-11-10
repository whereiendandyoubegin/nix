local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')
local E = require('hx.editor')
local SL = require('hx.selection')
local Picker = require('hx.ui.picker')

local M = {}

local W = require('hx.walk')

local function path_style()
  return {
    dir = T.get('ui.text.directory'),
    num = T.get('constant.numeric.integer'),
    colon = T.get('punctuation'),
  }
end

local function stylize(path, line)
  local st = path_style()
  local spans = {}
  if path then
    local dir = vim.fn.fnamemodify(path, ':h')
    if dir ~= '.' and dir ~= '' and path:find('/') then spans[#spans + 1] = { dir .. '/', st.dir } end
    spans[#spans + 1] = { vim.fn.fnamemodify(path, ':t'), nil }
  else
    spans[#spans + 1] = { '[scratch]', nil }
  end
  if line then
    spans[#spans + 1] = { ':', st.colon }
    spans[#spans + 1] = { tostring(line + 1), st.num }
  end
  return spans
end
M.stylize = stylize

local function rel(path)
  return vim.fn.fnamemodify(path, ':.')
end

function M.file_picker(root, opts)
  opts = opts or {}
  root = vim.fn.fnamemodify(root, ':p'):gsub('/$', '')
  if vim.fn.isdirectory(root) == 0 then
    S.set_status('Workspace directory does not exist', 'error')
    return
  end
  local dir_style = T.get('ui.text.directory')
  local p
  p = Picker.open({
    columns = {
      {
        name = 'path',
        format = function(path)
          local r = path:sub(1, #root + 1) == root .. '/' and path:sub(#root + 2) or path
          local spans = {}
          local d = r:match('^(.*)/[^/]*$')
          if d then
            spans[#spans + 1] = { d, dir_style }
            spans[#spans + 1] = { '/', dir_style }
          end
          spans[#spans + 1] = { r:match('[^/]*$'), nil }
          return spans
        end,
      },
    },
    path_matching = true,
    default_action = opts.action,
    on_select = function(path, action)
      local ok, err = pcall(E.open, path, action)
      if not ok then S.set_status(('unable to open "%s"'):format(path), 'error') end
      require('hx.input').after_key()
    end,
    preview = function(path)
      return { path = path }
    end,
  })
  p.running = true
  local gen = p.generation
  local handle
  handle = W.files(root, W.opts_from(S.config.editor['file-picker']), function(paths)
    if gen ~= p.generation or require('hx.ui.compositor').find(p.id) ~= p then
      handle.cancel()
      return
    end
    p:inject(paths)
  end, function()
    p.running = false
    p:schedule_render()
  end)
  return p
end

function M.file_picker_root()
  local root = E.find_workspace()
  M.file_picker(root)
end

function M.file_picker_cwd()
  M.file_picker(vim.fn.getcwd())
end

function M.file_picker_buffer_dir()
  local name = api.nvim_buf_get_name(E.buf())
  if name == '' then
    S.set_status('Current buffer has no parent, opening file picker in current working directory', 'error')
    return M.file_picker(vim.fn.getcwd())
  end
  M.file_picker(vim.fn.fnamemodify(name, ':h'))
end

function M.file_explorer(root)
  root = vim.fn.fnamemodify(root, ':p'):gsub('/$', '')
  if root == '' then root = '/' end
  local items = {}
  if vim.fn.fnamemodify(root, ':h') ~= root then items[#items + 1] = { root .. '/..', true } end
  for _, it in ipairs(W.dir(root, W.opts_from({ hidden = false, ['git-ignore'] = false, ignore = true }))) do
    items[#items + 1] = it
  end
  local dir_style = T.get('ui.text.directory')
  Picker.open({
    columns = {
      {
        name = 'path',
        format = function(it)
          local name = it[1]:sub(#root + 2)
          if it[2] then return { { name .. '/', dir_style } } end
          return name
        end,
      },
    },
    items = items,
    path_matching = true,
    on_select = function(it, action)
      if it[2] then
        local new_root = vim.fn.resolve(vim.fn.fnamemodify(it[1], ':p')):gsub('/$', '')
        vim.schedule(function()
          M.file_explorer(new_root)
          require('hx.input').after_key()
        end)
      else
        pcall(E.open, it[1], action)
      end
    end,
    preview = function(it)
      return { path = it[1] }
    end,
  })
end

function M.file_explorer_root()
  M.file_explorer((E.find_workspace()))
end
function M.file_explorer_cwd()
  M.file_explorer(vim.fn.getcwd())
end
function M.file_explorer_buffer_dir()
  local name = api.nvim_buf_get_name(E.buf())
  if name == '' then
    S.set_status('Current buffer has no parent, opening file explorer in current working directory', 'error')
    return M.file_explorer(vim.fn.getcwd())
  end
  M.file_explorer(vim.fn.fnamemodify(name, ':h'))
end

local focused_at = {}
api.nvim_create_autocmd('BufEnter', {
  callback = function(ev)
    focused_at[ev.buf] = vim.uv.hrtime()
  end,
})

function M.buffer_picker()
  local cur = E.buf()
  local items = {}
  for _, b in ipairs(E.documents()) do
    local name = api.nvim_buf_get_name(b)
    items[#items + 1] = {
      id = b,
      path = name ~= '' and rel(name) or nil,
      modified = vim.bo[b].modified,
      current = b == cur,
      focused = focused_at[b] or 0,
    }
  end
  table.sort(items, function(a, b)
    return a.focused > b.focused
  end)
  Picker.open({
    columns = {
      { name = 'id', format = function(m) return tostring(m.id) end },
      {
        name = 'flags',
        format = function(m)
          return (m.modified and '+' or '') .. (m.current and '*' or '')
        end,
      },
      { name = 'path', format = function(m) return stylize(m.path, nil) end },
    },
    primary = 3,
    items = items,
    on_select = function(m, action)
      if action == 'hsplit' or action == 'vsplit' then E.split(action, m.id) else E.switch_buffer(m.id) end
    end,
    preview = function(m)
      local line
      for w, v in pairs(S.views) do
        local sel = v.sels[m.id]
        if sel then
          local text = require('hx.text').get(m.id)
          line = sel:prim():cursor_line(text)
          break
        end
      end
      return { buf = m.id, range = line and { line, line } or nil }
    end,
  })
end

function M.jumplist_picker()
  local items = {}
  for win, v in pairs(S.views) do
    if api.nvim_win_is_valid(win) then
      local cur = api.nvim_win_get_buf(win)
      for i = #v.jumps, 1, -1 do
        local j = v.jumps[i]
        if api.nvim_buf_is_valid(j.buf) then
          local text = require('hx.text').get(j.buf)
          local frags = j.sel:fragments(text)
          local name = api.nvim_buf_get_name(j.buf)
          items[#items + 1] = {
            id = j.buf,
            path = name ~= '' and rel(name) or nil,
            sel = j.sel,
            line = j.sel:prim():cursor_line(text),
            text = table.concat(frags, ' '),
            current = cur == j.buf,
          }
        end
      end
    end
  end
  Picker.open({
    columns = {
      { name = 'id', format = function(m) return tostring(m.id) end },
      { name = 'path', format = function(m) return stylize(m.path, m.line) end },
      { name = 'flags', format = function(m) return m.current and ' (*)' or '' end },
      { name = 'contents', format = function(m) return m.text:gsub('\n', ' ') end },
    },
    primary = 2,
    items = items,
    on_select = function(m, action)
      if action == 'hsplit' or action == 'vsplit' then
        E.split(action, m.id)
      else
        E.switch_buffer(m.id)
      end
      E.set_sel(m.sel)
      require('hx.cmd.view_util').ensure_cursor_in_view_center(E.win())
    end,
    preview = function(m)
      return { buf = m.id, range = { m.line, m.line } }
    end,
  })
end

local SEV_ORDER = { error = 1, warning = 2, info = 3, hint = 4 }
local function diag_picker(list, show_path)
  table.sort(list, function(a, b)
    return (SEV_ORDER[a.severity] or 4) < (SEV_ORDER[b.severity] or 4)
  end)
  local columns = {
    {
      name = 'severity',
      format = function(d)
        local lbl = ({ hint = 'HINT', info = 'INFO', warning = 'WARN', error = 'ERROR' })[d.severity] or ''
        return { { lbl, T.get(d.severity or 'hint') } }
      end,
    },
    { name = 'source', format = function(d) return d.source or '' end },
    { name = 'code', format = function(d) return d.code and tostring(d.code) or '' end },
    { name = 'message', format = function(d) return (d.message:gsub('\n', ' ')) end },
  }
  local primary = 4
  if show_path then
    table.insert(columns, 4, { name = 'path', format = function(d) return vim.fn.pathshorten(rel(d.path), 1) end })
    primary = 5
  end
  Picker.open({
    columns = columns,
    primary = primary,
    items = list,
    truncate_start = false,
    on_select = function(d, action)
      require('hx.lsp.util').jump_to_location(d.path, d.range_lsp, d.encoding, action, d)
      pcall(function()
        require('hx.lsp.diagnostics').immediately_show(E.buf())
      end)
    end,
    preview = function(d)
      return { path = d.path, range = { d.lnum, d.end_lnum } }
    end,
  })
end

function M.diagnostics_picker()
  local Dg = require('hx.lsp.diagnostics')
  local buf = E.buf()
  if api.nvim_buf_get_name(buf) == '' then return end
  diag_picker(Dg.picker_items(buf), false)
end

function M.workspace_diagnostics_picker()
  local Dg = require('hx.lsp.diagnostics')
  diag_picker(Dg.picker_items(nil), true)
end

function M.changed_file_picker()
  local cwd = vim.fn.getcwd()
  if vim.fn.isdirectory(cwd) == 0 then
    S.set_status('Current working directory does not exist', 'error')
    return
  end
  local styles = {
    untracked = { '+ untracked', T.get('diff.plus') },
    modified = { '~ modified', T.get('diff.delta') },
    conflict = { 'x conflict', T.get('diff.delta.conflict') },
    deleted = { '- deleted', T.get('diff.minus') },
    renamed = { '> renamed', T.get('diff.delta.moved') },
  }
  local p = Picker.open({
    columns = {
      { name = 'change', format = function(c) return { styles[c.kind] or { c.kind, nil } } end },
      {
        name = 'path',
        format = function(c)
          return c.path:sub(1, #cwd + 1) == cwd .. '/' and c.path:sub(#cwd + 2) or c.path
        end,
      },
    },
    primary = 2,
    on_select = function(c, action)
      pcall(E.open, c.path, action)
    end,
    preview = function(c)
      return { path = c.path }
    end,
  })
  p.running = true
  require('hx.git').changed_files(cwd, function(items)
    p.running = false
    p:inject(items)
    p:schedule_render()
  end)
end

function M.last_picker()
  if not Picker.reopen_last() then
  end
end

function M.global_search(regname)
  local cwd = vim.fn.getcwd()
  local smart = S.config.editor.search['smart-case'] ~= false
  Picker.open({
    columns = {
      { name = 'path', format = function(r) return stylize(r.rel, r.line_start) end },
      { name = 'contents', format = function(r) return '' end, hidden = true },
    },
    primary = 2,
    history_register = regname,
    on_select = function(r, action)
      local buf = E.open(r.path, action)
      if not buf then return end
      local text = E.text()
      if r.line_start >= text:len_lines() then
        S.set_status('The line you jumped to does not exist anymore because the file has changed.', 'error')
        return
      end
      local s = text:line_start(r.line_start)
      local e = text:line_start(math.min(r.line_end + 1, text:len_lines()))
      E.set_sel(SL.Selection.single(s, e))
      require('hx.cmd.view_util').align_view(E.win(), 'center')
    end,
    preview = function(r)
      return { path = r.path, range = { r.line_start, r.line_end } }
    end,
    dynamic = {
      debounce = 275,
      fn = function(query, inject, done)
        if query == '' then
          done()
          return
        end
        local RE = require('hx.regex')
        local ci = smart and not query:find('%u')
        local regex, err = RE.new(query, { ci = ci })
        if not regex then
          done('Failed to compile regex')
          return
        end
        S.clear_status()
        local skip = {}
        local results = {}
        for _, b in ipairs(E.documents()) do
          local name = api.nvim_buf_get_name(b)
          if name ~= '' and name:sub(1, #cwd + 1) == cwd .. '/' and api.nvim_buf_is_loaded(b) then
            skip[#skip + 1] = name
            local text = require('hx.text').get(b)
            local subject = text:all()
            local seen = {}
            for s, e in regex:find_iter(subject, 0, #subject) do
              local ls = text:line_of(s)
              local le = text:line_of(math.max(s, e - 1))
              if not seen[ls] then
                seen[ls] = true
                results[#results + 1] = { path = name, rel = rel(name), line_start = ls, line_end = le }
              end
            end
          end
        end
        if #results > 0 then inject(results) end
        local skipset = {}
        for _, sk in ipairs(skip) do
          skipset[sk] = true
        end
        local handle
        handle = W.grep(cwd, { re = regex, multiline = query:find('\\n') ~= nil },
          W.opts_from(S.config.editor['file-picker']), skipset, function(items)
            for _, it in ipairs(items) do
              it.rel = rel(it.path)
            end
            if inject(items) == false then handle.cancel() end
          end, function()
            done(nil)
          end)
      end,
    },
  })
end

function M.command_palette()
  local KM = require('hx.keymap')
  local K = require('hx.keys')
  local rev = KM.reverse(S.mode)
  local items = {}
  for _, e in ipairs(require('hx.command_docs')) do
    items[#items + 1] = { kind = 'static', name = e[1], doc = e[2] }
  end
  for _, c in ipairs(require('hx.typed').list) do
    items[#items + 1] = { kind = 'typed', name = c.name, doc = c.doc }
  end
  local ctx_count = require('hx.input').view.count
  local ctx_reg = require('hx.input').view.register
  Picker.open({
    columns = {
      { name = 'name', format = function(it) return it.kind == 'typed' and (':' .. it.name) or it.name end },
      {
        name = 'bindings',
        format = function(it)
          local b = rev[it.kind == 'typed' and (':' .. it.name) or it.name]
          if not b then return '' end
          local out = {}
          for _, seq in ipairs(b) do
            local s = ''
            for _, k in ipairs(seq) do
              s = s .. K.seq_format(k)
            end
            out[#out + 1] = s
          end
          return table.concat(out, ' ')
        end,
      },
      { name = 'doc', format = function(it) return (it.doc:gsub('\n.*', '')) end },
    },
    primary = 1,
    items = items,
    truncate_start = false,
    on_select = function(it)
      local ctx = require('hx.input').new_ctx()
      ctx.count = ctx_count
      ctx.register = ctx_reg
      if it.kind == 'typed' then
        require('hx.typed').execute_line(it.name, ctx)
      else
        require('hx.input').exec_cmd(it.name, ctx)
      end
    end,
  })
end

local function lsp_or_syntax(kind)
  local L = require('hx.lsp')
  local feature = kind == 'doc' and 'document_symbols' or 'workspace_symbols'
  if L.has_feature(E.buf(), feature) then
    if kind == 'doc' then
      require('hx.lsp.commands').symbol_picker()
    else
      require('hx.lsp.commands').workspace_symbol_picker()
    end
  elseif kind == 'doc' and require('hx.syntax').has_tree(E.buf()) then
    M.syntax_symbol_picker()
  elseif kind == 'doc' then
    S.set_status('No language server supporting document symbols or syntax info available', 'error')
  else
    M.syntax_workspace_symbol_picker()
  end
end
function M.lsp_or_syntax_symbol_picker() lsp_or_syntax('doc') end
function M.lsp_or_syntax_workspace_symbol_picker() lsp_or_syntax('ws') end
function M.symbol_picker() require('hx.lsp.commands').symbol_picker() end
function M.workspace_symbol_picker() require('hx.lsp.commands').workspace_symbol_picker() end

function M.syntax_symbol_picker()
  local buf = E.buf()
  local Syn = require('hx.syntax')
  local root, lang = Syn.root(buf)
  if not root then
    S.set_status('Syntax tree is not available', 'error')
    return
  end
  local q = Syn.get_query(lang, 'tags')
  if not q then
    S.set_status('Syntax-based symbols information not available', 'error')
    return
  end
  local text = require('hx.text').get(buf)
  local items = {}
  for _, match in q:iter_matches(root, buf, 0, -1, { all = true }) do
    local name_node, def_node, kind
    for id, nodes in pairs(match) do
      local cap = q.captures[id]
      if cap == 'name' then
        name_node = nodes[1]
      elseif cap:match('^definition%.') then
        def_node = nodes[1]
        kind = cap:gsub('^definition%.', '')
      end
    end
    if name_node and def_node then
      local _, _, ns, _, _, ne = name_node:range(true)
      items[#items + 1] = { name = text:slice(ns, ne), kind = kind, start = ns, ['end'] = ne,
        line = text:line_of(ns) }
    end
  end
  Picker.open({
    columns = {
      { name = 'kind', format = function(s) return s.kind end },
      { name = 'name', format = function(s) return s.name end },
    },
    primary = 2,
    items = items,
    on_select = function(s)
      require('hx.doc').push_jump()
      E.set_sel(SL.Selection.single(s.start, s['end']))
      require('hx.cmd.view_util').align_view(E.win(), 'center')
    end,
    preview = function(s)
      return { buf = buf, range = { s.line, s.line } }
    end,
  })
end

function M.syntax_workspace_symbol_picker()
  S.set_status('Syntax-based workspace symbol search requires the language server', 'error')
end

return M
