local api = vim.api
local S = require('hx.state')
local T = require('hx.theme')
local Text = require('hx.text')

local M = {}
local SEV = { [1] = 'error', [2] = 'warning', [3] = 'info', [4] = 'hint' }
local RANK = { hint = 1, info = 2, warning = 3, error = 4 }

local cache = {}

local function convert(buf, d)
  local text = Text.get(buf)
  local nl = text:len_lines()
  local lnum = math.min(d.lnum, nl - 1)
  local end_lnum = math.min(d.end_lnum or d.lnum, nl - 1)
  local s = text:line_start(lnum) + math.min(d.col or 0, #text:line(lnum) + 1)
  local e = text:line_start(end_lnum) + math.min(d.end_col or d.col or 0, #text:line(end_lnum) + 1)
  if e < s then e = s end
  local lsp = d.user_data and d.user_data.lsp or {}
  local client = d.namespace and vim.lsp.diagnostic.get_namespace and nil
  return {
    s = math.min(s, text:len()),
    e = math.min(e, text:len()),
    lnum = lnum,
    end_lnum = end_lnum,
    severity = SEV[d.severity] or 'hint',
    message = d.message or '',
    source = d.source,
    code = d.code or lsp.code,
    tags = lsp.tags,
    range_lsp = lsp.range,
    path = api.nvim_buf_get_name(buf),
  }
end

function M.doc_diagnostics(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if c and c.tick == tick and c.version == M.version then return c.list end
  local list = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    list[#list + 1] = convert(buf, d)
  end
  table.sort(list, function(a, b)
    if a.s ~= b.s then return a.s < b.s end
    return a.e < b.e
  end)
  cache[buf] = { tick = tick, list = list, version = M.version }
  return list
end

function M.line_diagnostics(buf, line)
  local out = {}
  for _, d in ipairs(M.doc_diagnostics(buf)) do
    if d.lnum == line then out[#out + 1] = d end
  end
  return out
end

function M.workspace_diagnostics()
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    out[#out + 1] = { severity = SEV[d.severity] or 'hint' }
  end
  return out
end

function M.picker_items(buf)
  local out = {}
  local diags = vim.diagnostic.get(buf)
  for _, d in ipairs(diags) do
    local b = d.bufnr or buf
    local name = api.nvim_buf_get_name(b)
    local lsp = d.user_data and d.user_data.lsp or {}
    local enc = 'utf-16'
    out[#out + 1] = {
      severity = SEV[d.severity] or 'hint',
      source = d.source,
      code = d.code,
      message = d.message or '',
      path = name,
      lnum = d.lnum,
      end_lnum = d.end_lnum or d.lnum,
      range_lsp = lsp.range or { start = { line = d.lnum, character = d.col }, ['end'] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col } },
      encoding = lsp.range and enc or 'utf-8',
    }
  end
  return out
end

M.version = 0
function M.changed()
  M.version = M.version + 1
  vim.schedule(function()
    pcall(M.refresh_inline)
    pcall(vim.cmd, 'redraw')
    pcall(vim.cmd.redrawstatus, { bang = true })
  end)
end

local state = { line = -1, buf = -1, active = false, timer = nil }

function M.on_cursor_moved()
  local E = require('hx.editor')
  local buf = E.buf()
  local text = Text.get(buf)
  local line = E.sel():prim():cursor_line(text)
  if line ~= state.line or buf ~= state.buf then
    state.line, state.buf = line, buf
    state.active = false
    if state.timer then
      state.timer:stop()
    else
      state.timer = vim.uv.new_timer()
    end
    state.timer:start(350, 0, vim.schedule_wrap(function()
      state.active = true
      M.refresh_inline()
      require('hx.render').redraw()
    end))
  end
  M.refresh_inline()
end

function M.immediately_show(buf)
  local E = require('hx.editor')
  local text = Text.get(buf)
  state.buf = buf
  state.line = E.sel():prim():cursor_line(text)
  state.active = true
  M.refresh_inline()
end

function M.show_cursorline(buf, line)
  return state.active and state.buf == buf and state.line == line
end

local ns = api.nvim_create_namespace('hx_diagnostics')
local frame = {}

local function sev_style(sev)
  return T.get(sev .. '.diagnostic.inline')
end

local function filter_level(v)
  if v == nil or v == 'disable' or v == false then return nil end
  return RANK[v]
end

local function wrap(s, w)
  local out = {}
  for para in (s .. '\n'):gmatch('(.-)\n') do
    local line = ''
    for word in para:gmatch('%S+%s*') do
      if vim.api.nvim_strwidth(line .. word) > w and line ~= '' then
        out[#out + 1] = line
        line = ''
      end
      while vim.api.nvim_strwidth(word) > w do
        out[#out + 1] = word:sub(1, w)
        word = word:sub(w + 1)
      end
      line = line .. word
    end
    out[#out + 1] = line
  end
  while #out > 1 and out[#out] == '' do
    out[#out] = nil
  end
  return out
end

local ns_inline = api.nvim_create_namespace('hx_inline_diagnostics')
local inline_key = {}

local function inline_filter_for(row, cursor_line, buf, width)
  local cfg = S.config.editor
  local inline_cfg = cfg['inline-diagnostics']
  local is_cursor = row == cursor_line and M.show_cursorline(buf, row)
  local f
  if row == cursor_line then
    local cl = filter_level(inline_cfg['cursor-line'])
    local ol = filter_level(inline_cfg['other-lines'])
    if is_cursor then
      f = cl
    elseif cl and ol then
      f = math.min(cl, ol)
    end
  else
    f = filter_level(inline_cfg['other-lines'])
  end
  if width < (inline_cfg['min-diagnostic-width'] or 40) + (inline_cfg['prefix-len'] or 1) then f = nil end
  return f
end
M.inline_filter_for = inline_filter_for

local function wrap_fmt(msg, width, max_wrap)
  local out = {}
  width = math.max(1, width)
  for _, para in ipairs(vim.split(msg, '\n', { plain = true })) do
    local line, lw = '', 0
    for word in para:gmatch('%S+%s*') do
      local ww = api.nvim_strwidth(word)
      local core = api.nvim_strwidth((word:gsub('%s+$', '')))
      if lw > 0 and lw + core > width then
        if core <= max_wrap or core > width then
          out[#out + 1] = line
          line, lw = '', 0
        end
      end
      while lw + core > width do
        local take = width - lw
        local chars = vim.fn.split(word, '\\zs')
        local part, pw = '', 0
        local i = 1
        while i <= #chars and pw + api.nvim_strwidth(chars[i]) <= take do
          part = part .. chars[i]
          pw = pw + api.nvim_strwidth(chars[i])
          i = i + 1
        end
        out[#out + 1] = line .. part
        line, lw = '', 0
        word = table.concat(chars, '', i)
        ww = api.nvim_strwidth(word)
        core = api.nvim_strwidth((word:gsub('%s+$', '')))
        if word == '' then break end
      end
      line = line .. word
      lw = lw + ww
    end
    out[#out + 1] = line
  end
  return out
end

local function build_inline(buf, row, diags, inline_filter, width)
  local inline_cfg = S.config.editor['inline-diagnostics']
  local max_n = inline_cfg['max-diagnostics'] or 10
  local prefix_len = inline_cfg['prefix-len'] or 1
  local min_w = inline_cfg['min-diagnostic-width'] or 40
  local max_wrap_cfg = inline_cfg['max-wrap'] or 20
  local start = width - min_w - prefix_len
  local text = Text.get(buf)
  local ls = text:line_start(row)
  local line = text:line(row)
  local stack = {}
  for _, d in ipairs(diags) do
    local anchor = vim.fn.strdisplaywidth(line:sub(1, math.max(0, d.s - ls)))
    if anchor < width and RANK[d.severity] >= inline_filter then stack[#stack + 1] = { d = d, anchor = anchor } end
  end
  while #stack > max_n do
    table.remove(stack)
  end
  if #stack == 0 then return nil end
  local function G(rank)
    return T.group_for(sev_style(({ 'hint', 'info', 'warning', 'error' })[rank]))
  end
  local rows = {}
  local r = 0
  local function put(col, rr, ch, g)
    if col < 0 or col >= width then return end
    rows[rr] = rows[rr] or {}
    rows[rr][col] = { ch, g }
  end
  local function put_str(col, rr, s, g)
    for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
      local w = api.nvim_strwidth(ch)
      put(col, rr, ch, g)
      if w == 2 then put(col + 1, rr, '', g) end
      col = col + w
    end
  end
  local function draw_diagnostic(d, col, next_sev)
    local sev = RANK[d.severity]
    local sym, symsev = '└', sev
    if next_sev then sym, symsev = '├', math.max(next_sev, sev) end
    put(col, r, sym, G(symsev))
    for i = 0, prefix_len - 1 do
      put(col + i + 1, r, '─', G(sev))
    end
    local text_col = col + prefix_len + 1
    local tw = text_col > start and min_w or (width - text_col - prefix_len)
    local lines = wrap_fmt(vim.trim(d.message), tw, math.min(max_wrap_cfg, math.floor(tw / 4)))
    for li, l in ipairs(lines) do
      put_str(text_col, r + li - 1, l, G(sev))
    end
    r = r + 1
    local extra = #lines - 1
    if next_sev then
      for _ = 1, extra do
        put(col, r, '│', G(next_sev))
        r = r + 1
      end
    else
      r = r + extra
    end
  end
  local last = stack[#stack]
  if last.anchor > start then
    local sev = RANK[last.d.severity]
    local last_anchor = last.anchor
    put(last_anchor, r, '┘', G(sev))
    local stacked = 1
    for i = #stack - 1, 1, -1 do
      local it = stack[i]
      local sym
      if it.anchor < start then break end
      sym = it.anchor == start and '├' or '┴'
      stacked = stacked + 1
      sev = math.max(sev, RANK[it.d.severity])
      if it.anchor ~= last_anchor then
        for c = it.anchor + 1, last_anchor - 1 do
          put(c, r, '─', G(sev))
        end
        put(it.anchor, r, sym, G(sev))
        last_anchor = it.anchor
      end
    end
    if last_anchor ~= start then
      for c = start + 1, last_anchor - 1 do
        put(c, r, '─', G(sev))
      end
      put(start, r, '┌', G(sev))
    end
    r = r + 1
    local list = {}
    for i = #stack - stacked + 1, #stack do
      list[#list + 1] = stack[i]
    end
    for i = #list, 1, -1 do
      local nsev
      for j = 1, i - 1 do
        local v = RANK[list[j].d.severity]
        if not nsev or v > nsev then nsev = v end
      end
      draw_diagnostic(list[i].d, start, nsev)
    end
    for _ = 1, stacked do
      table.remove(stack)
    end
  end
  local first_row = 0
  local last_anchor = width
  for i = #stack, 1, -1 do
    local it = stack[i]
    if it.anchor ~= last_anchor then
      for rr = first_row, r - 1 do
        put(it.anchor, rr, '│', G(RANK[it.d.severity]))
      end
    end
    local nxt = stack[i - 1]
    local next_sev = (nxt and nxt.anchor == it.anchor) and RANK[nxt.d.severity] or nil
    draw_diagnostic(it.d, it.anchor, next_sev)
    last_anchor = it.anchor
  end
  local vlines = {}
  for rr = 0, r - 1 do
    local cells = rows[rr] or {}
    local chunks = {}
    local maxc = -1
    for c in pairs(cells) do
      if c > maxc then maxc = c end
    end
    local pending = 0
    for c = 0, maxc do
      local cell = cells[c]
      if cell then
        if pending > 0 then
          chunks[#chunks + 1] = { string.rep(' ', pending), 'HxDefaultBg' }
          pending = 0
        end
        if cell[1] ~= '' then chunks[#chunks + 1] = { cell[1], cell[2] } end
      else
        pending = pending + 1
      end
    end
    if #chunks == 0 then chunks[1] = { '', 'HxDefaultBg' } end
    vlines[#vlines + 1] = chunks
  end
  return vlines
end

function M.refresh_inline()
  if not S.enabled then return end
  local seen = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == '' then
      local buf = api.nvim_win_get_buf(win)
      if not seen[buf] then
        seen[buf] = true
        local text = Text.get(buf)
        local focused = win == require('hx.ui.compositor').editor_win()
        local cursor_line = focused and S.get_sel(win, buf):prim():cursor_line(text) or -1
        local width = api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
        local key = table.concat({ api.nvim_buf_get_changedtick(buf), cursor_line, tostring(M.show_cursorline(buf,
          cursor_line)), width, M.version, vim.fn.line('w0', win), vim.fn.line('w$', win) }, ':')
        if inline_key[buf] ~= key then
          inline_key[buf] = key
          api.nvim_buf_clear_namespace(buf, ns_inline, 0, -1)
          local by_line = {}
          for _, d in ipairs(M.doc_diagnostics(buf)) do
            by_line[d.lnum] = by_line[d.lnum] or {}
            table.insert(by_line[d.lnum], d)
          end
          local top, bot = vim.fn.line('w0', win) - 1, vim.fn.line('w$', win) - 1
          for row, diags in pairs(by_line) do
            if row >= top - 1 and row <= bot + 1 then
              local f = inline_filter_for(row, cursor_line, buf, width)
              if f then
                local vl = build_inline(buf, row, diags, f, width)
                if vl and row < api.nvim_buf_line_count(buf) then
                  pcall(api.nvim_buf_set_extmark, buf, ns_inline, row, 0, { virt_lines = vl, priority = 4002 })
                end
              end
            end
          end
        end
      end
    end
  end
end

function M.setup()
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf, top, bot)
      frame[win] = nil
      if not S.enabled then return false end
      if api.nvim_win_get_config(win).relative ~= '' then return false end
      local list = M.doc_diagnostics(buf)
      if #list == 0 then return false end
      local text = Text.get(buf)
      local rows = {}
      local by_line = {}
      for _, d in ipairs(list) do
        local g = T.group_for(T.get('diagnostic.' .. d.severity))
        local tags = d.tags or {}
        for _, tg in ipairs(tags) do
          if tg == 1 then g = T.group_for(T.get('diagnostic.unnecessary')) end
          if tg == 2 then g = T.group_for(T.get('diagnostic.deprecated')) end
        end
        local s, e = d.s, d.e
        if e == s then e = text:next_grapheme(s) end
        local sr, er = text:line_of(s), text:line_of(math.max(s, e - 1))
        for r = math.max(sr, top), math.min(er, bot) do
          local ls = text:line_start(r)
          local l = text:line(r)
          local a = math.max(s, ls) - ls
          local b = math.min(e, ls + #l) - ls
          rows[r] = rows[r] or {}
          if b > a then table.insert(rows[r], { a, b, g }) end
        end
        by_line[d.lnum] = by_line[d.lnum] or {}
        table.insert(by_line[d.lnum], d)
      end
      local focused = win == require('hx.ui.compositor').editor_win()
      local cursor_line = focused and S.get_sel(win, buf):prim():cursor_line(text) or -1
      frame[win] = { rows = rows, by_line = by_line, cursor_line = cursor_line, buf = buf,
        width = api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff }
      return true
    end,
    on_line = function(_, win, buf, row)
      local f = frame[win]
      if not f then return end
      for _, sp in ipairs(f.rows[row] or {}) do
        pcall(api.nvim_buf_set_extmark, buf, ns, row, sp[1], {
          end_row = row,
          end_col = sp[2],
          hl_group = sp[3],
          ephemeral = true,
          priority = 4000,
        })
      end
      local diags = f.by_line[row]
      if not diags then return end
      local cfg = S.config.editor
      local inline_filter = inline_filter_for(row, f.cursor_line, buf, f.width)
      local eol_filter = filter_level(cfg['end-of-line-diagnostics'])
      if eol_filter then
        local best
        for _, d in ipairs(diags) do
          local r = RANK[d.severity]
          if r >= eol_filter and (not inline_filter or inline_filter > r) then
            if not best or r > RANK[best.severity] then best = d end
          end
        end
        if best then
          local chunks = {}
          local msg_lines = vim.split(best.message, '\n', { plain = true })
          local g = T.group_for(sev_style(best.severity))
          table.insert(chunks, { ' ', 'HxDefaultBg' })
          for i, ml in ipairs(msg_lines) do
            if i > 1 then table.insert(chunks, { '  ', g }) end
            table.insert(chunks, { ml, g })
          end
          pcall(api.nvim_buf_set_extmark, buf, ns, row, 0, {
            virt_text = chunks,
            virt_text_pos = 'eol',
            hl_mode = 'combine',
            ephemeral = true,
            priority = 4001,
          })
        end
      end
    end,
  })
  api.nvim_set_hl(0, 'HxDefaultBg', {})
end

return M
