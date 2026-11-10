local api = vim.api
local S = require('hx.state')
local Text = require('hx.text')
local SL = require('hx.selection')
local LU = require('hx.lsp.util')

local M = {}

local function Lsp()
  return require('hx.lsp')
end
local function E()
  return require('hx.editor')
end

local function err(msg)
  S.set_status(msg, 'error')
  require('hx.ui.cmdline').render()
end

local function status(msg)
  S.set_status(msg)
  require('hx.ui.cmdline').render()
end

local function after_async()
  local C = require('hx.ui.compositor')
  require('hx.input').after_key()
  C.render_all()
  pcall(vim.cmd, 'redraw')
end

local function doc_position(buf, client)
  local text = Text.get(buf)
  local cursor = E().sel():prim():cursor(text)
  return LU.pos_to_lsp_pos(text, cursor, client.offset_encoding or 'utf-16')
end

local function gather(clients, method, params_fn, buf, cb)
  local pending = #clients
  local results = {}
  if pending == 0 then
    vim.schedule(function()
      cb(results)
    end)
    return
  end
  for _, client in ipairs(clients) do
    local ok = client:request(method, params_fn(client), function(e, result)
      results[#results + 1] = { client = client, result = result, err = e }
      pending = pending - 1
      if pending == 0 then cb(results) end
    end, buf)
    if not ok then
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          cb(results)
        end)
      end
    end
  end
end

local function dedupe(clients)
  local seen, out = {}, {}
  for _, c in ipairs(clients) do
    if not seen[c.id] then
      seen[c.id] = true
      out[#out + 1] = c
    end
  end
  return out
end

local function location_to_item(loc, enc)
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetRange
  if not uri or not range then return nil end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if not ok then return nil end
  return { uri = uri, path = path, range = range, encoding = enc }
end

local function jump_to_location(loc, action)
  LU.jump_to_location(loc.path, loc.range, loc.encoding, action or 'replace')
end
M.jump_to_location = jump_to_location

local function goto_impl(locations)
  if #locations == 1 then
    jump_to_location(locations[1], 'replace')
    after_async()
    return
  end
  local cwd = vim.fn.getcwd()
  require('hx.ui.picker').open({
    columns = {
      {
        name = 'location',
        format = function(l)
          local p = l.path
          if p:sub(1, #cwd + 1) == cwd .. '/' then p = p:sub(#cwd + 2) end
          return ('%s:%d'):format(p, l.range.start.line + 1)
        end,
      },
    },
    primary = 1,
    items = locations,
    on_select = function(l, action)
      jump_to_location(l, action)
    end,
    preview = function(l)
      return { path = l.path, range = { l.range.start.line, l.range['end'].line } }
    end,
  })
end

local NOT_FOUND = {
  goto_declaration = 'No declaration found.',
  goto_definition = 'No definition found.',
  goto_type_definition = 'No type definition found.',
  goto_implementation = 'No implementation found.',
}
local METHOD = {
  goto_declaration = 'textDocument/declaration',
  goto_definition = 'textDocument/definition',
  goto_type_definition = 'textDocument/typeDefinition',
  goto_implementation = 'textDocument/implementation',
}

local function goto_single_impl(feature)
  local buf = E().buf()
  local clients = Lsp().with_feature(buf, feature)
  gather(clients, METHOD[feature], function(client)
    return { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = doc_position(buf, client) }
  end, buf, function(results)
    local locations = {}
    for _, r in ipairs(results) do
      local enc = r.client.offset_encoding or 'utf-16'
      local res = r.result
      if res and not r.err then
        if res.uri or res.targetUri then res = { res } end
        for _, loc in ipairs(res) do
          if loc.targetUri then loc = { uri = loc.targetUri, range = loc.targetRange } end
          local it = location_to_item(loc, enc)
          if it then locations[#locations + 1] = it end
        end
      end
    end
    if #locations == 0 then
      err(NOT_FOUND[feature] or 'No location found.')
    else
      goto_impl(locations)
    end
  end)
end

function M.goto_declaration()
  goto_single_impl('goto_declaration')
end
function M.goto_definition()
  goto_single_impl('goto_definition')
end
function M.goto_type_definition()
  goto_single_impl('goto_type_definition')
end
function M.goto_implementation()
  goto_single_impl('goto_implementation')
end

function M.goto_reference()
  local buf = E().buf()
  local include = S.config.editor.lsp['goto-reference-include-declaration']
  if include == nil then include = true end
  local clients = Lsp().with_feature(buf, 'goto_reference')
  gather(clients, 'textDocument/references', function(client)
    return {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = doc_position(buf, client),
      context = { includeDeclaration = include },
    }
  end, buf, function(results)
    local locations = {}
    for _, r in ipairs(results) do
      local enc = r.client.offset_encoding or 'utf-16'
      for _, loc in ipairs((not r.err and r.result) or {}) do
        local it = location_to_item(loc, enc)
        if it then locations[#locations + 1] = it end
      end
    end
    if #locations == 0 then
      err('No references found.')
    else
      goto_impl(locations)
    end
  end)
end

function M.signature_help()
  require('hx.lsp.signature').trigger('manual')
end

local Hover = {}
Hover.__index = Hover

local function marked_string(c)
  if type(c) == 'string' then return c end
  if c.language then
    if c.language == 'markdown' then return c.value end
    return ('```%s\n%s\n```'):format(c.language, c.value)
  end
  return c.value or ''
end

local function hover_contents_to_string(contents)
  if type(contents) == 'string' then return contents end
  if contents.kind then return contents.value end
  if contents.language or contents.value then return marked_string(contents) end
  local parts = {}
  for _, c in ipairs(contents) do
    parts[#parts + 1] = marked_string(c)
  end
  return table.concat(parts, '\n\n')
end

function Hover:has_header()
  return #self.contents > 1
end

function Hover:content()
  return self.contents[self.active + 1]
end

function Hover:required_size(vw, _)
  local Md = require('hx.ui.markdown')
  local Tx = require('hx.ui.text')
  local max_text_width = math.min(math.max(vw - 2, 10), 120)
  local c = self:content()
  local header_w = 0
  if c.header then header_w = Tx.required_size(Md.parse(c.header, false), max_text_width) end
  local cw, ch = Tx.required_size(Md.parse(c.body, false), max_text_width)
  local w = 2 + math.max(header_w, cw)
  local h = self:has_header() and (1 + 1 + 1 + ch + 1) or (1 + ch + 1)
  return w, h
end

function Hover:render(cv, x, y, w, h, scroll)
  local T = require('hx.theme')
  local Md = require('hx.ui.markdown')
  local Tx = require('hx.ui.text')
  x, y, w, h = x + 1, y + 1, math.max(0, w - 2), math.max(0, h - 2)
  if w <= 0 or h <= 0 then return end
  local base = T.group_for(T.get('ui.popup'))
  local c = self:content()
  if c.header then
    local hl = Md.parse(c.header, true)
    local cx = x
    for _, sp in ipairs(hl[1] or {}) do
      cx = cv:put(cx, y, sp[1], sp[2] and T.group_for(sp[2]) or base, x + w - cx)
    end
    for xx = x, x + w - 1 do
      cv:put(xx, y + 1, '─', T.group_for({}))
    end
  end
  local off = self:has_header() and 2 or 0
  if h - off > 0 then Tx.render(cv, x, y + off, w, h - off, Md.parse(c.body, true), scroll, base) end
end

function Hover:handle_key(key)
  if key == 'A-p' then
    self.active = self.active > 0 and self.active - 1 or #self.contents - 1
    return 'consumed'
  elseif key == 'A-n' then
    self.active = (self.active + 1) % #self.contents
    return 'consumed'
  end
  return 'ignored'
end

function M.hover()
  local buf = E().buf()
  local clients = dedupe(Lsp().with_feature(buf, 'hover'))
  if #clients == 0 then
    err('No configured language server supports hover')
    return
  end
  gather(clients, 'textDocument/hover', function(client)
    return { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = doc_position(buf, client) }
  end, buf, function(results)
    local hovers = {}
    for _, r in ipairs(results) do
      if not r.err and r.result and r.result.contents then hovers[#hovers + 1] = { r.client.name, r.result } end
    end
    if #hovers == 0 then
      status('No hover results available.')
      return
    end
    local contents = {}
    for i, hv in ipairs(hovers) do
      contents[i] = {
        header = #hovers > 1 and ('**[%d/%d] %s**'):format(i, #hovers, hv[1]) or nil,
        body = hover_contents_to_string(hv[2].contents),
      }
    end
    local h = setmetatable({ active = 0, contents = contents }, Hover)
    local Popup = require('hx.ui.popup').Popup
    require('hx.ui.compositor').push(Popup.new('hover', h, { auto_close = true }))
    pcall(vim.cmd, 'redraw')
  end)
end

local function prefill_from_word_boundary(buf)
  local text = Text.get(buf)
  local r = E().sel():prim()
  if r:to() - r:from() > 1 then return text:slice(r:from(), r:to()) end
  local Cmd = require('hx.commands')
  Cmd.load()
  local wr = Cmd.textobject.textobject_word(text, r, true, false)
  return text:slice(wr:from(), wr:to())
end

local function create_rename_prompt(prefill, history_register, client_id)
  local P = require('hx.ui.prompt')
  P.open({
    prompt = 'rename-to:',
    register = history_register,
    line = prefill,
    completer = nil,
    callback = function(input, event)
      if event ~= 'validate' then return end
      local buf = E().buf()
      local client
      for _, c in ipairs(Lsp().with_feature(buf, 'rename')) do
        if not client_id or c.id == client_id then
          client = c
          break
        end
      end
      if not client then
        err('No configured language server supports symbol renaming')
        return
      end
      local enc = client.offset_encoding or 'utf-16'
      local res = client:request_sync('textDocument/rename', {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = doc_position(buf, client),
        newName = input,
      }, 10000, buf)
      if not res then
        err('request timed out')
      elseif res.err then
        err(res.err.message or tostring(res.err))
      elseif res.result then
        pcall(LU.apply_workspace_edit, res.result, enc)
      end
    end,
  })
end

function M.rename_symbol(ctx)
  local buf = E().buf()
  local clients = Lsp().with_feature(buf, 'rename')
  if #clients == 0 then
    err('No configured language server supports symbol renaming')
    return
  end
  local history_register = ctx and ctx.register
  local prep
  for _, c in ipairs(clients) do
    local rp = c.server_capabilities.renameProvider
    if type(rp) == 'table' and rp.prepareProvider == true then
      prep = c
      break
    end
  end
  if prep then
    local enc = prep.offset_encoding or 'utf-16'
    prep:request('textDocument/prepareRename', {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = doc_position(buf, prep),
    }, function(e, result)
      local prefill
      if e or result == nil or result == vim.NIL then
        err('lsp did not respond to prepare rename request')
        return
      end
      if result.start then
        local r = LU.lsp_range_to_range(Text.get(buf), result, enc)
        if not r then
          err('lsp sent invalid selection range for rename')
          return
        end
        prefill = Text.get(buf):slice(r:from(), r:to())
      elseif result.placeholder then
        prefill = result.placeholder
      elseif result.defaultBehavior then
        prefill = prefill_from_word_boundary(buf)
      elseif result.range then
        local r = LU.lsp_range_to_range(Text.get(buf), result.range, enc)
        prefill = r and Text.get(buf):slice(r:from(), r:to()) or ''
      end
      create_rename_prompt(prefill or '', history_register, prep.id)
      after_async()
    end, buf)
  else
    create_rename_prompt(prefill_from_word_boundary(buf), history_register, nil)
  end
end

local function code_action_priority(action)
  local is_command = type(action.command) == 'string'
  local category = 0
  if not is_command and type(action.kind) == 'string' then
    local comps = vim.split(action.kind, '.', { plain = true })
    local a, b = comps[1], comps[2]
    if a == 'quickfix' then
      category = 7
    elseif a == 'refactor' then
      category = ({ extract = 6, inline = 5, rewrite = 4, move = 3, surround = 2 })[b] or 1
    elseif a == 'source' then
      category = 1
    end
  end
  local fixes = not is_command and type(action.diagnostics) == 'table' and #action.diagnostics > 0
  local preferred = not is_command and action.isPreferred == true
  local p = category * 4
  if fixes then p = p + 2 end
  if preferred then p = p + 1 end
  return p
end

local function execute_lsp_command(client, command)
  client:request('workspace/executeCommand', { command = command.command, arguments = command.arguments },
    function(e)
      if e then err(e.message or tostring(e)) end
    end, E().buf())
end

local function execute_action(it)
  local client = vim.lsp.get_client_by_id(it.client_id)
  if not client then
    err('Language Server disappeared')
    return
  end
  local enc = client.offset_encoding or 'utf-16'
  local a = it.action
  if type(a.command) == 'string' then
    execute_lsp_command(client, a)
    return
  end
  if a.edit == nil or a.command == nil then
    local cap = client.server_capabilities.codeActionProvider
    if type(cap) == 'table' and cap.resolveProvider then
      local res = client:request_sync('codeAction/resolve', a, 5000, E().buf())
      if res and not res.err and res.result then a = res.result end
    end
  end
  if a.edit then pcall(LU.apply_workspace_edit, a.edit, enc) end
  if a.command then execute_lsp_command(client, a.command) end
end

local function diagnostics_in_range(buf, r, client)
  local out = {}
  local text = Text.get(buf)
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local s = text:line_start(math.min(d.lnum, text:len_lines() - 1)) + (d.col or 0)
    local e = text:line_start(math.min(d.end_lnum or d.lnum, text:len_lines() - 1)) + (d.end_col or d.col or 0)
    local dr = SL.R(s, e)
    local overlaps = r:from() == dr:from() or (r:to() > dr:from() and dr:to() > r:from())
    if overlaps then
      local lsp = d.user_data and d.user_data.lsp
      if lsp and d.namespace == vim.lsp.diagnostic.get_namespace(client.id) then
        out[#out + 1] = lsp
      else
        out[#out + 1] = {
          range = LU.range_to_lsp_range(text, dr, client.offset_encoding or 'utf-16'),
          severity = d.severity,
          code = d.code,
          source = d.source,
          message = d.message,
        }
      end
    end
  end
  return out
end

function M.code_action()
  local buf = E().buf()
  local r = E().sel():prim()
  local clients = dedupe(Lsp().with_feature(buf, 'code_action'))
  if #clients == 0 then
    err('No configured language server supports code actions')
    return
  end
  local text = Text.get(buf)
  gather(clients, 'textDocument/codeAction', function(client)
    return {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      range = LU.range_to_lsp_range(text, r, client.offset_encoding or 'utf-16'),
      context = { diagnostics = diagnostics_in_range(buf, r, client), triggerKind = 1 },
    }
  end, buf, function(results)
    local actions = {}
    for _, res in ipairs(results) do
      for _, a in ipairs((not res.err and res.result) or {}) do
        if type(a.command) == 'string' or a.disabled == nil then
          actions[#actions + 1] = { action = a, client_id = res.client.id, priority = code_action_priority(a),
            title = a.title, idx = #actions + 1 }
        end
      end
    end
    table.sort(actions, function(a, b)
      if a.priority ~= b.priority then return a.priority > b.priority end
      return a.idx < b.idx
    end)
    if #actions == 0 then
      err('No code actions available')
      return
    end
    local Menu = require('hx.ui.menu').Menu
    local menu = Menu.new(actions, function(it)
      return { it.title }
    end, function(it, event)
      if event ~= 'validate' then return end
      execute_action(it)
    end)
    menu:move_down()
    local Popup = require('hx.ui.popup').Popup
    local p = Popup.new('code-action', menu, { scrollbar = false, auto_close = true, is_menu = true })
    require('hx.ui.compositor').push(p)
    pcall(vim.cmd, 'redraw')
  end)
end

function M.select_references_to_symbol_under_cursor()
  local buf = E().buf()
  local client = Lsp().with_feature(buf, 'document_highlight')[1]
  if not client then
    err('No configured language server supports document-highlight')
    return
  end
  local enc = client.offset_encoding or 'utf-16'
  client:request('textDocument/documentHighlight', {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = doc_position(buf, client),
  }, function(e, result)
    if e or type(result) ~= 'table' or #result == 0 then return end
    local text = Text.get(buf)
    local pos = E().sel():prim():cursor(text)
    local ranges = {}
    local primary = 1
    for _, h in ipairs(result) do
      local r = LU.lsp_range_to_range(text, h.range, enc)
      if r then
        ranges[#ranges + 1] = r
        if r:from() <= pos and pos < r:to() then primary = #ranges end
      end
    end
    if #ranges == 0 then return end
    require('hx.doc').set_selection(SL.Selection.new(ranges, primary))
    after_async()
  end, buf)
end

local SYMBOL_KIND = {
  'file', 'module', 'namespace', 'package', 'class', 'method', 'property', 'field', 'construct', 'enum',
  'interface', 'function', 'variable', 'constant', 'string', 'number', 'boolean', 'array', 'object', 'key',
  'null', 'enummem', 'struct', 'event', 'operator', 'typeparam',
}

local function symbol_columns(with_path)
  local cols = {
    { name = 'kind', format = function(it) return SYMBOL_KIND[it.symbol.kind] or '' end },
    { name = 'name', format = function(it) return it.symbol.name end, filter = not with_path },
    { name = 'container', format = function(it) return it.symbol.containerName or '' end },
  }
  if with_path then
    cols[#cols + 1] = {
      name = 'path',
      format = function(it)
        if it.location.path then return vim.fn.fnamemodify(it.location.path, ':.') end
        return it.symbol.location and it.symbol.location.uri or ''
      end,
    }
  end
  return cols
end

local function location_preview(it)
  local l = it.location
  return { path = l.path, range = { l.range.start.line, l.range['end'].line } }
end

function M.symbol_picker()
  local buf = E().buf()
  local clients = dedupe(Lsp().with_feature(buf, 'document_symbols'))
  if #clients == 0 then
    err('No configured language server supports document symbols')
    return
  end
  local path = api.nvim_buf_get_name(buf)
  local uri = vim.uri_from_bufnr(buf)
  gather(clients, 'textDocument/documentSymbol', function()
    return { textDocument = { uri = uri } }
  end, buf, function(results)
    local symbols = {}
    local function nested(sym, enc)
      symbols[#symbols + 1] = {
        symbol = { name = sym.name, kind = sym.kind, containerName = nil },
        location = { path = path, uri = uri, range = sym.selectionRange, encoding = enc },
      }
      for _, ch in ipairs(sym.children or {}) do
        nested(ch, enc)
      end
    end
    for _, r in ipairs(results) do
      local enc = r.client.offset_encoding or 'utf-16'
      for _, sym in ipairs((not r.err and r.result) or {}) do
        if sym.location then
          symbols[#symbols + 1] = {
            symbol = sym,
            location = { path = path, uri = uri, range = sym.location.range, encoding = enc },
          }
        else
          nested(sym, enc)
        end
      end
    end
    require('hx.ui.picker').open({
      columns = symbol_columns(false),
      primary = 2,
      items = symbols,
      truncate_start = false,
      on_select = function(it, action)
        jump_to_location(it.location, action)
      end,
      preview = location_preview,
    })
    pcall(vim.cmd, 'redraw')
  end)
end

function M.workspace_symbol_picker()
  local buf = E().buf()
  if #Lsp().with_feature(buf, 'workspace_symbols') == 0 then
    err('No configured language server supports workspace symbols')
    return
  end
  require('hx.ui.picker').open({
    columns = symbol_columns(true),
    primary = 2,
    items = {},
    truncate_start = false,
    on_select = function(it, action)
      jump_to_location(it.location, action)
    end,
    preview = location_preview,
    dynamic = {
      debounce = 100,
      fn = function(query, inject, done)
        local b = E().buf()
        local clients = dedupe(Lsp().with_feature(b, 'workspace_symbols'))
        if #clients == 0 then
          err('No configured language server supports workspace symbols')
          if done then done() end
          return
        end
        gather(clients, 'workspace/symbol', function()
          return { query = query }
        end, b, function(results)
          local batch = {}
          local function inject1(it)
            batch[#batch + 1] = it
          end
          for _, r in ipairs(results) do
            local enc = r.client.offset_encoding or 'utf-16'
            for _, sym in ipairs((not r.err and r.result) or {}) do
              if sym.location and sym.location.range then
                local ok, p = pcall(vim.uri_to_fname, sym.location.uri)
                if ok then
                  inject1({ symbol = sym, location = { path = p, uri = sym.location.uri, range = sym.location.range,
                    encoding = enc } })
                end
              end
            end
          end
          inject(batch)
          if done then done() end
        end)
      end,
    },
  })
end

return M
