local api = vim.api
local S = require('hx.state')
local L = require('hx.languages')

local M = {}

M.clients = {}

local function find_root(buf, markers)
  local name = api.nvim_buf_get_name(buf)
  local start = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  local ws = require('hx.editor').find_workspace()
  local dir = start
  while dir and dir ~= '' do
    for _, m in ipairs(markers or {}) do
      if vim.uv.fs_stat(dir .. '/' .. m) then return dir end
    end
    if dir == ws then break end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then break end
    dir = parent
  end
  return ws
end

local function capabilities()
  local caps = vim.lsp.protocol.make_client_capabilities()
  local td = caps.textDocument
  td.completion.completionItem.snippetSupport = S.config.editor.lsp.snippets ~= false
  td.completion.completionItem.resolveSupport = {
    properties = { 'documentation', 'detail', 'additionalTextEdits' },
  }
  td.completion.completionItem.insertReplaceSupport = true
  td.completion.completionItem.deprecatedSupport = true
  td.completion.completionItem.tagSupport = { valueSet = { 1 } }
  td.completion.completionItem.labelDetailsSupport = false
  td.signatureHelp.signatureInformation.activeParameterSupport = true
  td.inlayHint = { dynamicRegistration = false, resolveSupport = { properties = {} } }
  caps.window = caps.window or {}
  caps.window.workDoneProgress = true
  caps.general = caps.general or {}
  caps.general.positionEncodings = { 'utf-8', 'utf-32', 'utf-16' }
  return caps
end

local spinner_frames = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' }
local progress = {}
local spin_timer

local function ensure_spinner()
  if spin_timer then return end
  spin_timer = vim.uv.new_timer()
  spin_timer:start(80, 80, vim.schedule_wrap(function()
    local any = false
    for _, n in pairs(progress) do
      if n > 0 then any = true end
    end
    if not any then
      spin_timer:stop()
      spin_timer:close()
      spin_timer = nil
    end
    pcall(vim.cmd.redrawstatus, { bang = true })
  end))
end

function M.spinner_frame(buf)
  for _, id in ipairs(M.clients[buf] or {}) do
    if (progress[id] or 0) > 0 then
      local i = math.floor(vim.uv.now() / 80) % #spinner_frames + 1
      return spinner_frames[i]
    end
  end
  return nil
end

local function handlers()
  return {
    ['$/progress'] = function(_, result, ctx)
      local v = result and result.value
      if not v then return end
      local id = ctx.client_id
      if v.kind == 'begin' then
        progress[id] = (progress[id] or 0) + 1
        ensure_spinner()
      elseif v.kind == 'end' then
        progress[id] = math.max(0, (progress[id] or 1) - 1)
      end
      if S.config.editor.lsp['display-progress-messages'] then
        local client = vim.lsp.get_client_by_id(id)
        local title = v.title or ''
        local msg = v.message or ''
        local pct = v.percentage and (v.percentage .. '%') or ''
        S.set_status(('[%s] %s %s %s'):format(client and client.name or '?', title, pct, msg))
      end
    end,
    ['window/showMessage'] = function(_, result, ctx)
      if not S.config.editor.lsp['display-messages'] then return end
      local t = result.type
      S.set_status(result.message, t == 1 and 'error' or (t == 2 and 'warning' or 'info'))
      require('hx.ui.cmdline').render()
    end,
    ['window/logMessage'] = function() end,
    ['textDocument/publishDiagnostics'] = function(err, result, ctx)
      vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx)
      require('hx.lsp.diagnostics').changed()
    end,
    ['textDocument/diagnostic'] = function(err, result, ctx)
      vim.lsp.diagnostic.on_diagnostic(err, result, ctx)
      require('hx.lsp.diagnostics').changed()
    end,
    ['workspace/applyEdit'] = function(_, params, ctx)
      local client = vim.lsp.get_client_by_id(ctx.client_id)
      local ok = pcall(require('hx.lsp.util').apply_workspace_edit, params.edit, client.offset_encoding)
      return { applied = ok }
    end,
  }
end

function M.attach(buf)
  if not S.config.editor.lsp.enable then return end
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then return end
  local name = api.nvim_buf_get_name(buf)
  if name == '' then return end
  local servers = L.servers_for(buf)
  if #servers == 0 then return end
  local lang = L.language[vim.bo[buf].filetype]
  local root = find_root(buf, lang and lang.roots)
  local ids = {}
  for _, sname in ipairs(servers) do
    local def = L.language_server[sname]
    if def and vim.fn.executable(def.command) == 1 then
      local cmd = { def.command }
      vim.list_extend(cmd, def.args or {})
      local id = vim.lsp.start({
        name = sname,
        cmd = cmd,
        root_dir = root,
        workspace_folders = { { uri = vim.uri_from_fname(root), name = root } },
        settings = def.config or vim.empty_dict(),
        init_options = def.config,
        capabilities = capabilities(),
        handlers = handlers(),
        flags = { debounce_text_changes = 0 },
        on_init = function(client)
          if def.config then
            client:notify('workspace/didChangeConfiguration', { settings = def.config })
          end
        end,
      }, { bufnr = buf, reuse_client = function(client, config)
        return client.name == config.name and client.root_dir == config.root_dir
      end })
      if id then ids[#ids + 1] = id end
    end
  end
  M.clients[buf] = ids
end

function M.doc_opened(buf)
  M.attach(buf)
end

function M.buf_clients(buf)
  local out = {}
  for _, id in ipairs(M.clients[buf] or {}) do
    local c = vim.lsp.get_client_by_id(id)
    if c and not c:is_stopped() then out[#out + 1] = c end
  end
  return out
end

local feature_caps = {
  completion = 'completionProvider',
  hover = 'hoverProvider',
  signature_help = 'signatureHelpProvider',
  goto_definition = 'definitionProvider',
  goto_declaration = 'declarationProvider',
  goto_type_definition = 'typeDefinitionProvider',
  goto_implementation = 'implementationProvider',
  goto_reference = 'referencesProvider',
  document_highlight = 'documentHighlightProvider',
  document_symbols = 'documentSymbolProvider',
  workspace_symbols = 'workspaceSymbolProvider',
  code_action = 'codeActionProvider',
  rename = 'renameProvider',
  format = 'documentFormattingProvider',
  range_format = 'documentRangeFormattingProvider',
  inlay_hints = 'inlayHintProvider',
  workspace_command = 'executeCommandProvider',
}

local feature_methods = {
  completion = 'textDocument/completion',
  hover = 'textDocument/hover',
  signature_help = 'textDocument/signatureHelp',
  goto_definition = 'textDocument/definition',
  goto_declaration = 'textDocument/declaration',
  goto_type_definition = 'textDocument/typeDefinition',
  goto_implementation = 'textDocument/implementation',
  goto_reference = 'textDocument/references',
  document_highlight = 'textDocument/documentHighlight',
  document_symbols = 'textDocument/documentSymbol',
  workspace_symbols = 'workspace/symbol',
  code_action = 'textDocument/codeAction',
  rename = 'textDocument/rename',
  format = 'textDocument/formatting',
  range_format = 'textDocument/rangeFormatting',
  inlay_hints = 'textDocument/inlayHint',
  workspace_command = 'workspace/executeCommand',
}

local function supports(client, feature, buf)
  local cap = feature_caps[feature]
  if not cap then return false end
  local v = client.server_capabilities[cap]
  if v ~= nil and v ~= false then return true end
  local method = feature_methods[feature]
  if method and client.dynamic_capabilities then
    local ok, reg = pcall(function()
      return client.dynamic_capabilities:get(method, { bufnr = buf })
    end)
    if ok and reg ~= nil then return true end
  end
  return false
end
M.supports = supports

function M.with_feature(buf, feature)
  local out = {}
  for _, c in ipairs(M.buf_clients(buf)) do
    if supports(c, feature, buf) then out[#out + 1] = c end
  end
  return out
end

function M.has_feature(buf, feature)
  return #M.with_feature(buf, feature) > 0
end

function M.position(buf, pos, client)
  local text = require('hx.text').get(buf)
  local row = text:line_of(pos)
  local col = pos - text:line_start(row)
  if row >= text.nlines then
    row = math.max(0, text.nlines - 1)
    col = #text:line(row)
  end
  local line = text:line(row)
  local enc = client.offset_encoding or 'utf-16'
  local character = col
  if enc ~= 'utf-8' then character = vim.str_utfindex(line, enc, math.min(col, #line), false) end
  return { line = row, character = character }
end

function M.doc_identifier(buf)
  return { uri = vim.uri_from_bufnr(buf) }
end

function M.request(client, method, params, buf, cb)
  return client:request(method, params, function(err, result)
    cb(err, result)
  end, buf)
end

function M.did_save(buf)
end

function M.restart(args)
  local buf = require('hx.editor').buf()
  local names = {}
  for _, a in ipairs(args or {}) do
    names[a] = true
  end
  for _, c in ipairs(M.buf_clients(buf)) do
    if #args == 0 or names[c.name] then c:stop() end
  end
  vim.defer_fn(function()
    M.attach(buf)
  end, 500)
end

function M.stop(args)
  local buf = require('hx.editor').buf()
  local names = {}
  for _, a in ipairs(args or {}) do
    names[a] = true
  end
  for _, c in ipairs(M.buf_clients(buf)) do
    if #args == 0 or names[c.name] then c:stop() end
  end
end

function M.workspace_command(args)
  local buf = require('hx.editor').buf()
  local clients = M.with_feature(buf, 'workspace_command')
  if #clients == 0 then error('No configured language server supports workspace commands') end
  if #args == 0 then
    local items = {}
    for _, c in ipairs(clients) do
      for _, cmd in ipairs(c.server_capabilities.executeCommandProvider.commands or {}) do
        items[#items + 1] = { cmd = cmd, client = c }
      end
    end
    require('hx.ui.picker').open({
      columns = { { name = 'command', format = function(it) return it.cmd end } },
      items = items,
      on_select = function(it)
        it.client:request('workspace/executeCommand', { command = it.cmd }, function() end, buf)
      end,
    })
    return
  end
  local cmd = args[1]
  local rest = {}
  for i = 2, #args do
    local ok, v = pcall(vim.json.decode, args[i])
    rest[#rest + 1] = ok and v or args[i]
  end
  for _, c in ipairs(clients) do
    for _, name in ipairs(c.server_capabilities.executeCommandProvider.commands or {}) do
      if name == cmd then
        c:request('workspace/executeCommand', { command = cmd, arguments = rest }, function() end, buf)
        return
      end
    end
  end
  error(("No language server supports the command '%s'"):format(cmd))
end

function M.setup()
  vim.diagnostic.config({ virtual_text = false, virtual_lines = false, signs = false, underline = false,
    update_in_insert = true, severity_sort = true, float = false })
  api.nvim_create_autocmd('LspAttach', {
    callback = function(ev)
      pcall(vim.keymap.del, 'n', 'K', { buffer = ev.buf })
      vim.bo[ev.buf].omnifunc = ''
      vim.bo[ev.buf].tagfunc = ''
      vim.bo[ev.buf].formatexpr = ''
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client then client.server_capabilities.semanticTokensProvider = nil end
      pcall(function()
        vim.lsp.document_color.enable(false, ev.buf)
      end)
      pcall(function()
        vim.lsp.inlay_hint.enable(false, { bufnr = ev.buf })
      end)
    end,
  })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'FileType' }, {
    callback = function(ev)
      vim.schedule(function()
        M.attach(ev.buf)
      end)
    end,
  })
  require('hx.lsp.inlay').setup()
  require('hx.lsp.diagnostics').setup()
end

return M
