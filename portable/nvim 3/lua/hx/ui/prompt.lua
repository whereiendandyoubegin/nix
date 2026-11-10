local api = vim.api
local Canvas = require('hx.ui.canvas')
local C = require('hx.ui.compositor')
local S = require('hx.state')
local T = require('hx.theme')
local U = require('hx.util')
local K = require('hx.keys')
local Regs = require('hx.registers')

local M = {}

local Prompt = {}
Prompt.__index = Prompt
M.Prompt = Prompt

local BASE_WIDTH = 30

function Prompt.new(opts)
  local self = setmetatable({
    id = 'prompt',
    prompt = opts.prompt or '',
    line = opts.line or '',
    cursor = 0,
    anchor = 0,
    completion = {},
    selection = nil,
    history_register = opts.register,
    history_pos = nil,
    completion_fn = opts.completion or function() return {} end,
    callback_fn = opts.callback or function() end,
    doc_fn = opts.doc or function() return nil end,
    language = opts.language,
    covers_cmdline = true,
    cursor_shape = 'bar',
  }, Prompt)
  self.cursor = #self.line
  return self
end

function Prompt:recalculate_completion()
  self.selection = nil
  local ok, res = pcall(self.completion_fn, self.line)
  self.completion = ok and res or {}
end

local function is_word_sep(cp)
  return cp == 47 or U.rust_whitespace(cp)
end

local function char_indices(s)
  local out = {}
  for i, cp in U.chars(s) do
    out[#out + 1] = { i - 1, cp }
  end
  return out
end

function Prompt:eval_movement(kind, rep)
  rep = rep or 1
  local line = self.line
  if kind == 'bchar' then
    local p = self.cursor
    for _ = 1, rep do
      if p == 0 then break end
      p = U.prev_boundary(line, p)
    end
    return p
  elseif kind == 'fchar' then
    local p = self.cursor
    for _ = 1, rep do
      if p >= #line then break end
      p = U.next_boundary(line, p)
    end
    return p
  elseif kind == 'bword' then
    local ci = char_indices(line)
    if #ci == 0 then return self.cursor end
    local pos = #ci - 1
    for idx, e in ipairs(ci) do
      if e[1] == self.cursor then
        pos = idx - 1
        break
      end
    end
    for _ = 1, rep do
      if pos == 0 then break end
      local found
      for prev = pos - 2, 0, -1 do
        if is_word_sep(ci[prev + 1][2]) then
          found = prev + 1
          break
        end
      end
      pos = found or 0
    end
    return ci[pos + 1][1]
  elseif kind == 'fword' then
    local ci = char_indices(line)
    if #ci == 0 then return self.cursor end
    local pos = #ci
    for idx, e in ipairs(ci) do
      if e[1] == self.cursor then
        pos = idx - 1
        break
      end
    end
    for _ = 1, rep do
      while pos < #ci and not is_word_sep(ci[pos + 1][2]) do
        pos = pos + 1
      end
      while pos < #ci and is_word_sep(ci[pos + 1][2]) do
        pos = pos + 1
      end
    end
    if ci[pos + 1] then return ci[pos + 1][1] end
    return #line
  elseif kind == 'start' then
    return 0
  elseif kind == 'end' then
    return #line
  end
  return self.cursor
end

function Prompt:insert_str(s)
  self.line = self.line:sub(1, self.cursor) .. s .. self.line:sub(self.cursor + 1)
  self.cursor = self.cursor + #s
  self:recalculate_completion()
end

function Prompt:insert_char(ch)
  if self.next_char_handler then
    local h = self.next_char_handler
    self.next_char_handler = nil
    h(self, ch)
    return
  end
  self:insert_str(ch)
end

function Prompt:replace_range(a, b, s)
  self.line = self.line:sub(1, a) .. (s or '') .. self.line:sub(b + 1)
end

function Prompt:set_line(line)
  self.line = line
  self.cursor = #line
  self:recalculate_completion()
end

function Prompt:first_history()
  if not self.history_register then return nil end
  return Regs.first(self.history_register)
end

function Prompt:change_history(register, forward)
  self.callback_fn(self.line, 'abort')
  local values = Regs.read(register)
  if not values or #values == 0 then return end
  local rev = {}
  for i = #values, 1, -1 do
    rev[#rev + 1] = values[i]
  end
  local endi = #rev - 1
  local index
  if forward then
    index = self.history_pos and (self.history_pos + 1) or 0
  else
    index = math.max(0, (self.history_pos or #rev) - 1)
  end
  index = math.min(index, endi)
  self.line = rev[index + 1]
  self.history_pos = index
  self.cursor = #self.line
  self.callback_fn(self.line, 'update')
  self:recalculate_completion()
end

function Prompt:change_completion_selection(forward)
  if #self.completion == 0 then return end
  local n = #self.completion
  local idx
  if forward then
    idx = self.selection and (self.selection + 1) or 0
  else
    idx = (self.selection or 0) + n - 1
  end
  idx = idx % n
  self.selection = idx
  local item = self.completion[idx + 1]
  self:replace_range(item[1], #self.line, item[2])
  self.line = self.line:sub(1, item[1]) .. item[2]
  self.cursor = #self.line
end

function Prompt:render()
  local scr = Canvas.screen()
  local W, H = scr.w, scr.h
  local bg = T.get('ui.background')
  local text_style = T.get('ui.text')
  local menu = T.get('ui.menu')
  local selected = T.get('ui.menu.selected')
  local max_len = BASE_WIDTH
  for _, c in ipairs(self.completion) do
    max_len = math.max(max_len, #c[2])
  end
  local cols = math.max(1, math.floor(W / max_len))
  local col_width = math.floor((W - cols) / cols)
  local height = math.min(math.ceil(#self.completion / cols), 10, H - 1)
  local comp_y = math.max(0, (H - height) - 1)
  if height > 0 and #self.completion > 0 then
    local items = height * cols
    local offset = self.selection and (math.floor(self.selection / items) * items) or 0
    local menu_group = T.group_for(menu)
    local c = Canvas.new(W, height, menu_group)
    local row, col = 0, 0
    for i = offset, math.min(#self.completion - 1, offset + items - 1) do
      local item = self.completion[i + 1]
      local is_sel = i == self.selection
      local st = is_sel and selected or T.patch(menu, item.style or {})
      c:put(col * (1 + col_width), row, item[2], T.group_for(st), math.max(0, col_width - 1))
      row = row + 1
      if row > height - 1 then
        row = 0
        col = col + 1
      end
    end
    Canvas.show('prompt_completion', c, comp_y, 0, { zindex = 70 })
  else
    Canvas.hide('prompt_completion')
  end
  local doc = self.doc_fn(self.line)
  if doc then
    local max_width = BASE_WIDTH * 3
    local text_width = max_width - 4
    local lines = U.split_lines(doc)
    local wrapped = {}
    for _, l in ipairs(lines) do
      local Text = require('hx.ui.text')
      for _, wl in ipairs(Text.wrap(l, text_width)) do
        wrapped[#wrapped + 1] = wl
      end
    end
    local h = #wrapped + 2
    local y = math.max(0, comp_y - h)
    local w = math.min(max_width, W)
    h = math.min(h, H - y)
    local help = T.group_for(T.get('ui.help'))
    local c = Canvas.new(w, h, help)
    c:border(0, 0, w, h, help)
    for i, l in ipairs(wrapped) do
      if i > h - 2 then break end
      c:put(2, i, l, T.group_for(T.get('ui.text')), w - 4)
    end
    Canvas.show('prompt_doc', c, y, 0, { zindex = 71 })
  else
    Canvas.hide('prompt_doc')
  end
  local line_group = T.group_for(bg)
  local c = Canvas.new(W, 1, line_group)
  local pw = vim.api.nvim_strwidth(self.prompt)
  c:put(0, 0, self.prompt, T.group_for(T.patch(bg, text_style)))
  local line_area_w = math.max(0, W - pw - 2)
  local text_group = T.group_for(T.patch(bg, text_style))
  self.truncate_start, self.truncate_end = false, false
  if self.line == '' then
    self.anchor = 0
    local sugg = self:first_history()
    if sugg then
      c:put(pw, 0, sugg, T.group_for(T.patch(bg, T.get('ui.text.inactive'))), line_area_w)
    end
  else
    local line = self.line
    local lw = vim.api.nvim_strwidth(line)
    if lw < line_area_w then
      self.anchor = 0
    elseif self.cursor <= self.anchor then
      self.anchor = U.prev_boundary(line, self.cursor)
      if self.cursor == 0 then self.anchor = 0 end
    elseif vim.api.nvim_strwidth(line:sub(self.anchor + 1, self.cursor)) > line_area_w then
      local w = 0
      local idx = self.cursor
      while idx > 0 do
        local p = U.prev_boundary(line, idx)
        w = w + vim.api.nvim_strwidth(line:sub(p + 1, idx))
        if w > line_area_w then
          self.anchor = idx
          break
        end
        idx = p
      end
    end
    self.truncate_start = self.anchor > 0
    self.truncate_end = vim.api.nvim_strwidth(line:sub(self.anchor + 1)) > line_area_w
    if self.truncate_end and vim.api.nvim_strwidth(line:sub(self.anchor + 1, self.cursor)) >= line_area_w then
      self.anchor = U.next_boundary(line, self.anchor)
    end
    local visible = line:sub(self.anchor + 1)
    local spans
    if self.language then
      spans = require('hx.ui.markdown').highlight_code(visible, self.language, T.patch(bg, text_style))
    end
    if spans then
      c:put_spans(pw, 0, spans, line_area_w)
    else
      c:put(pw, 0, visible, text_group, line_area_w)
    end
    if self.truncate_start then c:put(pw, 0, '…', text_group) end
    if self.truncate_end then c:put(pw + line_area_w - 1, 0, '…', text_group) end
  end
  local win = Canvas.show('prompt_line', c, H - 1, 0, { zindex = 80, focusable = true, normal = 'HxCmdline' })
  self.focus_win = win
  local col = pw + vim.api.nvim_strwidth(self.line:sub(self.anchor + 1, self.cursor))
  if self.truncate_end and vim.api.nvim_strwidth(self.line:sub(self.anchor + 1, self.cursor)) >= line_area_w then
    col = col - 1
  end
  if self.truncate_start and self.cursor == self.anchor then col = col + 1 end
  self.cursor_col = col
  if api.nvim_get_current_win() ~= win then C.refocus() end
  pcall(function()
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, 1, false)
    local l = lines[1] or ''
    local byte = vim.fn.byteidx(l, vim.fn.charidx(l, 0))
    local bcol = 0
    local w = 0
    local i = 1
    while i <= #l and w < col do
      local _, n = U.decode(l, i)
      w = w + vim.api.nvim_strwidth(l:sub(i, i + n - 1))
      i = i + n
    end
    bcol = i - 1
    if w < col then
      api.nvim_win_set_cursor(win, { 1, #l })
      vim.api.nvim_win_call(win, function()
        vim.fn.cursor(1, #l + 1 + (col - w))
      end)
    else
      api.nvim_win_set_cursor(win, { 1, bcol })
    end
    local _ = byte
  end)
end

function Prompt:close()
  Canvas.hide('prompt_line')
  Canvas.hide('prompt_completion')
  Canvas.hide('prompt_doc')
  self.focus_win = nil
end

function Prompt:finish()
  C.remove(self)
end

function Prompt:handle_paste(s)
  self:insert_str(s)
  self.callback_fn(self.line, 'update')
end

function Prompt:handle_key(key)
  local cb = function(ev)
    self.callback_fn(self.line, ev)
  end
  if key == 'C-c' or key == 'esc' then
    cb('abort')
    self:finish()
    return true
  elseif key == 'A-b' or key == 'C-left' then
    self.cursor = self:eval_movement('bword')
  elseif key == 'A-f' or key == 'C-right' then
    self.cursor = self:eval_movement('fword')
  elseif key == 'C-b' or key == 'left' then
    self.cursor = self:eval_movement('bchar')
  elseif key == 'C-f' or key == 'right' then
    self.cursor = self:eval_movement('fchar')
  elseif key == 'C-e' or key == 'end' then
    self.cursor = #self.line
  elseif key == 'C-a' or key == 'home' then
    self.cursor = 0
  elseif key == 'C-w' or key == 'A-backspace' or key == 'C-backspace' then
    local p = self:eval_movement('bword')
    self:replace_range(p, self.cursor, '')
    self.cursor = p
    self:recalculate_completion()
    cb('update')
  elseif key == 'A-d' or key == 'A-del' or key == 'C-del' then
    local p = self:eval_movement('fword')
    self:replace_range(self.cursor, p, '')
    self:recalculate_completion()
    cb('update')
  elseif key == 'C-k' then
    self:replace_range(self.cursor, #self.line, '')
    self:recalculate_completion()
    cb('update')
  elseif key == 'C-u' then
    self:replace_range(0, self.cursor, '')
    self.cursor = 0
    self:recalculate_completion()
    cb('update')
  elseif key == 'C-h' or key == 'backspace' or key == 'S-backspace' then
    local p = self:eval_movement('bchar')
    self:replace_range(p, self.cursor, '')
    self.cursor = p
    self:recalculate_completion()
    cb('update')
  elseif key == 'C-d' or key == 'del' then
    local p = self:eval_movement('fchar')
    self:replace_range(self.cursor, p, '')
    self:recalculate_completion()
    cb('update')
  elseif key == 'C-s' then
    local E = require('hx.editor')
    local tobj = require('hx.commands')
    tobj.load()
    local text = E.text()
    local r = tobj.textobject.textobject_word(text, E.sel():prim(), true, false)
    local word = text:slice(r:from(), r:to())
    if word ~= '' then
      self:insert_str(word)
      cb('update')
    end
  elseif key == 'ret' then
    if self.selection and self.line:sub(-1) == '/' then
      self:recalculate_completion()
    else
      local last = self:first_history() or ''
      local input
      if self.line == '' then
        input = last
      else
        if last ~= self.line and self.history_register then
          local ok, err = Regs.push(self.history_register, self.line)
          if not ok then S.set_status(err, 'error') end
        end
        input = self.line
      end
      self.callback_fn(input, 'validate')
      self:finish()
      return true
    end
  elseif key == 'C-p' or key == 'up' then
    if self.history_register then self:change_history(self.history_register, false) end
  elseif key == 'C-n' or key == 'down' then
    if self.history_register then self:change_history(self.history_register, true) end
  elseif key == 'tab' then
    self:change_completion_selection(true)
    if #self.completion == 1 and self.line:sub(-1) == '/' then self:recalculate_completion() end
    cb('update')
  elseif key == 'S-tab' then
    self:change_completion_selection(false)
    cb('update')
  elseif key == 'C-q' then
    self.selection = nil
  elseif key == 'C-r' then
    local comp = {}
    for _, e in ipairs(Regs.preview()) do
      comp[#comp + 1] = { 0, e[1] .. ' ' .. e[2] }
    end
    self.completion = comp
    self.next_char_handler = function(p, c)
      p:insert_str(Regs.first(c) or '')
    end
    cb('update')
  else
    local p = K.parse(key)
    local ch = K.code_char(p.code)
    if ch then
      self:insert_char(ch)
      cb('update')
    end
  end
  return true
end

function M.open(opts)
  local p = Prompt.new(opts)
  p:recalculate_completion()
  C.push(p)
  return p
end

function M.regex_prompt(opts)
  local E = require('hx.editor')
  local D = require('hx.doc')
  local RE = require('hx.regex')
  local win, buf = E.win(), E.buf()
  local snapshot = E.sel():copy()
  local view_snapshot = api.nvim_win_call(win, vim.fn.winsaveview)
  local smart = S.config.editor.search == nil or S.config.editor.search['smart-case'] ~= false
  local p
  p = M.open({
    prompt = opts.prompt,
    register = opts.register,
    completion = opts.completion,
    language = 'regex',
    callback = function(input, event)
      if event == 'abort' then
        S.set_sel(snapshot, win, buf)
        api.nvim_win_call(win, function()
          vim.fn.winrestview(view_snapshot)
        end)
        return
      end
      if input == '' then return end
      local ci = false
      if smart then
        ci = true
        for _, cp in U.chars(input) do
          if U.is_upper(cp) then
            ci = false
            break
          end
        end
      end
      local regex, err = RE.new(input, { ci = ci })
      if regex then
        S.set_sel(snapshot, win, buf)
        if event == 'validate' then
          local v = S.view(win)
          local cur = S.get_sel(win, buf)
          S.set_sel(snapshot, win, buf)
          D.push_jump(win, buf)
          S.set_sel(cur, win, buf)
        end
        opts.callback(regex, event)
        require('hx.render').sync_cursor(win)
      else
        S.set_sel(snapshot, win, buf)
        api.nvim_win_call(win, function()
          vim.fn.winrestview(view_snapshot)
        end)
        if event == 'validate' then
          vim.schedule(function()
            local Popup = require('hx.ui.popup')
            local scr = Canvas.screen()
            Popup.text('invalid-regex', tostring(err), { row = scr.h - 2, col = 0, auto_close = true })
            require('hx.input').after_key()
          end)
        end
      end
    end,
  })
  return p
end

return M
