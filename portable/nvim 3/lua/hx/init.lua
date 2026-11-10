local api = vim.api
local M = {}

local function root_dir()
  local src = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(src, ':h:h:h')
end
M.root = root_dir()

local function deep_merge(a, b)
  for k, v in pairs(b) do
    if type(v) == 'table' and type(a[k]) == 'table' and v[1] == nil then
      deep_merge(a[k], v)
    else
      a[k] = v
    end
  end
  return a
end

local function load_config()
  local defaults = {
    editor = {
      scrolloff = 5,
      mouse = true,
      ['middle-click-paste'] = true,
      ['scroll-lines'] = 3,
      shell = { 'sh', '-c' },
      ['line-number'] = 'absolute',
      cursorline = false,
      cursorcolumn = false,
      gutters = { 'diagnostics', 'spacer', 'line-numbers', 'spacer', 'diff' },
      ['auto-completion'] = true,
      ['path-completion'] = true,
      ['word-completion'] = { enable = true, ['trigger-length'] = 7 },
      ['auto-format'] = true,
      ['auto-save'] = false,
      ['idle-timeout'] = 250,
      ['completion-timeout'] = 250,
      ['preview-completion-insert'] = true,
      ['completion-trigger-len'] = 2,
      ['completion-replace'] = false,
      ['auto-info'] = true,
      ['true-color'] = false,
      rulers = {},
      bufferline = 'never',
      ['color-modes'] = false,
      ['text-width'] = 80,
      ['default-line-ending'] = 'native',
      ['insert-final-newline'] = true,
      ['trim-final-newlines'] = false,
      ['trim-trailing-whitespace'] = false,
      ['popup-border'] = 'none',
      ['indent-heuristic'] = 'hybrid',
      ['jump-label-alphabet'] = 'abcdefghijklmnopqrstuvwxyz',
      ['end-of-line-diagnostics'] = 'disable',
      ['continue-comments'] = true,
      ['default-yank-register'] = '"',
      ['auto-pairs'] = true,
      lsp = { enable = true, ['display-messages'] = true, ['display-progress-messages'] = false,
        ['auto-signature-help'] = true, ['display-signature-help-docs'] = true,
        ['display-inlay-hints'] = false, ['display-color-swatches'] = true, snippets = true,
        ['goto-reference-include-declaration'] = true },
      ['cursor-shape'] = { normal = 'block', insert = 'block', select = 'block' },
      ['file-picker'] = { hidden = true, ['follow-symlinks'] = true, ['deduplicate-links'] = true,
        parents = true, ignore = true, ['git-ignore'] = true, ['git-global'] = true,
        ['git-exclude'] = true },
      statusline = {
        left = { 'mode', 'spinner', 'file-name', 'read-only-indicator', 'file-modification-indicator' },
        center = {},
        right = { 'diagnostics', 'selections', 'register', 'position', 'file-encoding' },
        separator = '│',
        mode = { normal = 'NOR', insert = 'INS', select = 'SEL' },
        diagnostics = { 'warning', 'error' },
        ['workspace-diagnostics'] = { 'warning', 'error' },
      },
      search = { ['smart-case'] = true, ['wrap-around'] = true },
      whitespace = { render = 'none' },
      ['indent-guides'] = { render = false, character = '│', ['skip-levels'] = 0 },
      ['soft-wrap'] = { enable = false, ['max-wrap'] = 20, ['max-indent-retain'] = 40,
        ['wrap-indicator'] = '↪ ', ['wrap-at-text-width'] = false },
      ['smart-tab'] = { enable = true, ['supersede-menu'] = false },
      ['inline-diagnostics'] = { ['cursor-line'] = 'disable', ['other-lines'] = 'disable',
        ['min-diagnostic-width'] = 40, ['prefix-len'] = 1, ['max-wrap'] = 20, ['max-diagnostics'] = 10 },
    },
  }
  local user = dofile(M.root .. '/lua/hx/config.lua')
  local cfg = deep_merge(defaults, { editor = user.editor })
  cfg.keys = user.keys
  cfg.cursorline = cfg.editor.cursorline
  return cfg
end

local function set_options()
  local o = vim.o
  local cfg = require('hx.state').config.editor
  o.termguicolors = true
  o.mouse = cfg.mouse and 'a' or ''
  o.mousemodel = 'extend'
  o.scrolloff = cfg.scrolloff
  o.sidescrolloff = 0
  o.number = false
  o.relativenumber = false
  o.signcolumn = 'no'
  o.foldcolumn = '0'
  o.statuscolumn = '%!v:lua.hx_statuscolumn()'
  o.cursorline = false
  o.wrap = cfg['soft-wrap'].enable
  o.linebreak = true
  o.breakindent = true
  o.breakindentopt = 'min:20,shift:0'
  o.showbreak = cfg['soft-wrap']['wrap-indicator']
  o.smoothscroll = true
  o.virtualedit = 'onemore'
  o.showmode = false
  o.ruler = false
  o.showcmd = false
  o.laststatus = 2
  o.statusline = '%!v:lua.hx_statusline()'
  o.showtabline = cfg.bufferline == 'never' and 0 or 2
  o.tabline = '%!v:lua.hx_bufferline()'
  o.cmdheight = 1
  o.fillchars = 'eob: ,vert:│,horiz:─,horizup:┴,horizdown:┬,vertleft:┤,vertright:├,verthoriz:┼,fold: ,diff: ,msgsep: ,lastline: '
  o.list = false
  o.timeout = false
  o.ttimeout = true
  o.ttimeoutlen = 10
  o.shortmess = 'filnxtToOFIcCsWS'
  o.splitbelow = true
  o.splitright = true
  o.equalalways = true
  o.hidden = true
  o.swapfile = false
  o.writebackup = false
  o.backup = false
  o.undofile = false
  o.undolevels = 10000
  o.updatetime = cfg['idle-timeout']
  o.completeopt = ''
  o.wildmenu = false
  o.hlsearch = false
  o.incsearch = false
  o.ignorecase = false
  o.smartcase = false
  o.matchpairs = ''
  o.showmatch = false
  o.whichwrap = ''
  o.belloff = 'all'
  o.errorbells = false
  o.visualbell = false
  o.report = 99999
  o.more = false
  o.confirm = false
  o.autoread = true
  o.title = true
  o.titlestring = 'hx - %t'
  o.startofline = false
  o.jumpoptions = ''
  o.fixendofline = cfg['insert-final-newline']
  o.endofline = true
  o.expandtab = true
  o.tabstop = 4
  o.shiftwidth = 4
  o.softtabstop = 0
  o.autoindent = false
  o.smartindent = false
  o.formatoptions = ''
  o.textwidth = 0
  o.modeline = false
  o.spell = false
  o.conceallevel = 0
  vim.g.loaded_matchparen = 1
  vim.g.loaded_netrwPlugin = 1
  vim.g.loaded_netrw = 1
  vim.g.loaded_2html_plugin = 1
  vim.g.loaded_tutor_mode_plugin = 1
  vim.g.loaded_remote_plugins = 1
  vim.g.loaded_gzip = 1
  vim.g.loaded_tarPlugin = 1
  vim.g.loaded_zipPlugin = 1
  vim.g.loaded_spellfile_plugin = 1
  vim.g.loaded_man = 1
  vim.g.editorconfig = true
  vim.g.lsp_auto_attach = false
  vim.g.python_recommended_style = 0
  vim.g.no_plugin_maps = 1
  vim.g.no_python_maps = 1
end

local function window_options(win)
  if not api.nvim_win_is_valid(win) then return end
  if api.nvim_win_get_config(win).relative ~= '' then return end
  vim.wo[win].winhighlight = 'Normal:HxText,NormalNC:HxText,EndOfBuffer:HxBackground,'
    .. 'StatusLine:HxStatusline,StatusLineNC:HxStatuslineInactive,WinSeparator:HxWindow,'
    .. 'LineNr:HxLinenr,CursorLineNr:HxLinenr,SignColumn:HxBackground,NonText:HxBackground'
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldenable = false
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].statuscolumn = '%!v:lua.hx_statuscolumn()'
end
M.window_options = window_options

local function autocmds()
  local g = api.nvim_create_augroup('hx', { clear = true })
  local S = require('hx.state')
  api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'WinNew', 'WinEnter' }, {
    group = g,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      window_options(win)
      if api.nvim_win_get_config(win).relative == '' then
        require('hx.ui.compositor').set_editor_win(win)
      end
      require('hx.doc').attach(ev.buf)
    end,
  })
  api.nvim_create_autocmd('FileType', {
    group = g,
    callback = function(ev)
      require('hx.syntax').attach(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = g,
    callback = function(ev)
      require('hx.doc').attach(ev.buf)
      require('hx.events').doc_opened(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ 'BufWritePost' }, {
    group = g,
    callback = function(ev)
      require('hx.diff').reload(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ 'VimResized' }, {
    group = g,
    callback = function()
      require('hx.input').after_key()
    end,
  })
  api.nvim_create_autocmd('ColorScheme', {
    group = g,
    callback = function()
      if vim.g.colors_name ~= 'spacemacs' then require('hx.theme').setup() end
    end,
  })
  api.nvim_create_autocmd({ 'WinClosed' }, {
    group = g,
    callback = function(ev)
      local w = tonumber(ev.match)
      if w then S.views[w] = nil end
      vim.schedule(function()
        require('hx.input').after_key()
      end)
    end,
  })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufModifiedSet' }, {
    group = g,
    callback = function()
      pcall(vim.cmd.redrawtabline)
    end,
  })
  api.nvim_create_autocmd('ModeChanged', {
    group = g,
    callback = function()
      local m = api.nvim_get_mode().mode
      if m:sub(1, 1) == 'i' or m:sub(1, 1) == 'v' or m:sub(1, 1) == 'V' or m == '\22' or m:sub(1, 1) == 'R' then
        vim.schedule(function()
          local cur = api.nvim_get_mode().mode
          if cur ~= 'n' and cur:sub(1, 1) ~= 'c' and cur ~= 't' then
            api.nvim_feedkeys(api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 'n', false)
          end
        end)
      end
    end,
  })
end

function M.setup()
  local S = require('hx.state')
  S.config = load_config()
  require('hx.ui.statusline')
  require('hx.ui.bufferline')
  require('hx.ui.gutter')
  set_options()
  require('hx.theme').setup()
  require('hx.syntax').setup(M.root)
  require('hx.languages').setup_filetypes()
  require('hx.keymap').build(S.config.keys)
  require('hx.render').setup()
  require('hx.input').setup()
  require('hx.input').setup_paste()
  require('hx.decorations').setup()
  autocmds()
  S.enabled = true
  pcall(function()
    require('hx.lsp').setup()
  end)
  pcall(function()
    require('hx.plugins').setup()
  end)
  vim.schedule(function()
    for _, w in ipairs(api.nvim_list_wins()) do
      window_options(w)
    end
    local buf = api.nvim_get_current_buf()
    require('hx.doc').attach(buf)
    if vim.bo[buf].filetype ~= '' then require('hx.syntax').attach(buf) end
    require('hx.input').after_key()
  end)
end

return M
