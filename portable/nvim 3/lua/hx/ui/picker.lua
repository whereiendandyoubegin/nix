local api = vim.api
local Canvas = require('hx.ui.canvas')
local C = require('hx.ui.compositor')
local T = require('hx.theme')
local U = require('hx.util')
local S = require('hx.state')
local F = require('hx.fuzzy')
local Prompt = require('hx.ui.prompt').Prompt

local M = {}
local MIN_AREA_WIDTH_FOR_PREVIEW = 72

local Picker = {}
Picker.__index = Picker
M.Picker = Picker

function Picker.new(opts)
  local self = setmetatable({
    id = 'picker',
    columns = opts.columns,
    primary = opts.primary or 1,
    items = {},
    matched = {},
    cursor = 0,
    on_select = opts.on_select,
    preview_fn = opts.preview,
    show_preview = true,
    dynamic = opts.dynamic,
    path_matching = opts.path_matching or false,
    truncate_start = opts.truncate_start ~= false,
    cursor_shape = 'bar',
    covers_cmdline = false,
    running = false,
    default_action = opts.default_action or 'replace',
    preview_cache = {},
    widths = {},
    generation = 0,
  }, Picker)
  self.prompt = Prompt.new({ prompt = '', register = opts.history_register, callback = function() end })
  for _, it in ipairs(opts.items or {}) do
    self.items[#self.items + 1] = it
  end
  self:refilter()
  return self
end

function Picker:column_text(item, col)
  local f = col.format(item)
  if type(f) == 'string' then return f, { { f, nil } } end
  local parts = {}
  for _, sp in ipairs(f) do
    parts[#parts + 1] = sp[1]
  end
  return table.concat(parts), f
end

function Picker:parse_query(line)
  local q = {}
  local primary = self.columns[self.primary].name
  local cur = primary
  local buf = {}
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '\\' and line:sub(i + 1, i + 1) == '%' then
      buf[#buf + 1] = '%'
      i = i + 2
    elseif c == '%' then
      local name = line:match('^%%([%w_]+)', i)
      local found
      if name then
        for _, col in ipairs(self.columns) do
          if col.name:sub(1, #name) == name and col.filter ~= false then found = col.name end
        end
      end
      if found then
        q[cur] = U.trim(table.concat(buf))
        buf = {}
        cur = found
        i = i + 1 + #name
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  local v = table.concat(buf)
  q[cur] = U.trim((q[cur] and (q[cur] .. ' ') or '') .. v)
  if q[primary] then q[primary] = q[primary]:gsub('^%s+', '') end
  return q
end

function Picker:refilter()
  local q = self:parse_query(self.prompt.line)
  self.query = q
  local atoms_by_col = {}
  local any = false
  for ci, col in ipairs(self.columns) do
    if col.filter ~= false then
      local pat = q[col.name] or ''
      if col.name == self.columns[self.primary].name and self.dynamic then pat = '' end
      if pat ~= '' then
        atoms_by_col[ci] = F.parse_pattern(pat)
        any = true
      end
    end
  end
  local res = {}
  for idx, it in ipairs(self.items) do
    if not any then
      res[#res + 1] = { idx = idx, score = 0 }
    else
      local total = 0
      local ok = true
      for ci, atoms in pairs(atoms_by_col) do
        local txt = self:column_text(it, self.columns[ci])
        local s = F.match_atoms(txt, atoms, self.path_matching)
        if not s then
          ok = false
          break
        end
        total = total + s
      end
      if ok then res[#res + 1] = { idx = idx, score = total } end
    end
  end
  if any then
    table.sort(res, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.idx < b.idx
    end)
  end
  self.atoms_by_col = atoms_by_col
  self.matched = res
  if self.cursor >= #res then self.cursor = math.max(0, #res - 1) end
end

function Picker:inject(items)
  for _, it in ipairs(items) do
    self.items[#self.items + 1] = it
  end
  self:refilter()
  self:schedule_render()
end

function Picker:clear_items()
  self.items = {}
  self.matched = {}
  self.cursor = 0
end

function Picker:schedule_render()
  if self.render_scheduled then return end
  self.render_scheduled = true
  vim.defer_fn(function()
    self.render_scheduled = false
    if C.find(self.id) == self then
      self:render()
      pcall(vim.cmd, 'redraw')
    end
  end, 15)
end

function Picker:selection()
  local m = self.matched[self.cursor + 1]
  if not m then return nil end
  return self.items[m.idx]
end

function Picker:move_by(n, forward)
  local len = #self.matched
  if len == 0 then return end
  if forward then
    self.cursor = (self.cursor + n) % len
  else
    self.cursor = (self.cursor + len - (n % len)) % len
  end
end

local function overlay_area()
  local scr = Canvas.screen()
  local w, h = scr.w, math.max(0, scr.h - 2)
  local iw = math.floor(w * 90 / 100)
  local ih = math.floor(h * 90 / 100)
  return { x = math.floor((w - iw) / 2), y = math.floor((h - ih) / 2), w = iw, h = ih }
end

local function header_height(self)
  local visible = 0
  for _, c in ipairs(self.columns) do
    visible = visible + 1
  end
  return visible > 1 and 1 or 0
end

function Picker:render()
  local area = overlay_area()
  self.completion_height = math.max(0, area.h - (4 + header_height(self)))
  local render_preview = self.show_preview and self.preview_fn ~= nil and area.w > MIN_AREA_WIDTH_FOR_PREVIEW
  local picker_w = render_preview and math.floor(area.w / 2) or area.w
  local bg = T.get('ui.background')
  local bg_group = T.group_for(bg)
  local c = Canvas.new(area.w, area.h, bg_group)
  self:render_picker(c, 0, 0, picker_w, area.h)
  if render_preview then self:render_preview(c, picker_w, 0, area.w - picker_w, area.h) end
  local win = Canvas.show('picker', c, area.y, area.x, { zindex = 25, focusable = true, normal = bg_group })
  self.focus_win = win
  if api.nvim_get_current_win() ~= win then C.refocus() end
  local col = 2 + vim.api.nvim_strwidth(self.prompt.line:sub(1, self.prompt.cursor))
  pcall(function()
    local l = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 1, 2, false)[1] or ''
    local b = 0
    local w = 0
    local i = 1
    while i <= #l and w < col do
      local _, n = U.decode(l, i)
      w = w + vim.api.nvim_strwidth(l:sub(i, i + n - 1))
      i = i + n
    end
    b = i - 1
    api.nvim_win_set_cursor(win, { 2, b })
  end)
end

local function style_patch(a, b)
  return T.patch(a or {}, b or {})
end

function Picker:render_picker(c, x, y, w, h)
  local text_style = T.get('ui.text')
  local bg = T.get('ui.background')
  local base = T.patch(bg, text_style)
  local selected = T.get('ui.text.focus')
  local hl_style = T.patch(T.get('special'), { mods = { bold = true } })
  c:clear(x, y, w, h, T.group_for(bg))
  c:border(x, y, w, h, T.group_for(bg))
  local ix, iy, iw, ih = x + 1, y + 1, w - 2, h - 2
  local count = ('%s%d/%d'):format(self.running and '(running) ' or '', #self.matched, #self.items)
  local line_w = math.max(0, iw - 1 - (#count + 1))
  local pr = self.prompt
  local line = pr.line
  local shown
  if line == '' then
    local sugg = pr:first_history()
    if sugg then c:put(ix + 1, iy, sugg, T.group_for(T.patch(bg, T.get('ui.text.inactive'))), line_w) end
  else
    local lw = vim.api.nvim_strwidth(line)
    shown = line
    if lw > line_w then shown = U.truncate(line:sub(math.max(1, pr.cursor - line_w + 2)), line_w) end
    c:put(ix + 1, iy, shown, T.group_for(base), line_w)
  end
  c:put(ix + iw - (#count + 1), iy, count, T.group_for(base), #count)
  local sep = T.get('ui.background.separator')
  for xx = ix, ix + iw - 1 do
    c:put(xx, iy + 1, '─', T.group_for(T.patch(bg, sep)))
  end
  local ty = iy + 2
  local th = ih - 2
  local hh = header_height(self)
  local rows = math.max(1, th - hh)
  local offset = self.cursor - (self.cursor % rows)
  local cursor = self.cursor - offset
  local last = math.min(offset + rows, #self.matched)
  local visible_cols = {}
  for ci, col in ipairs(self.columns) do
    if not col.hidden then visible_cols[#visible_cols + 1] = ci end
  end
  local cells = {}
  for r = offset + 1, last do
    local it = self.items[self.matched[r].idx]
    local rowcells = {}
    for _, ci in ipairs(visible_cols) do
      local col = self.columns[ci]
      local txt, spans = self:column_text(it, col)
      local atoms = self.atoms_by_col and self.atoms_by_col[ci]
      if atoms then
        local _, idx = F.match_atoms(txt, atoms, self.path_matching, true)
        local set = {}
        for _, k in ipairs(idx or {}) do
          set[k] = true
        end
        local out = {}
        local g = 0
        for _, sp in ipairs(spans) do
          for _, cp in U.chars(sp[1]) do
            g = g + 1
            local st = sp[2] or {}
            if set[g] then st = style_patch(st, hl_style) end
            out[#out + 1] = { U.encode(cp), st }
          end
        end
        spans = out
      end
      local cw = vim.api.nvim_strwidth(txt)
      self.widths[ci] = math.max(self.widths[ci] or 0, cw)
      rowcells[#rowcells + 1] = { spans = spans, width = cw }
    end
    cells[#cells + 1] = rowcells
  end
  local sym = ' > '
  local cy = ty
  if hh > 0 then
    local hst = T.get('ui.picker.header')
    local cx = ix + #sym
    for _, ci in ipairs(visible_cols) do
      local col = self.columns[ci]
      local w0 = self.widths[ci] or #col.name
      w0 = math.max(w0, #col.name)
      self.widths[ci] = w0
      local active = self.query and self.query[col.name] and self.prompt.line:find('%%' .. col.name:sub(1, 1))
      local st = active and T.get('ui.picker.header.column.active') or T.get('ui.picker.header.column')
      c:put(cx, cy, col.name, T.group_for(T.patch(base, T.patch(hst, st))), w0)
      cx = cx + w0 + 1
    end
    cy = cy + 1
  end
  for r, rowcells in ipairs(cells) do
    local is_sel = (r - 1) == cursor
    local row_style = is_sel and T.patch(base, selected) or base
    c:style(ix, cy, iw, 1, T.group_for(row_style))
    local cx = ix
    c:put(cx, cy, is_sel and sym or '   ', T.group_for(row_style), iw)
    cx = cx + #sym
    for k, ci in ipairs(visible_cols) do
      local cell = rowcells[k]
      local colw = self.widths[ci] or cell.width
      local avail = math.max(0, ix + iw - cx)
      if k == #visible_cols then colw = avail end
      colw = math.min(colw, avail)
      local spans = cell.spans
      local total = cell.width
      if total > colw and self.truncate_start and colw > 1 then
        local drop = total - colw + 1
        local out = { { '…', {} } }
        local acc = 0
        for _, sp in ipairs(spans) do
          local s = sp[1]
          for _, cp in U.chars(s) do
            local ch = U.encode(cp)
            local cwid = vim.api.nvim_strwidth(ch)
            if acc >= drop then
              out[#out + 1] = { ch, sp[2] }
            end
            acc = acc + cwid
          end
        end
        spans = out
      end
      local px = cx
      for _, sp in ipairs(spans) do
        local st = T.patch(row_style, sp[2] or {})
        px = c:put(px, cy, sp[1], T.group_for(st), math.max(0, cx + colw - px))
      end
      cx = cx + colw + 1
      if cx >= ix + iw then break end
    end
    cy = cy + 1
  end
end

local function read_file_preview(path)
  local st = vim.uv.fs_stat(path)
  if not st then return { kind = 'notfound' } end
  if st.type == 'directory' then
    local out = {}
    local ok, items = pcall(require('hx.walk').dir, path, require('hx.walk').opts_from({}))
    if ok then
      local root = (vim.fn.fnamemodify(path, ':p'):gsub('(.)/$', '%1'))
      for _, it in ipairs(items) do
        local p, d = it[1], it[2]
        local name = p:sub(#root + 2)
        if name == '' then name = vim.fn.fnamemodify(p, ':t') end
        out[#out + 1] = { d and (name .. '/') or name, d }
      end
    end
    return { kind = 'dir', entries = out }
  end
  if st.size > 10 * 1024 * 1024 then return { kind = 'large' } end
  local f = io.open(path, 'rb')
  if not f then return { kind = 'notfound' } end
  local data = f:read('*a')
  f:close()
  if data:sub(1, 1024):find('\0', 1, true) then return { kind = 'binary' } end
  local ft = vim.filetype.match({ filename = path, contents = vim.split(data:sub(1, 2000), '\n') })
  return { kind = 'doc', text = data, ft = ft }
end

function Picker:get_preview()
  local item = self:selection()
  if not item then return nil end
  local loc = self.preview_fn(item)
  if not loc then return nil end
  if loc.buf and api.nvim_buf_is_valid(loc.buf) then
    local lines = api.nvim_buf_get_lines(loc.buf, 0, -1, false)
    return { kind = 'doc', lines = lines, ft = vim.bo[loc.buf].filetype, buf = loc.buf }, loc.range
  end
  if loc.path then
    local b = vim.fn.bufnr(loc.path)
    if b > 0 and api.nvim_buf_is_loaded(b) then
      return { kind = 'doc', lines = api.nvim_buf_get_lines(b, 0, -1, false), ft = vim.bo[b].filetype, buf = b }, loc.range
    end
    local p = self.preview_cache[loc.path]
    if not p then
      p = read_file_preview(loc.path)
      if p.kind == 'doc' then
        p.lines = vim.split(p.text, '\n', { plain = true })
        if p.lines[#p.lines] == '' then p.lines[#p.lines] = nil end
        p.text = nil
      end
      self.preview_cache[loc.path] = p
    end
    return p, loc.range
  end
  return nil
end

local function highlight_lines(p, first, last)
  if not p.ft or p.ft == '' then return nil end
  local lang = vim.treesitter.language.get_lang(p.ft) or p.ft
  if not pcall(vim.treesitter.language.add, lang) then return nil end
  local Syn = require('hx.syntax')
  local q = Syn.get_query(lang, 'highlights')
  if not q then return nil end
  p.full = p.full or (table.concat(p.lines, '\n') .. '\n')
  if not p.tree then
    local ok, parser = pcall(vim.treesitter.get_string_parser, p.full, lang)
    if not ok then return nil end
    p.parser = parser
    p.tree = parser:parse()[1]
  end
  if not p.tree then return nil end
  return Syn.capture_spans(p.tree:root(), p.full, q, first, last)
end

function Picker:render_preview(c, x, y, w, h)
  local bg = T.get('ui.background')
  local text_style = T.patch(bg, T.get('ui.text'))
  local dir_style = T.patch(bg, T.get('ui.text.directory'))
  c:clear(x, y, w, h, T.group_for(bg))
  c:border(x, y, w, h, T.group_for(bg))
  local ix, iy, iw, ih = x + 2, y + 1, w - 4, h - 2
  local p, range = self:get_preview()
  if not p then return end
  if p.kind ~= 'doc' or (range and not (range[1] <= range[2] and range[2] <= #p.lines + 1)) then
    if p.kind == 'dir' then
      for i, e in ipairs(p.entries) do
        if i > ih then break end
        c:put(ix, iy + i - 1, e[1], T.group_for(e[2] and dir_style or text_style), iw)
      end
      return
    end
    local alt = ({ binary = '<Binary file>', large = '<File too large to preview>', notfound = '<File not found>' })[p.kind]
      or '<Invalid file location>'
    c:put(ix + math.floor(math.max(0, iw - #alt) / 2), iy + math.floor(ih / 2), alt, T.group_for(text_style), iw)
    return
  end
  local first = 0
  if range then
    local s, e = range[1], range[2]
    local height = e - s
    if height < ih then
      local middle = s + math.floor(height / 2)
      first = math.max(0, middle - math.floor(ih / 2))
      if s < first then first = s end
    else
      first = s
    end
  end
  local last = math.min(#p.lines - 1, first + ih - 1)
  local spans = highlight_lines(p, first, last)
  local by_row = {}
  if spans then
    for _, sp in ipairs(spans) do
      for r = math.max(sp[1], first), math.min(sp[3], last) do
        by_row[r] = by_row[r] or {}
        table.insert(by_row[r], { r == sp[1] and sp[2] or 0, r == sp[3] and sp[4] or math.huge, sp[5], sp[6] })
      end
    end
  end
  local hl_range = range and (T.try_get('ui.highlight') or T.get('ui.selection'))
  local ts = 4
  for row = first, last do
    local sy = iy + (row - first)
    local l = p.lines[row + 1] or ''
    local line_style = text_style
    if range and row >= range[1] and row <= range[2] then line_style = T.patch(text_style, hl_range) end
    if range and row >= range[1] and row <= range[2] then c:style(ix, sy, iw, 1, T.group_for(line_style)) end
    local caps = by_row[row]
    local cx = ix
    local i = 1
    local vcol = 0
    while i <= #l and cx < ix + iw do
      local cp, n = U.decode(l, i)
      local ch = l:sub(i, i + n - 1)
      local st = line_style
      if caps then
        local best, bd
        for _, cap in ipairs(caps) do
          if i - 1 >= cap[1] and i - 1 < cap[2] and (not bd or cap[4] >= bd) then
            best, bd = cap[3], cap[4]
          end
        end
        if best then st = T.patch(line_style, T.get(best)) end
      end
      if cp == 9 then
        local tw = ts - vcol % ts
        cx = c:put(cx, sy, string.rep(' ', tw), T.group_for(st), ix + iw - cx)
        vcol = vcol + tw
      else
        cx = c:put(cx, sy, ch, T.group_for(st), ix + iw - cx)
        vcol = vcol + vim.api.nvim_strwidth(ch)
      end
      i = i + n
    end
  end
end

function Picker:close()
  Canvas.hide('picker')
  self.focus_win = nil
  self.generation = self.generation + 1
  if self.on_close then pcall(self.on_close) end
end

function Picker:prompt_changed(is_paste)
  local old = self.last_line
  if old == self.prompt.line then return end
  self.last_line = self.prompt.line
  self.cursor = 0
  self:refilter()
  if self.dynamic then self:run_dynamic(is_paste) end
end

function Picker:run_dynamic(immediate)
  local q = self.query[self.columns[self.primary].name] or ''
  self.dyn_token = (self.dyn_token or 0) + 1
  local token = self.dyn_token
  local function go()
    if token ~= self.dyn_token then return end
    if q == self.last_dynamic_query then return end
    self.last_dynamic_query = q
    self.generation = self.generation + 1
    local gen = self.generation
    self:clear_items()
    self.running = true
    self:schedule_render()
    self.dynamic.fn(q, function(items)
      if gen ~= self.generation then return false end
      self:inject(items)
      return true
    end, function(err)
      if gen ~= self.generation then return end
      self.running = false
      if err then S.set_status(err, 'error') end
      self:schedule_render()
    end)
  end
  if immediate or not self.dynamic.debounce then
    go()
  else
    vim.defer_fn(go, self.dynamic.debounce)
  end
end

function Picker:handle_paste(s)
  self.prompt:insert_str(s)
  self:prompt_changed(true)
  self:render()
end

function Picker:finish()
  if #self.items <= 1000000 then M.last_picker = self end
  C.remove(self)
end

function Picker:handle_key(key)
  if key == 'S-tab' or key == 'up' or key == 'C-p' then
    self:move_by(1, false)
  elseif key == 'tab' or key == 'down' or key == 'C-n' then
    self:move_by(1, true)
  elseif key == 'pagedown' or key == 'C-d' then
    self:move_by(self.completion_height or 10, true)
  elseif key == 'pageup' or key == 'C-u' then
    self:move_by(self.completion_height or 10, false)
  elseif key == 'home' then
    self.cursor = 0
  elseif key == 'end' then
    self.cursor = math.max(0, #self.matched - 1)
  elseif key == 'esc' or key == 'C-c' then
    self:finish()
  elseif key == 'A-ret' then
    local it = self:selection()
    if it then self.on_select(it, self.default_action) end
  elseif key == 'ret' then
    local hist = self.prompt:first_history()
    if hist and self.prompt.line == '' then
      self.prompt:set_line((hist:gsub('%%', '\\%%')))
      self:prompt_changed(true)
    else
      local it = self:selection()
      local reg = self.prompt.history_register
      self:finish()
      if it then self.on_select(it, self.default_action) end
      if reg then
        local q = self.query and self.query[self.columns[self.primary].name] or ''
        require('hx.registers').push(reg, q)
      end
      return true
    end
  elseif key == 'C-s' then
    local it = self:selection()
    self:finish()
    if it then self.on_select(it, 'hsplit') end
    return true
  elseif key == 'C-v' then
    local it = self:selection()
    self:finish()
    if it then self.on_select(it, 'vsplit') end
    return true
  elseif key == 'C-t' then
    self.show_preview = not self.show_preview
  else
    self.prompt:handle_key(key)
    self:prompt_changed(false)
  end
  if C.find(self.id) == self then self:render() end
  return true
end

function M.open(opts)
  local p = Picker.new(opts)
  p.prompt.finish = function() end
  p.last_line = ''
  C.push(p)
  if p.dynamic then p:run_dynamic(true) end
  return p
end

function M.reopen_last()
  local p = M.last_picker
  if not p then return false end
  p.generation = p.generation + 1
  C.push(p)
  return true
end

return M
