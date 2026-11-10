local M = {}

M.language_server = {
  ty = { command = 'ty', args = { 'server' } },
  ruff = { command = 'ruff', args = { 'server' } },
  basedpyright = { command = 'basedpyright-langserver', args = { '--stdio' }, config = {} },
}

M.language = {
  python = {
    scope = 'source.python',
    ['injection-regex'] = 'py(thon)?',
    ['file-types'] = { 'py', 'pyi', 'py3', 'pyw', 'ptl', 'rpy', 'cpy', 'ipy', 'pyt',
      { glob = '.python_history' }, { glob = '.pythonstartup' }, { glob = '.pythonrc' },
      { glob = '*SConstruct' }, { glob = '*SConscript' }, { glob = '*sconstruct' } },
    shebangs = { 'python', 'uv' },
    roots = { 'pyproject.toml', 'setup.py', 'poetry.lock', 'pyrightconfig.json' },
    ['comment-token'] = '#',
    ['language-servers'] = { 'ty', 'ruff', 'basedpyright' },
    indent = { ['tab-width'] = 4, unit = '    ' },
  },
}

local DEFAULT_PAIRS = { { '(', ')' }, { '{', '}' }, { '[', ']' }, { "'", "'" }, { '"', '"' }, { '`', '`' } }

local function lang(buf)
  return M.language[vim.bo[buf].filetype]
end

function M.comment_tokens(buf)
  local l = lang(buf)
  if l then
    local t = l['comment-tokens'] or l['comment-token']
    if type(t) == 'string' then return { t } end
    return t
  end
  local cs = vim.bo[buf].commentstring
  if cs and cs ~= '' then
    local tok = cs:match('^(.-)%s*%%s%s*$')
    if tok and tok ~= '' and not cs:match('%%s.+') then return { tok } end
  end
  return nil
end

function M.block_comment_tokens(buf)
  local l = lang(buf)
  if l then return l['block-comment-tokens'] end
  local cs = vim.bo[buf].commentstring
  if cs then
    local s, e = cs:match('^(.-)%s*%%s%s*(.+)$')
    if s and e and e ~= '' then return { { start = s, ['end'] = e } } end
  end
  return nil
end

function M.auto_pairs(buf)
  local cfg = require('hx.state').config.editor['auto-pairs']
  if cfg == false then return nil end
  local U = require('hx.util')
  local function from_map(m)
    local out = {}
    for o, c in pairs(m) do
      out[#out + 1] = { o, c }
    end
    table.sort(out, function(a, b)
      return a[1] < b[1]
    end)
    return out
  end
  local list = type(cfg) == 'table' and from_map(cfg) or DEFAULT_PAIRS
  local l = lang(buf)
  if l and l['auto-pairs'] == false then return nil end
  if l and type(l['auto-pairs']) == 'table' then list = from_map(l['auto-pairs']) end
  local map = {}
  for _, p in ipairs(list) do
    local o, c = U.decode(p[1], 1), U.decode(p[2], 1)
    local pair = { open = o, close = c }
    map[o] = pair
    if o ~= c then map[c] = pair end
  end
  return map
end

function M.servers_for(buf)
  local l = lang(buf)
  if not l then return {} end
  return l['language-servers'] or {}
end

function M.setup_filetypes()
  local ext, filename, pattern = {}, {}, {}
  for name, l in pairs(M.language) do
    for _, ft in ipairs(l['file-types'] or {}) do
      if type(ft) == 'string' then
        ext[ft] = name
      elseif ft.glob then
        if ft.glob:find('[%*%?]') then
          pattern[vim.fn.glob2regpat(ft.glob):gsub('^%^', ''):gsub('%$$', '')] = name
        else
          filename[ft.glob] = name
        end
      end
    end
  end
  vim.filetype.add({ extension = ext, filename = filename })
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('hx_languages', { clear = true }),
    callback = function(ev)
      local l = M.language[vim.bo[ev.buf].filetype]
      if l and l.indent then
        local unit = l.indent.unit
        vim.bo[ev.buf].tabstop = l.indent['tab-width']
        if unit == '\t' then
          vim.bo[ev.buf].expandtab = false
          vim.bo[ev.buf].shiftwidth = 0
        else
          vim.bo[ev.buf].expandtab = true
          vim.bo[ev.buf].shiftwidth = #unit
        end
      end
      vim.bo[ev.buf].indentexpr = ''
      vim.bo[ev.buf].formatoptions = ''
      vim.bo[ev.buf].smartindent = false
      vim.bo[ev.buf].cindent = false
      vim.bo[ev.buf].autoindent = false
    end,
  })
end

return M
