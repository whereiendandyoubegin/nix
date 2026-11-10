local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')

local M = {}
local ns = api.nvim_create_namespace('hx_inlay_hints')
local state = {}
local idle

local function style_group(scope, fallback)
  local st = T.try_get(scope)
  if not st and fallback then st = T.try_get(fallback) end
  if not st then return nil end
  return T.group_for(st)
end

local function truncate(label, limit)
  if not limit or limit == vim.NIL then return label end
  if vim.api.nvim_strwidth(label) <= limit then return label end
  local acc, out = 0, {}
  for _, ch in ipairs(vim.fn.split(label, '\\zs')) do
    acc = acc + vim.api.nvim_strwidth(ch)
    if acc > limit then break end
    out[#out + 1] = ch
  end
  return table.concat(out) .. '…'
end

local function apply(buf, hints, client)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not hints or #hints == 0 then return end
  local Text = require('hx.text')
  local LU = require('hx.lsp.util')
  local text = Text.get(buf)
  local enc = client.offset_encoding or 'utf-16'
  table.sort(hints, function(a, b)
    if a.position.line ~= b.position.line then return a.position.line < b.position.line end
    return a.position.character < b.position.character
  end)
  local type_g = style_group('ui.virtual.inlay-hint.type', 'ui.virtual.inlay-hint')
  local param_g = style_group('ui.virtual.inlay-hint.parameter', 'ui.virtual.inlay-hint')
  local other_g = style_group('ui.virtual.inlay-hint')
  local limit = S.config.editor.lsp['inlay-hints-length-limit']
  local at = {}
  local order = {}
  for _, h in ipairs(hints) do
    local pos = LU.lsp_pos_to_pos(text, h.position, enc)
    if pos then
      local label = h.label
      if type(label) == 'table' then
        local parts = {}
        for _, p in ipairs(label) do
          parts[#parts + 1] = p.value
        end
        label = table.concat(parts)
      end
      label = truncate(label, limit)
      local slot = at[pos]
      if not slot then
        slot = { before = {}, type = {}, param = {}, other = {}, after = {} }
        at[pos] = slot
        order[#order + 1] = pos
      end
      if h.paddingLeft == true then table.insert(slot.before, { ' ' }) end
      local layer = h.kind == 1 and 'type' or (h.kind == 2 and 'param' or 'other')
      local g = layer == 'type' and type_g or (layer == 'param' and param_g or other_g)
      table.insert(slot[layer], { label, g })
      if h.paddingRight == true then table.insert(slot.after, { ' ' }) end
    end
  end
  for _, pos in ipairs(order) do
    local slot = at[pos]
    local chunks = {}
    for _, l in ipairs({ 'before', 'type', 'param', 'other', 'after' }) do
      for _, c in ipairs(slot[l]) do
        chunks[#chunks + 1] = { c[1], c[2] or 'HxText' }
      end
    end
    local row = text:line_of(pos)
    local col = pos - text:line_start(row)
    if row < api.nvim_buf_line_count(buf) then
      pcall(api.nvim_buf_set_extmark, buf, ns, row, col, {
        virt_text = chunks,
        virt_text_pos = 'inline',
        right_gravity = false,
        hl_mode = 'combine',
      })
    end
  end
end

local function compute_for_view(win)
  local buf = api.nvim_win_get_buf(win)
  local client = require('hx.lsp').with_feature(buf, 'inlay_hints')[1]
  if not client then return end
  local Text = require('hx.text')
  local text = Text.get(buf)
  local len_lines = text:len_lines()
  local height = api.nvim_win_get_height(win)
  local first_visible = vim.fn.line('w0', win) - 1
  local first = math.max(0, first_visible - height)
  local last = math.min(first_visible + height * 2, len_lines)
  local id = first .. ':' .. last
  local tick = api.nvim_buf_get_changedtick(buf)
  local st = state[buf]
  if st and st.id == id and st.tick == tick then return end
  state[buf] = { id = id, tick = tick }
  local LU = require('hx.lsp.util')
  local SL = require('hx.selection')
  local a = text:line_start(math.min(first, len_lines - 1))
  local b = last >= len_lines and text:len() or text:line_start(last)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    range = LU.range_to_lsp_range(text, SL.R(a, b), client.offset_encoding or 'utf-16'),
  }
  client:request('textDocument/inlayHint', params, function(err, result)
    if err or not S.config.editor.lsp['display-inlay-hints'] then return end
    if not api.nvim_buf_is_valid(buf) then return end
    apply(buf, result, client)
  end, buf)
end

function M.compute_all()
  if not S.config.editor.lsp['display-inlay-hints'] then
    for buf in pairs(state) do
      if api.nvim_buf_is_valid(buf) then api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
    end
    state = {}
    return
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == '' then pcall(compute_for_view, win) end
  end
end

function M.on_key()
  if not idle then idle = vim.uv.new_timer() end
  idle:stop()
  idle:start(S.config.editor['idle-timeout'] or 250, 0, vim.schedule_wrap(M.compute_all))
end

function M.setup()
  api.nvim_create_autocmd('LspAttach', {
    callback = function()
      vim.defer_fn(M.compute_all, 300)
    end,
  })
  api.nvim_create_autocmd('BufDelete', {
    callback = function(ev)
      state[ev.buf] = nil
    end,
  })
end

return M
