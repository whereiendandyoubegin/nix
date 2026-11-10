local M = {}
local api = vim.api

local c = {
  act1 = '#222226', act2 = '#5d4d7a', base = '#b2b2b2', base_dim = '#686868', bg1 = '#292b2e',
  bg2 = '#212026', bg3 = '#100a14', bg4 = '#0a0814', bg_alt = '#42444a', border = '#5d4d7a',
  cblk = '#cbc1d5', cblk_bg = '#2f2b33', cblk_ln = '#827591', cblk_ln_bg = '#373040',
  cursor = '#e3dedd', const = '#a45bad', comment = '#2aa1ae', comment_light = '#2aa1ae',
  comment_bg = '#292e34', comp = '#c56ec3', err = '#e0211d', func = '#bc6ec5', head1 = '#4f97d7',
  head1_bg = '#293239', head2 = '#2d9574', head2_bg = '#293235', head3 = '#67b11d',
  head3_bg = '#293235', head4 = '#b1951d', head4_bg = '#32322c', highlight = '#444155',
  highlight_dim = '#3b314d', keyword = '#4f97d7', lnum = '#44505c', mat = '#86dc2f',
  meta = '#9f8766', str = '#2d9574', suc = '#86dc2f', ttip = '#9a9aba', ttip_sl = '#5e5079',
  ttip_bg = '#34323e', type = '#ce537a', var = '#7590db', war = '#dc752f',
}
M.palette = c

M.styles = {
  ['ui.text'] = { fg = c.base },
  ['ui.selection'] = { bg = c.highlight },
  ['ui.cursor'] = { bg = c.cursor, mods = { reversed = true } },
  ['ui.background'] = { bg = c.bg1, fg = c.base },
  ['constant'] = { fg = c.const },
  ['comment'] = { fg = c.comment, mods = { italic = true } },
  ['function.builtin'] = { fg = c.keyword, mods = { italic = true } },
  ['function'] = { fg = c.func, mods = { italic = true } },
  ['keyword.function'] = { fg = c.keyword },
  ['string'] = { fg = c.str },
  ['error'] = { fg = c.err },
  ['keyword'] = { fg = c.keyword, mods = { italic = true, bold = true } },
  ['ui.cursor.match'] = { fg = c.mat, ul_style = 'line' },
  ['diagnostic.error'] = { ul_style = 'curl', ul_color = c.err },
  ['diagnostic.warning'] = { ul_style = 'curl', ul_color = c.war },
  ['diagnostic.info'] = { ul_style = 'curl', ul_color = c.war },
  ['diagnostic.unnecessary'] = { ul_style = 'curl', ul_color = c.war },
  ['diagnostic.hint'] = { ul_style = 'curl', ul_color = c.war },
  ['type'] = { fg = c.type },
  ['type.builtin'] = { fg = c.type },
  ['variable'] = { fg = c.var },
  ['namespace'] = { fg = c.type },
  ['ui.cursor.primary'] = { mods = { reversed = true } },
  ['ui.cursorline'] = { bg = c.highlight_dim },
}

local EMPTY = {}

function M.try_get(scope)
  local s = scope
  while s do
    local st = M.styles[s]
    if st then return st end
    s = s:match('^(.*)%.[^.]*$')
  end
  return nil
end

function M.get(scope)
  return M.try_get(scope) or EMPTY
end

function M.get_exact(scope)
  return M.styles[scope]
end

function M.patch(a, b)
  if not b then return a end
  local out = { fg = a.fg, bg = a.bg, ul_color = a.ul_color, ul_style = a.ul_style, mods = {} }
  if b.fg then out.fg = b.fg end
  if b.bg then out.bg = b.bg end
  if b.ul_color then out.ul_color = b.ul_color end
  if b.ul_style then out.ul_style = b.ul_style end
  for k, v in pairs(a.mods or EMPTY) do
    out.mods[k] = v
  end
  for k, v in pairs(b.mods or EMPTY) do
    out.mods[k] = v
  end
  return out
end

local function to_hl(st, opts)
  opts = opts or {}
  local hl = {}
  if st.fg then hl.fg = st.fg end
  if st.bg then hl.bg = st.bg end
  if st.ul_color then hl.sp = st.ul_color end
  local m = st.mods or EMPTY
  if m.bold then hl.bold = true end
  if m.italic then hl.italic = true end
  if m.reversed then hl.reverse = true end
  if m.crossed_out then hl.strikethrough = true end
  if m.dim then hl.fg = hl.fg end
  local u = st.ul_style
  if u == 'line' then
    hl.underline = true
  elseif u == 'curl' then
    hl.undercurl = true
  elseif u == 'dashed' then
    hl.underdashed = true
  elseif u == 'dotted' then
    hl.underdotted = true
  elseif u == 'double_line' then
    hl.underdouble = true
  end
  if m.underlined and not u then hl.underline = true end
  if opts.nocombine then hl.nocombine = true end
  return hl
end
M.to_hl = to_hl

local group_cache = {}
local counter = 0

function M.group_for(st, prefix)
  local key = vim.inspect(st)
  local g = group_cache[key]
  if g then return g end
  counter = counter + 1
  g = (prefix or 'HxS') .. counter
  api.nvim_set_hl(0, g, to_hl(st))
  group_cache[key] = g
  return g
end

function M.group(scope)
  return M.group_for(M.get(scope))
end

local function define()
  group_cache = {}
  local set = function(name, st)
    api.nvim_set_hl(0, name, to_hl(st))
  end
  api.nvim_set_hl(0, 'Normal', {})
  local bgs = M.get('ui.background')
  set('HxBackground', bgs)
  set('HxText', M.patch(bgs, M.get('ui.text')))
  set('HxPopupText', M.get('ui.text'))
  set('HxDefault', {})
  set('HxStatusline', M.patch(bgs, M.get('ui.statusline')))
  set('HxStatuslineInactive', M.patch(bgs, M.get('ui.statusline.inactive')))
  set('HxBufferline', M.patch(bgs, M.get('ui.bufferline')))
  set('HxBufferlineActive', M.patch(bgs, M.get('ui.bufferline.active')))
  set('HxCmdline', bgs)
  set('HxSelection', M.get('ui.selection'))
  set('HxSelectionPrimary', M.try_get('ui.selection.primary') or M.get('ui.selection'))
  set('HxCursorline', M.get('ui.cursorline.primary'))
  set('HxCursorlineSecondary', M.get('ui.cursorline.secondary'))
  set('HxCursorMatch', M.get('ui.cursor.match'))
  set('HxLinenr', M.patch(bgs, M.get('ui.linenr')))
  set('HxLinenrSelected', M.patch(bgs, M.get('ui.linenr.selected')))
  set('HxWindow', M.patch(bgs, M.get('ui.window')))
  set('HxVirtualIndentGuide', M.patch(bgs, M.get('ui.virtual.indent-guide')))
  set('HxVirtualWrap', M.get('ui.virtual.wrap'))
  set('HxVirtualWhitespace', M.get('ui.virtual.whitespace'))
  set('HxInlayHint', M.get('ui.virtual.inlay-hint'))
  set('HxInlayHintParameter', M.try_get('ui.virtual.inlay-hint.parameter') or M.get('ui.virtual.inlay-hint'))
  set('HxInlayHintType', M.try_get('ui.virtual.inlay-hint.type') or M.get('ui.virtual.inlay-hint'))
  set('HxJumpLabel', M.get('ui.virtual.jump-label'))
  for _, sev in ipairs({ 'error', 'warning', 'info', 'hint' }) do
    local cap = sev:sub(1, 1):upper() .. sev:sub(2)
    set('HxDiag' .. cap, M.get('diagnostic.' .. sev))
    set('HxSev' .. cap, M.get(sev))
  end
  set('HxDiagUnnecessary', M.get('diagnostic.unnecessary'))
  set('HxDiagDeprecated', M.get('diagnostic.deprecated'))
  set('HxDiffPlus', M.get('diff.plus'))
  set('HxDiffMinus', M.get('diff.minus'))
  set('HxDiffDelta', M.get('diff.delta'))
  api.nvim_set_hl(0, 'HxHiddenCursor', { blend = 100, nocombine = true, reverse = true })
  api.nvim_set_hl(0, 'EndOfBuffer', { link = 'HxBackground' })
  api.nvim_set_hl(0, 'WinSeparator', { link = 'HxWindow' })
  api.nvim_set_hl(0, 'VertSplit', { link = 'HxWindow' })
  api.nvim_set_hl(0, 'StatusLine', { link = 'HxStatusline' })
  api.nvim_set_hl(0, 'StatusLineNC', { link = 'HxStatuslineInactive' })
  api.nvim_set_hl(0, 'TabLine', {})
  api.nvim_set_hl(0, 'TabLineFill', {})
  api.nvim_set_hl(0, 'TabLineSel', {})
  api.nvim_set_hl(0, 'MsgArea', { link = 'HxCmdline' })
  api.nvim_set_hl(0, 'NormalFloat', {})
  api.nvim_set_hl(0, 'FloatBorder', {})
  api.nvim_set_hl(0, 'CursorLine', {})
  api.nvim_set_hl(0, 'CursorLineNr', {})
  api.nvim_set_hl(0, 'LineNr', { link = 'HxLinenr' })
  api.nvim_set_hl(0, 'SignColumn', { link = 'HxBackground' })
  api.nvim_set_hl(0, 'FoldColumn', { link = 'HxBackground' })
  api.nvim_set_hl(0, 'NonText', { link = 'HxBackground' })
  api.nvim_set_hl(0, 'Whitespace', { link = 'HxVirtualWhitespace' })
  api.nvim_set_hl(0, 'MatchParen', {})
  api.nvim_set_hl(0, 'Search', {})
  api.nvim_set_hl(0, 'CurSearch', {})
  api.nvim_set_hl(0, 'IncSearch', {})
  api.nvim_set_hl(0, 'Visual', { link = 'HxSelection' })
  api.nvim_set_hl(0, 'Pmenu', {})
  api.nvim_set_hl(0, 'ErrorMsg', { link = 'HxSevError' })
  for _, name in ipairs(vim.fn.getcompletion('', 'highlight')) do
    if name:match('^@') or name:match('^Diagnostic') or name:match('^LspInlay') or name:match('^Lsp') then
      api.nvim_set_hl(0, name, {})
    end
  end
  for _, name in ipairs({ 'Comment', 'Constant', 'String', 'Character', 'Number', 'Boolean', 'Float',
    'Identifier', 'Function', 'Statement', 'Conditional', 'Repeat', 'Label', 'Operator', 'Keyword',
    'Exception', 'PreProc', 'Include', 'Define', 'Macro', 'PreCondit', 'Type', 'StorageClass',
    'Structure', 'Typedef', 'Special', 'SpecialChar', 'Tag', 'Delimiter', 'SpecialComment', 'Debug',
    'Underlined', 'Ignore', 'Error', 'Todo', 'Added', 'Changed', 'Removed', 'Title', 'Directory',
    'Question', 'MoreMsg', 'ModeMsg', 'WarningMsg', 'SpellBad', 'SpellCap', 'SpellLocal', 'SpellRare',
    'Conceal', 'QuickFixLine', 'WildMenu', 'PmenuSel', 'PmenuSbar', 'PmenuThumb', 'PmenuKind',
    'PmenuExtra', 'PmenuMatch', 'PmenuMatchSel', 'ColorColumn', 'CursorColumn', 'DiffAdd',
    'DiffChange', 'DiffDelete', 'DiffText', 'Folded', 'SnippetTabstop', 'FloatTitle', 'FloatFooter',
    'WinBar', 'WinBarNC', 'StatusLineTerm', 'StatusLineTermNC', 'OkMsg', 'StderrMsg', 'StdoutMsg' }) do
    api.nvim_set_hl(0, name, {})
  end
end

local function define_captures()
  for scope, st in pairs(M.styles) do
    if not scope:match('^ui%.') and not scope:match('^diagnostic') and scope ~= 'error' then
      api.nvim_set_hl(0, '@' .. scope, to_hl(st))
    end
  end
  api.nvim_set_hl(0, '@error', to_hl(M.styles['error']))
end

function M.setup()
  vim.o.termguicolors = true
  vim.cmd('highlight clear')
  vim.g.colors_name = 'spacemacs'
  define()
  define_captures()
end

return M
