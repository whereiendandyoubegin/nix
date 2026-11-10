local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')
local Text = require('hx.text')
local SL = require('hx.selection')
local U = require('hx.util')
local F = require('hx.fuzzy')
local LU = require('hx.lsp.util')
local Canvas = require('hx.ui.canvas')

local M = {}

M.completion = nil
M.last_completion = nil
M.active_completions = {}

local function controller()
  return { gen = 0, active = nil }
end
local function restart(ctl)
  ctl.gen = ctl.gen + 1
  local h = { ctl = ctl, gen = ctl.gen, done = false, reqs = {} }
  ctl.active = h
  return h
end
local function cancel(ctl)
  local h = ctl.active
  ctl.gen = ctl.gen + 1
  ctl.active = nil
  if h then
    for _, r in ipairs(h.reqs) do
      pcall(function()
        r.client:cancel_request(r.id)
      end)
    end
  end
end
local function is_canceled(h)
  return h.gen ~= h.ctl.gen
end
local function is_running(ctl)
  local h = ctl.active
  return h ~= nil and not is_canceled(h) and not h.done
end

M.request_controller = controller()

local function editor()
  local E = require('hx.editor')
  return E.win(), E.buf()
end

local function cfg()
  return S.config.editor
end

local function push_insert_event(ev)
  require('hx.input').push_insert_event(ev)
end

local function is_word(cp)
  return cp ~= nil and U.is_word(cp)
end

local function first_cp(s)
  if not s or s == '' then return nil end
  return (U.decode(s, 1))
end

local function cursor_of(win, buf)
  local text = Text.get(buf)
  return S.get_sel(win, buf):prim():cursor(text), text
end

function M.savepoint(win, buf)
  local text = Text.get(buf)
  return { win = win, buf = buf, text = text:all(), sel = S.get_sel(win, buf) }
end

function M.restore(sp)
  local buf, win = sp.buf, sp.win
  if not api.nvim_buf_is_valid(buf) or not api.nvim_win_is_valid(win) then return end
  local text = Text.get(buf)
  local cur = text:all()
  local changes = {}
  if cur ~= sp.text then
    local a, b = cur, sp.text
    local la, lb = #a, #b
    local p = 0
    local lim = math.min(la, lb)
    while p < lim and a:byte(p + 1) == b:byte(p + 1) do
      p = p + 1
    end
    local s = 0
    while s < lim - p and a:byte(la - s) == b:byte(lb - s) do
      s = s + 1
    end
    changes[1] = { p, la - s, b:sub(p + 1, lb - s) }
  end
  local tx = SL.Transaction.change(text, changes):with_selection(sp.sel)
  require('hx.doc').apply(tx, { win = win, buf = buf })
end

local function completion_clients(buf)
  local seen, out = {}, {}
  for _, c in ipairs(require('hx.lsp').with_feature(buf, 'completion')) do
    if not seen[c.id] then
      seen[c.id] = true
      out[#out + 1] = c
    end
  end
  return out
end

local function ends_with(s, suffix)
  return suffix ~= '' and s:sub(-#suffix) == suffix
end

local MIN_WORD_GRAPHEMES, MAX_WORD_LEN = 3, 50
local word_cache = {}

local function index_words(s, into)
  local start_byte, char_len, graphemes = nil, 0, 0
  local i, n = 1, #s
  local function qualify(e)
    if graphemes >= MIN_WORD_GRAPHEMES and char_len <= MAX_WORD_LEN then
      local w = s:sub(start_byte, e - 1)
      into[w] = (into[w] or 0) + 1
    end
  end
  while i <= n do
    local cp, len = U.decode(s, i)
    local j = i + len
    local nchars = 1
    while j <= n do
      local cp2, l2 = U.decode(s, j)
      if not U.is_extender(cp2) then break end
      j = j + l2
      nchars = nchars + 1
    end
    if is_word(cp) then
      if graphemes == 0 then
        start_byte = i
        char_len = 0
      end
      graphemes = graphemes + 1
      char_len = char_len + nchars
    elseif graphemes ~= 0 then
      qualify(i)
      graphemes = 0
    end
    i = j
  end
  if graphemes ~= 0 then qualify(n + 1) end
end

local function word_index_matches(pattern)
  local words = {}
  local now = vim.uv.now()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == '' then
      local tick = api.nvim_buf_get_changedtick(b)
      local c = word_cache[b]
      if not c or (c.tick ~= tick and now - c.at >= 1000) then
        local t = {}
        index_words(table.concat(api.nvim_buf_get_lines(b, 0, -1, false), '\n'), t)
        c = { tick = tick, words = t, at = now }
        word_cache[b] = c
      end
      for w in pairs(c.words) do
        words[w] = true
      end
    end
  end
  local cps = {}
  local cs = false
  for _, cp in U.chars(pattern) do
    cps[#cps + 1] = cp
    if U.is_upper(cp) then cs = true end
  end
  local res = {}
  for w in pairs(words) do
    local s = F.score(w, cps, { case_sensitive = cs })
    if s then res[#res + 1] = { w, s } end
  end
  table.sort(res, function(a, b)
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  local out = {}
  for i, r in ipairs(res) do
    out[i] = r[1]
  end
  return out
end

local function word_completion(trigger, handle, savepoint)
  local c = cfg()
  if not (c['word-completion'] and c['word-completion'].enable) then return nil end
  local trigger_length = c['word-completion']['trigger-length'] or 7
  local win, buf = editor()
  local text = Text.get(buf)
  local sel = S.get_sel(win, buf)
  local pos = sel:prim():cursor(text)
  local Mv = require('hx.movement')
  local cursor = Mv.move_prev_word_start(text, SL.R(pos, pos), 1)
  if cursor.head == pos then return nil end
  if trigger.kind ~= 'manual' then
    local p = cursor.head
    local count = 0
    while count < trigger_length and p < text:len() do
      local e = text:next_grapheme(p)
      local g = text:slice(p, e)
      local all = true
      for _, cp in U.chars(g) do
        if not is_word(cp) then all = false end
      end
      if not all then break end
      count = count + 1
      p = e
    end
    if count ~= trigger_length then return nil end
  end
  local typed_word = text:slice(cursor.head, pos)
  local last_cp = text:char(text:prev_char(pos))
  local edit_diff = (last_cp and U.rust_whitespace(last_cp)) and 0 or #typed_word
  if is_canceled(handle) then return nil end
  return function()
    local items = {}
    for _, word in ipairs(word_index_matches(typed_word)) do
      if word ~= typed_word then
        local tx = SL.Transaction.change_by_selection(text, sel, function(r)
          local cur = r:cursor(text)
          return { cur - edit_diff, cur, word }
        end)
        items[#items + 1] = { other = true, transaction = tx, label = word, kind = 'word', provider = 'word' }
      end
    end
    return { items = items, provider = 'word', context = { is_incomplete = false, priority = 0, savepoint = savepoint } }
  end
end

local function retain_valid_completions(trigger, win, buf, items)
  if trigger.kind == 'manual' then return items end
  local cursor, text = cursor_of(win, buf)
  local prev = cursor > 0 and text:char(text:prev_char(cursor)) or nil
  if prev and U.rust_whitespace(prev) then
    local out = {}
    for _, it in ipairs(items) do
      if it.provider ~= 'word' then out[#out + 1] = it end
    end
    return out
  end
  return items
end

local path_regex
local function get_path_suffix(s)
  if not path_regex then
    local comp = [=[[\w@.\-+#$%?!,;~&]|[\\]\s]=]
    local braced = [[\$\{(?:]] .. comp .. [[|[/:=])+\}]]
    local first = '(?:' .. braced .. '|(?:' .. comp .. '))'
    local component = '(?:' .. first .. '|=)'
    local url_prefix = [[[\w+\-.]+://??]]
    local path_start = '(?:' .. first .. '+|~|' .. url_prefix .. ')'
    local re = '(?:' .. path_start .. '?(?:(?:/' .. component .. '+)+/?|/))$'
    path_regex = require('hx.regex').new(re)
  end
  local ms, me = path_regex:find(s, 0, #s)
  if not ms then return nil end
  return s:sub(ms + 1, me)
end

local function expand_path(p)
  if p == '~' or p:sub(1, 2) == '~/' then p = (vim.uv.os_homedir() or '') .. p:sub(2) end
  p = p:gsub('%${([%w_]+):%-([^}]*)}', function(v, d)
    local e = os.getenv(v)
    return (e and e ~= '') and e or d
  end)
  p = p:gsub('%${([%w_]+)}', function(v)
    return os.getenv(v)
  end)
  p = p:gsub('%$([%a_][%w_]*)', function(v)
    return os.getenv(v)
  end)
  return p
end

local function fold_home(p)
  local home = vim.uv.os_homedir()
  if home and home ~= '' and p:sub(1, #home) == home and (p:sub(#home + 1, #home + 1) == '/' or #p == #home) then
    return '~' .. p:sub(#home + 1)
  end
  return p
end

local function normalize_path(p)
  local abs = p:sub(1, 1) == '/'
  local parts = {}
  for part in p:gmatch('[^/]+') do
    if part == '..' then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= '.' then
      parts[#parts + 1] = part
    end
  end
  return (abs and '/' or '') .. table.concat(parts, '/')
end

local function path_kind(st)
  if not st then return 'file' end
  local t = st.type
  if t == 'link' then return 'link' end
  if t == 'directory' then return 'folder' end
  if t == 'block' then return 'block' end
  if t == 'socket' then return 'socket' end
  if t == 'char' then return 'char_device' end
  if t == 'fifo' then return 'fifo' end
  return 'file'
end

local function perms(mode)
  local bits = { 256, 128, 64, 32, 16, 8, 4, 2, 1 }
  local chars = { 'r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x' }
  local out = {}
  for i, b in ipairs(bits) do
    out[i] = (math.floor(mode / b) % 2 == 1) and chars[i] or '-'
  end
  return table.concat(out)
end

local function path_completion(sel, buf, handle, savepoint)
  if not cfg()['path-completion'] then return nil end
  local text = Text.get(buf)
  local cursor = sel:prim():cursor(text)
  local row = text:line_of(cursor)
  local start = math.max(text:line_start(row), cursor - 1000)
  local line = text:slice(start, cursor)
  local matched = get_path_suffix(line)
  if not matched then return nil end
  local path
  if matched:sub(1, 7) == 'file://' then
    local ok, p = pcall(vim.uri_to_fname, matched)
    if not ok then return nil end
    path = p
  else
    path = matched
  end
  path = expand_path(path)
  local name = api.nvim_buf_get_name(buf)
  if path:sub(1, 1) ~= '/' and name ~= '' then
    path = vim.fn.fnamemodify(name, ':p:h') .. '/' .. path
  end
  local dir, typed
  if matched:sub(-1) == '/' then
    dir = path
  else
    local base = path:match('([^/]*)$')
    if base == '..' or base == '.' then
      dir = path:match('^(.*)/') or ''
      typed = nil
    else
      dir = path:sub(1, #path - #base - 1)
      if dir == '' and path:sub(1, 1) == '/' then dir = '/' end
      typed = base
    end
    if dir == '' then return nil end
  end
  if is_canceled(handle) then return nil end
  return function()
    local items = {}
    local resp = { items = items, provider = 'path', context = { is_incomplete = false, priority = 1, savepoint = savepoint } }
    local fs = vim.uv.fs_scandir(dir)
    if not fs then return resp end
    local edit_diff = typed and #typed or 0
    while true do
      local fname = vim.uv.fs_scandir_next(fs)
      if not fname then break end
      if is_canceled(handle) then break end
      local full = (dir:sub(-1) == '/' and dir or (dir .. '/')) .. fname
      local st = vim.uv.fs_lstat(full)
      if st then
        local kind = path_kind(st)
        local doc = ('type: `%s`\npermissions: `[%s]`\nfull path: `%s`'):format(kind, perms(st.mode % 512),
          fold_home(normalize_path(full)))
        local tx = SL.Transaction.change_by_selection(text, sel, function(r)
          local cur = r:cursor(text)
          return { cur - edit_diff, cur, fname }
        end)
        items[#items + 1] = { other = true, kind = kind, label = fname, transaction = tx, documentation = doc,
          provider = 'path' }
      end
    end
    return resp
  end
end

local function request_from_language_server(client, buf, win, context, priority, savepoint, handle, cb)
  local text = Text.get(buf)
  local cursor = S.get_sel(win, buf):prim():cursor(text)
  local enc = client.offset_encoding or 'utf-16'
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = LU.pos_to_lsp_pos(text, cursor, enc),
    context = context,
  }
  local ok, id = client:request('textDocument/completion', params, function(err, result)
    local items, incomplete = {}, false
    if not err and result then
      if result.items then
        items = result.items
        incomplete = result.isIncomplete or false
      else
        items = result
      end
    end
    table.sort(items, function(a, b)
      local sa = a.sortText or a.label
      local sb = b.sortText or b.label
      if sa ~= sb then return sa < sb end
      return false
    end)
    local out = {}
    for i, it in ipairs(items) do
      out[i] = { lsp = true, item = it, provider_id = client.id, resolved = false, provider_priority = priority }
    end
    cb({
      items = out,
      provider = 'lsp:' .. client.id,
      context = { is_incomplete = incomplete, priority = priority, savepoint = savepoint },
    })
  end, buf)
  if ok and id and handle then handle.reqs[#handle.reqs + 1] = { client = client, id = id } end
  if not ok then
    vim.schedule(function()
      cb({ items = {}, provider = 'lsp:' .. client.id, context = { is_incomplete = false, priority = priority,
        savepoint = savepoint } })
    end)
  end
end

local function take_items(resp, dst)
  for _, it in ipairs(resp.items) do
    dst[#dst + 1] = it
  end
  resp.items = {}
end

local function refresh()
  M.render()
  require('hx.ui.compositor').render_all()
  pcall(vim.cmd, 'redraw')
end

local function replace_response(handle, resp, is_incomplete)
  local c = M.completion
  if not c then return end
  if is_canceled(handle) then return end
  c:replace_provider_completions(resp, is_incomplete)
  if c:is_empty() then
    M.clear_completion()
    M.trigger_auto_completion(false)
  else
    M.active_completions[resp.provider] = resp.context
  end
  refresh()
end

local show_completion

local function request_completions(trigger, handle)
  local win, buf = editor()
  if M.completion or S.mode ~= 'insert' then
    handle.done = true
    return
  end
  local cursor, text = cursor_of(win, buf)
  if trigger.win ~= win or trigger.buf ~= buf or cursor < trigger.pos then
    handle.done = true
    return
  end
  trigger.pos = cursor
  local savepoint = M.savepoint(win, buf)
  local trigger_text = text:slice(math.max(0, cursor - 64), cursor)
  local clients = completion_clients(buf)

  local pending = 0
  local phase = 'first'
  local items, context = {}, {}
  local deadline
  local function finish_if_done()
    if pending == 0 and phase ~= 'collect' then handle.done = true end
  end
  local function show()
    if deadline then
      deadline:stop()
      deadline:close()
      deadline = nil
    end
    phase = 'replace'
    if not is_canceled(handle) then
      show_completion(items, context, trigger)
      refresh()
    end
    finish_if_done()
  end
  local function on_response(resp)
    pending = pending - 1
    if is_canceled(handle) then
      finish_if_done()
      return
    end
    local keep = resp.context.is_incomplete or #resp.items > 0
    if phase == 'first' then
      if keep then
        take_items(resp, items)
        context[resp.provider] = resp.context
        phase = 'collect'
        if pending == 0 then
          show()
          return
        end
        deadline = vim.uv.new_timer()
        deadline:start(100, 0, vim.schedule_wrap(function()
          if phase == 'collect' then show() end
        end))
      end
    elseif phase == 'collect' then
      if keep then
        take_items(resp, items)
        context[resp.provider] = resp.context
      end
      if pending == 0 then
        show()
        return
      end
    else
      if keep then replace_response(handle, resp, false) end
    end
    finish_if_done()
  end

  for i, client in ipairs(clients) do
    local priority = -(i - 1)
    local context_
    if trigger.kind == 'manual' then
      context_ = { triggerKind = 1 }
    else
      local tc
      local cp = client.server_capabilities.completionProvider
      for _, t in ipairs((cp and cp.triggerCharacters) or {}) do
        if ends_with(trigger_text, t) then
          tc = t
          break
        end
      end
      context_ = tc and { triggerKind = 2, triggerCharacter = tc } or { triggerKind = 1 }
    end
    pending = pending + 1
    request_from_language_server(client, buf, win, context_, priority, savepoint, handle, on_response)
  end
  local sel = S.get_sel(win, buf)
  local pathf = path_completion(sel, buf, handle, savepoint)
  if pathf then
    pending = pending + 1
    vim.schedule(function()
      on_response(pathf())
    end)
  end
  local wordf = word_completion(trigger, handle, savepoint)
  if wordf then
    pending = pending + 1
    vim.schedule(function()
      on_response(wordf())
    end)
  end
  push_insert_event({ completion = 'request' })
  if pending == 0 then handle.done = true end
end

local function request_incomplete_completion_list(handle)
  local win, buf = editor()
  local savepoint
  local reqs = 0
  for provider, context in pairs(M.active_completions) do
    if context.is_incomplete then
      local id = tonumber(provider:match('^lsp:(%d+)$') or '')
      local client = id and vim.lsp.get_client_by_id(id)
      if client then
        savepoint = savepoint or M.savepoint(win, buf)
        reqs = reqs + 1
        request_from_language_server(client, buf, win, { triggerKind = 3 }, context.priority, savepoint, handle,
          function(resp)
            replace_response(handle, resp, true)
          end)
      end
    end
  end
end

local H = { trigger = nil, in_flight = nil, ctl = controller(), timer = nil }

local function stop_timer()
  if H.timer then H.timer:stop() end
end

local function finish_debounce()
  local trigger = H.trigger
  H.trigger = nil
  if not trigger then return end
  H.in_flight = trigger
  local handle = restart(H.ctl)
  vim.schedule(function()
    request_completions(trigger, handle)
  end)
end

local function start_timer(ms)
  if not H.timer then H.timer = vim.uv.new_timer() end
  H.timer:stop()
  H.timer:start(ms, 0, vim.schedule_wrap(finish_debounce))
end

function M.event(ev)
  if H.in_flight and not is_running(H.ctl) then H.in_flight = nil end
  local kind = ev.kind
  if kind == 'auto' then
    local t = H.trigger or H.in_flight
    if not t or t.buf ~= ev.buf or t.win ~= ev.win then
      H.trigger = { pos = ev.cursor, win = ev.win, buf = ev.buf, kind = 'auto' }
    end
  elseif kind == 'trigger_char' then
    cancel(H.ctl)
    H.trigger = { pos = ev.cursor, win = ev.win, buf = ev.buf, kind = 'trigger_char' }
  elseif kind == 'manual' then
    H.trigger = { pos = ev.cursor, win = ev.win, buf = ev.buf, kind = 'manual' }
    stop_timer()
    finish_debounce()
    return
  elseif kind == 'cancel' then
    H.trigger = nil
    cancel(H.ctl)
  elseif kind == 'delete' then
    local t = H.trigger or H.in_flight
    if t and ev.cursor < t.pos then
      H.trigger = nil
      cancel(H.ctl)
    end
  end
  if H.trigger then
    start_timer(H.trigger.kind == 'auto' and (cfg()['completion-timeout'] or 250) or 5)
  else
    stop_timer()
  end
end

function M.trigger_auto_completion(trigger_char_only)
  if not cfg()['auto-completion'] then return end
  local win, buf = editor()
  local cursor, text = cursor_of(win, buf)
  local before = text:slice(math.max(0, cursor - 64), cursor)
  local is_trigger_char = false
  for _, c in ipairs(completion_clients(buf)) do
    local cp = c.server_capabilities.completionProvider
    for _, t in ipairs((cp and cp.triggerCharacters) or {}) do
      if ends_with(before, t) then is_trigger_char = true end
    end
  end
  local is_path_trigger = before:sub(-1) == '/'
  if is_trigger_char or (is_path_trigger and cfg()['path-completion']) then
    M.event({ kind = 'trigger_char', cursor = cursor, win = win, buf = buf })
    return
  end
  if trigger_char_only then return end
  local n = cfg()['completion-trigger-len'] or 2
  local p = cursor
  local all = true
  for _ = 1, n do
    if p <= 0 then break end
    p = text:prev_char(p)
    if not is_word(text:char(p)) then
      all = false
      break
    end
  end
  if all then M.event({ kind = 'auto', cursor = cursor, win = win, buf = buf }) end
end

local KIND = {
  'text', 'method', 'function', 'constructor', 'field', 'variable', 'class', 'interface', 'module', 'property',
  'unit', 'value', 'enum', 'keyword', 'snippet', 'color', 'file', 'reference', 'folder', 'enum_member',
  'constant', 'struct', 'event', 'operator', 'type_param',
}

local function doc_text(d)
  if d == nil or d == vim.NIL then return nil end
  if type(d) == 'string' then return d end
  return d.value
end

local function filter_text(item)
  if item.lsp then
    local ft = item.item.filterText
    if type(ft) == 'string' then return ft end
    return item.item.label
  end
  return item.label
end

local function provider_of(item)
  if item.lsp then return 'lsp:' .. item.provider_id end
  return item.provider
end

local function provider_priority(item)
  if item.lsp then return item.provider_priority end
  return 1
end

local function preselect(item)
  return item.lsp and item.item.preselect == true
end

local function format_item(item)
  if item._row then return item._row end
  local label, kind_cell, deprecated
  if item.lsp then
    local it = item.item
    label = it.label
    deprecated = it.deprecated == true
    if type(it.tags) == 'table' then
      for _, tg in ipairs(it.tags) do
        if tg == 1 then deprecated = true end
      end
    end
    local k = it.kind
    if k == 16 then
      local d = doc_text(it.documentation)
      local hex = d and #d >= 7 and d:sub(-7) or nil
      if hex and hex:match('^#%x%x%x%x%x%x$') then
        kind_cell = { { 'color ', nil }, { '■', { fg = hex } } }
      else
        kind_cell = 'color'
      end
    elseif k and KIND[k] then
      kind_cell = KIND[k]
    else
      kind_cell = ''
    end
  else
    label = item.label
    kind_cell = item.kind or ''
  end
  local style = {}
  if deprecated then
    style = { mods = { crossed_out = true } }
  elseif kind_cell == 'folder' then
    style = T.get('ui.text.directory')
  end
  item._row = { { { label, style } }, kind_cell }
  return item._row
end

local Completion = {}
Completion.__index = Completion

local function lsp_item_to_transaction(win, buf, item, encoding, trigger_offset, replace_mode)
  local text = Text.get(buf)
  local sel = S.get_sel(win, buf)
  local primary_cursor = sel:prim():cursor(text)
  local edit_offset, new_text
  local te = item.textEdit
  if type(te) == 'table' then
    local range
    if te.insert and te.replace then
      range = replace_mode and te.replace or te.insert
    else
      range = te.range
    end
    new_text = te.newText
    local r = LU.lsp_range_to_range(text, range, encoding)
    if not r then return SL.Transaction.change(text, {}), nil end
    edit_offset = { r.anchor - primary_cursor, r.head - primary_cursor }
  else
    new_text = type(item.insertText) == 'string' and item.insertText or item.label
    local _ = trigger_offset
  end
  if item.kind == 15 or item.insertTextFormat == 2 then
    local Snip = require('hx.snippet')
    local snip = Snip.parse(new_text)
    if not snip then return SL.Transaction.change(text, {}), nil end
    return Snip.generate_transaction_from_snippet(text, sel, edit_offset, replace_mode, snip, buf)
  end
  return LU.generate_transaction_from_completion_edit(text, sel, edit_offset, replace_mode, new_text), nil
end

local function completion_changes(tx, trigger_offset)
  local out = {}
  for _, c in ipairs(tx.cs.changes) do
    if c[1] <= trigger_offset and trigger_offset <= c[2] then
      out[#out + 1] = { c[1], c[2], c[3] }
    end
  end
  return out
end

local function resolve_sync(client, item)
  local cp = client.server_capabilities.completionProvider
  if not (cp and cp.resolveProvider) then return nil end
  local res = client:request_sync('completionItem/resolve', item, 2000, require('hx.editor').buf())
  if res and not res.err and res.result then return res.result end
  return nil
end

function Completion.new(items, trigger_offset)
  local win, buf = editor()
  local self = setmetatable({
    trigger_offset = trigger_offset,
    win = win,
    buf = buf,
    res = { last = nil, next = nil, in_flight = nil, timer = nil, gen = 0 },
  }, Completion)
  local Menu = require('hx.ui.menu').Menu
  self.menu = Menu.new(items, format_item, function(item, event)
    self:callback(item, event)
  end)
  local Popup = require('hx.ui.popup').Popup
  self.popup = Popup.new('completion', self.menu, { scrollbar = false, ignore_escape_key = true, is_menu = true })
  self.popup.zindex = 80
  local cursor, text = cursor_of(win, buf)
  local start = cursor
  while start > 0 do
    local p = text:prev_char(start)
    if not is_word(text:char(p)) then break end
    start = p
  end
  self.filter = text:slice(start, cursor)
  self:score(false)
  return self
end

function Completion:callback(item, event)
  local c = cfg()
  local preview = c['preview-completion-insert']
  local replace_mode = c['completion-replace']
  local win, buf = editor()
  local function language_server(it)
    local client = vim.lsp.get_client_by_id(it.provider_id)
    if not client or client:is_stopped() then
      S.set_status('completions are outdated', 'error')
      return nil
    end
    return client
  end
  local Doc = require('hx.doc')
  if event == 'abort' then
  elseif event == 'update' then
    if preview then
      if M.last_completion and M.last_completion.kind == 'triggered' then
        M.last_completion = { kind = 'selected', savepoint = M.savepoint(win, buf) }
      end
      local context = M.active_completions[provider_of(item)]
      if context then M.restore(context.savepoint) end
      if item.lsp then
        local client = language_server(item)
        if not client then return end
        local tx = lsp_item_to_transaction(win, buf, item.item, client.offset_encoding, self.trigger_offset,
          replace_mode)
        M.ghost = true
        Doc.apply(tx, { win = win, buf = buf })
        M.ghost = false
      else
        M.ghost = true
        Doc.apply(item.transaction, { win = win, buf = buf })
        M.ghost = false
      end
    end
  elseif event == 'validate' then
    local lc = M.last_completion
    M.last_completion = nil
    if lc and lc.kind == 'selected' then M.restore(lc.savepoint) end
    local context = M.active_completions[provider_of(item)]
    if context then M.restore(context.savepoint) end
    Doc.checkpoint(buf)
    local tx, snippet, add_edits, encoding
    if item.lsp then
      local client = language_server(item)
      if not client then return end
      local it = item.item
      if not item.resolved then
        local r = resolve_sync(client, it)
        if r then it = r end
      end
      encoding = client.offset_encoding
      tx, snippet = lsp_item_to_transaction(win, buf, it, encoding, self.trigger_offset, replace_mode)
      add_edits = it.additionalTextEdits
    else
      tx = item.transaction
    end
    Doc.apply(tx, { win = win, buf = buf })
    if snippet then require('hx.snippet').activate(buf, snippet) end
    M.last_completion = {
      kind = 'applied',
      trigger_offset = self.trigger_offset,
      changes = completion_changes(tx, self.trigger_offset),
      placeholder = snippet ~= nil,
    }
    if type(add_edits) == 'table' and #add_edits > 0 then
      local atx = LU.transaction_from_edits(Text.get(buf), add_edits, encoding)
      Doc.apply(atx, { win = win, buf = buf })
    end
    M.trigger_auto_completion(true)
  end
  if event ~= 'update' then
    pcall(function()
      require('hx.lsp.signature').trigger('automatic')
    end)
  end
end

function Completion:score(incremental)
  local cps = {}
  local nlen = 0
  for _, cp in U.chars(self.filter) do
    cps[#cps + 1] = U.lower(cp)
    nlen = nlen + 1
  end
  local opts = { case_sensitive = false, prefer_prefix = true }
  local menu = self.menu
  local options = menu.options
  if incremental then
    local kept = {}
    for _, m in ipairs(menu.matches) do
      local s = F.score(filter_text(options[m[1]]), cps, opts)
      if s then kept[#kept + 1] = { m[1], math.floor(s / 2) } end
    end
    menu.matches = kept
  else
    local ms = {}
    for i, opt in ipairs(options) do
      local s = F.score(filter_text(opt), cps, opts)
      if s then ms[#ms + 1] = { i, math.floor(s / 3) } end
    end
    menu.matches = ms
  end
  local min_score = math.floor((7 + nlen * 14) / 3)
  table.sort(menu.matches, function(a, b)
    local oa, ob = options[a[1]], options[b[1]]
    local la, lb = a[2] <= min_score, b[2] <= min_score
    if la ~= lb then return not la end
    local pa, pb = preselect(oa), preselect(ob)
    if pa ~= pb then return pa end
    local ra, rb = provider_priority(oa), provider_priority(ob)
    if ra ~= rb then return ra < rb end
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[1] < b[1]
  end)
end

function Completion:update_filter(c)
  if c then
    self.filter = self.filter .. U.encode(c)
  else
    if self.filter ~= '' then
      self.filter = self.filter:sub(1, U.prev_boundary(self.filter, #self.filter))
    end
    if self.filter == '' then
      self.menu:clear()
      return
    end
  end
  self:score(c ~= nil)
  self.menu:reset_cursor()
end

function Completion:replace_provider_completions(resp, is_incomplete)
  local menu = self.menu
  if is_incomplete then
    local kept = {}
    for _, it in ipairs(menu.options) do
      if provider_of(it) ~= resp.provider then kept[#kept + 1] = it end
    end
    menu.options = kept
  end
  take_items(resp, menu.options)
  self:score(false)
  menu:ensure_cursor_in_bounds()
end

function Completion:is_empty()
  return self.menu:is_empty()
end

function Completion:replace_item(old, new)
  for i, opt in ipairs(self.menu.options) do
    if opt == old then
      self.menu.options[i] = new
      return
    end
  end
end

function Completion:area()
  local area = self.popup:render_info()
  return area
end

function Completion:ensure_item_resolved(item)
  if item.resolved then return end
  local it = item.item
  local d = doc_text(it.documentation)
  if d and d ~= '' and type(it.detail) == 'string' and it.detail ~= '' and type(it.additionalTextEdits) == 'table'
    and #it.additionalTextEdits > 0 then
    item.resolved = true
    return
  end
  local R = self.res
  if R.last == item then return end
  local client = vim.lsp.get_client_by_id(item.provider_id)
  if not client then
    item.resolved = true
    return
  end
  local cp = client.server_capabilities.completionProvider
  if not (cp and cp.resolveProvider) then
    item.resolved = true
    return
  end
  R.last = item
  if R.next and R.next.item == item then return end
  if R.in_flight == item then
    R.next = nil
    if R.timer then R.timer:stop() end
    return
  end
  R.next = { item = item, client = client }
  if not R.timer then R.timer = vim.uv.new_timer() end
  R.timer:stop()
  R.timer:start(150, 0, vim.schedule_wrap(function()
    local req = R.next
    R.next = nil
    if not req then return end
    R.gen = R.gen + 1
    local gen = R.gen
    R.in_flight = req.item
    req.client:request('completionItem/resolve', req.item.item, function(err, result)
      if gen ~= R.gen then return end
      if M.completion ~= self then return end
      local new = {
        lsp = true,
        item = (not err and result) and result or req.item.item,
        provider_id = req.item.provider_id,
        resolved = true,
        provider_priority = req.item.provider_priority,
      }
      self:replace_item(req.item, new)
      refresh()
    end, self.buf)
  end))
end

local function markdowned(lang, detail, doc)
  if detail and doc then return ('```%s\n%s\n```\n%s'):format(lang, detail, doc) end
  if detail then return ('```%s\n%s\n```'):format(lang, detail) end
  if doc then return doc end
  return ''
end

function Completion:render()
  self.popup:render()
  local item = self.menu:selection()
  if not item then
    Canvas.hide('completion-doc')
    return
  end
  if item.lsp then
    self:ensure_item_resolved(item)
    item = self.menu:selection() or item
  end
  local lang = require('hx.editor').language(self.buf) or ''
  local md
  if item.lsp then
    local it = item.item
    local d = doc_text(it.documentation)
    local detail = type(it.detail) == 'string' and it.detail or nil
    if d then
      md = markdowned(lang, detail, d)
    elseif detail then
      md = markdowned(lang, detail, nil)
    else
      Canvas.hide('completion-doc')
      return
    end
  else
    if not item.documentation then
      Canvas.hide('completion-doc')
      return
    end
    md = markdowned(lang, nil, item.documentation)
  end
  local scr = Canvas.screen()
  local popup_area = self.popup.area
  if not popup_area then return end
  local Popup = require('hx.ui.popup')
  local contents = Popup.MarkdownContents(md)
  local cursor_row = Popup.cursor_screen_row()
  local right = popup_area.x + popup_area.w
  local avail = math.max(0, scr.w - right)
  local x, y, w, h
  if avail > 30 then
    w = avail
    h = math.max(0, scr.h - popup_area.y)
    x, y = right, popup_area.y
    local rw, rh = contents:required_size(w, h)
    w = math.min(rw, w)
    h = math.min(rh, h)
  else
    local above = math.max(0, math.min(cursor_row, popup_area.y) - 1)
    local below = math.max(0, scr.h - (math.max(cursor_row, popup_area.y + popup_area.h) + 1))
    local ah
    if below >= above then
      y, ah = scr.h - below, below
    else
      y, ah = 0, above
    end
    if ah <= 1 then
      Canvas.hide('completion-doc')
      return
    end
    x, w, h = 0, scr.w, math.min(ah, 15)
  end
  if w <= 0 or h <= 0 then
    Canvas.hide('completion-doc')
    return
  end
  local bg = T.group_for(T.get('ui.popup'))
  local canvas = Canvas.new(w, h, bg)
  local border = cfg()['popup-border']
  if border == 'all' or border == 'popup' then canvas:border(0, 0, w, h, T.group_for({})) end
  contents:render(canvas, 0, 0, w, h, 0)
  Canvas.show('completion-doc', canvas, y, x, { zindex = 81 })
end

function Completion:close()
  Canvas.hide('popup:completion')
  Canvas.hide('completion-doc')
  if self.res.timer then
    self.res.timer:stop()
    self.res.timer:close()
    self.res.timer = nil
  end
end

function M.render()
  if M.completion then
    local ok, err = pcall(M.completion.render, M.completion)
    if not ok then vim.schedule(function() vim.notify('hx completion: ' .. tostring(err), vim.log.levels.ERROR) end) end
  end
end

function M.set_completion(items, trigger_offset)
  local c = Completion.new(items, trigger_offset)
  if c:is_empty() then return nil end
  local area = c:area()
  M.last_completion = { kind = 'triggered' }
  push_insert_event({ completion = 'trigger' })
  M.completion = c
  return area
end

local function intersects(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
M.intersects = intersects

show_completion = function(items, context, trigger)
  local win, buf = editor()
  if S.mode ~= 'insert' or win ~= trigger.win or buf ~= trigger.buf then return end
  if M.completion then return end
  items = retain_valid_completions(trigger, win, buf, items)
  M.active_completions = context
  local area = M.set_completion(items, trigger.pos)
  local ok, Sig = pcall(require, 'hx.lsp.signature')
  if area and ok then
    local sa = Sig.area()
    if sa and intersects(area, sa) then Sig.close_popup() end
  end
end

function M.clear_completion()
  if M.completion then M.completion:close() end
  M.completion = nil
  restart(M.request_controller)
  M.active_completions = {}
  local lc = M.last_completion
  M.last_completion = nil
  local cb
  if lc then
    if lc.kind == 'applied' then
      push_insert_event({ completion = 'apply', trigger_offset = lc.trigger_offset, changes = lc.changes })
      if lc.placeholder then cb = require('hx.snippet').placeholder_callback end
    elseif lc.kind == 'selected' then
      M.restore(lc.savepoint)
    end
  end
  return cb
end

function M.active()
  return M.completion ~= nil
end
function M.active_()
  return M.completion ~= nil
end

function M.handle_event(key)
  local c = M.completion
  if not c then return false, false end
  local popup = c.popup
  if key == 'esc' and popup.ignore_escape_key then return false, false end
  local res = c.menu:handle_key(key)
  if res == 'ignored' or res == 'ignored_close' then
    if key == 'esc' or key == 'C-c' then
      c.menu:handle_key(key)
      return true, true
    elseif key == 'pagedown' or key == 'C-d' then
      popup.scroll_half_pages = popup.scroll_half_pages + 1
      return true, false
    elseif key == 'pageup' or key == 'C-u' then
      popup.scroll_half_pages = math.max(0, popup.scroll_half_pages - 1)
      return true, false
    end
    if popup.auto_close then return false, true end
    return false, res == 'ignored_close'
  end
  return true, res == 'consumed_close'
end

local function clear_completions(ctx)
  local fn = function()
    M.clear_completion()
  end
  if ctx then ctx:push_callback(fn) else fn() end
end

local function update_completion_filter(ctx, c)
  local fn = function()
    local comp = M.completion
    if not comp then return end
    comp:update_filter(c)
    if comp:is_empty() or (c and not is_word(c)) then
      M.clear_completion()
      if c then M.trigger_auto_completion(false) end
    else
      local handle = restart(M.request_controller)
      request_incomplete_completion_list(handle)
    end
  end
  if ctx then ctx:push_callback(fn) else fn() end
end

function M.post_command(name, ctx)
  if S.mode ~= 'insert' then return end
  if M.last_completion then
    if name == 'delete_word_forward' or name == 'delete_char_forward' or name == 'completion' then
      return
    elseif name == 'delete_char_backward' then
      update_completion_filter(ctx, nil)
    else
      clear_completions(ctx)
    end
  else
    local ev
    if name == 'delete_char_backward' or name == 'delete_word_forward' or name == 'delete_char_forward' then
      local win, buf = editor()
      ev = { kind = 'delete', cursor = (cursor_of(win, buf)) }
    elseif name == 'completion' or name == 'insert_mode' or name == 'append_mode' then
      return
    else
      ev = { kind = 'cancel' }
    end
    M.event(ev)
  end
end

function M.mode_switch(old, new, ctx)
  if old == 'insert' then
    M.event({ kind = 'cancel' })
    clear_completions(ctx)
  elseif new == 'insert' then
    M.trigger_auto_completion(false)
  end
end

function M.on_insert_char(ch, ctx)
  local cp = type(ch) == 'number' and ch or first_cp(ch)
  if M.last_completion then
    update_completion_filter(ctx, cp)
  else
    M.trigger_auto_completion(false)
  end
end

function M.trigger_manual()
  local win, buf = editor()
  local cursor = cursor_of(win, buf)
  M.event({ kind = 'manual', cursor = cursor, win = win, buf = buf })
end

function M.close()
  M.clear_completion()
end

local R = {}
function M.replay_begin()
  R = {}
end

function M.replay(ev)
  local win, buf = editor()
  if ev.completion == 'apply' then
    if R.last_savepoint then M.restore(R.last_savepoint) end
    local cursor, text = cursor_of(win, buf)
    local function shift(p)
      return math.max(0, p + cursor - ev.trigger_offset)
    end
    local changes = {}
    for _, c in ipairs(ev.changes) do
      changes[#changes + 1] = { shift(c[1]), shift(c[2]), c[3] }
    end
    require('hx.doc').apply(SL.Transaction.change(text, changes), { win = win, buf = buf })
  elseif ev.completion == 'trigger' then
    R.last_savepoint = R.last_request_savepoint
    R.last_request_savepoint = nil
  elseif ev.completion == 'request' then
    R.last_request_savepoint = M.savepoint(win, buf)
  end
end

return M
