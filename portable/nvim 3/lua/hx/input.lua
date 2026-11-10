local api = vim.api
local S = require('hx.state')
local K = require('hx.keys')
local KM = require('hx.keymap')
local C = require('hx.ui.compositor')

local M = {}

local view = {
  pending = {},
  sticky = nil,
  count = nil,
  register = nil,
  on_next_key = nil,
  pseudo_pending = {},
  last_insert = { cmd = nil, keys = {} },
}
M.view = view

M.recording = nil
M.replaying = {}

M.autoinfo = nil

local function exec_cmd(value, ctx)
  local Cmd = require('hx.commands')
  if type(value) == 'table' and value.seq then
    for _, v in ipairs(value.seq) do
      exec_cmd(v, ctx)
    end
    return
  end
  if type(value) ~= 'string' then return end
  if value:sub(1, 1) == ':' then
    require('hx.typed').execute_line(value:sub(2), ctx, true)
  elseif value:sub(1, 1) == '@' then
    local keys = K.parse_macro(value:sub(2))
    if keys then
      if vim.tbl_contains(M.replaying, '@') then
        S.set_status('Cannot execute macro because the [@] register is already used', 'error')
        return
      end
      table.insert(M.replaying, '@')
      for _, k in ipairs(keys) do
        M.feed(k, true)
      end
      table.remove(M.replaying)
    end
  else
    Cmd.run(value, ctx)
  end
end
M.exec_cmd = exec_cmd

local Ctx = {}
Ctx.__index = Ctx
function Ctx:get_count()
  return self.count or 1
end
function Ctx:on_next(fn, kind)
  self.on_next_key = { fn, kind or 'pseudo' }
end
function Ctx:push_callback(fn)
  table.insert(self.callbacks, fn)
end

local function new_ctx()
  return setmetatable({ count = nil, register = nil, callbacks = {}, on_next_key = nil }, Ctx)
end
M.new_ctx = new_ctx

local function set_autoinfo(n)
  if n then
    M.autoinfo = KM.infobox(n)
  else
    M.autoinfo = nil
  end
end

local function keymap_get(mode, key)
  local root = KM.maps[mode]
  if key == 'esc' then
    if #view.pending > 0 then
      local p = view.pending
      view.pending = {}
      return 'cancelled', p
    end
    view.sticky = nil
  end
  local first = view.pending[1] or key
  local trie = view.sticky or root
  local t = trie.map[first]
  if t == nil then return 'notfound' end
  if type(t) == 'string' then return 'matched', t end
  if type(t) == 'table' and t.seq then return 'sequence', t end
  table.insert(view.pending, key)
  local rest = { unpack(view.pending, 2) }
  local r = KM.search(t, rest)
  if type(r) == 'table' and r.is_node then
    if r.sticky then
      view.pending = {}
      view.sticky = r
    end
    return 'pending', r
  elseif type(r) == 'string' then
    view.pending = {}
    return 'matched', r
  elseif type(r) == 'table' and r.seq then
    view.pending = {}
    return 'sequence', r
  end
  local p = view.pending
  view.pending = {}
  return 'cancelled', p
end

local function handle_keymap_event(mode, ctx, key)
  local last_mode = mode
  local kind, res = keymap_get(mode, key)
  if view.sticky then
    set_autoinfo(view.sticky)
  else
    M.autoinfo = nil
  end
  local function execute(cmd)
    exec_cmd(cmd, ctx)
    local ev = require('hx.events')
    ev.post_command(type(cmd) == 'string' and cmd or '', ctx)
    local cur = S.mode
    if cur ~= last_mode then
      ev.mode_switch(last_mode, cur, ctx)
      if cur == 'insert' then
        view.last_insert.cmd = cmd
        view.last_insert.keys = {}
      end
    end
    last_mode = cur
  end
  if kind == 'matched' then
    execute(res)
  elseif kind == 'pending' then
    set_autoinfo(res)
  elseif kind == 'sequence' then
    for _, c in ipairs(res.seq) do
      execute(c)
    end
  else
    return kind, res
  end
  return nil
end

local function insert_mode_key(ctx, key)
  local kind, res = handle_keymap_event('insert', ctx, key)
  if kind == 'notfound' then
    local on = view.on_next_key
    if on and on[2] == 'fallback' then
      view.on_next_key = nil
      on[1](ctx, key)
    else
      local ch = K.char(key)
      if ch then require('hx.commands').insert_char(ctx, ch) end
    end
  elseif kind == 'cancelled' then
    for _, ev in ipairs(res) do
      local ch = K.char(ev)
      if ch then
        require('hx.commands').insert_char(ctx, ch)
      else
        local r = KM.maps.insert.map[ev]
        if type(r) == 'string' then exec_cmd(r, ctx) end
      end
    end
  end
end

local function command_mode_key(mode, ctx, key)
  local digit = key:match('^%d$')
  if digit and view.count then
    local n = view.count * 10 + tonumber(digit)
    if n > 100000000 then return end
    view.count = n
    return
  end
  if digit and digit ~= '0' and not view.count and #view.pending == 0 and not (view.sticky or KM.maps[mode]).map[key] then
    view.count = tonumber(digit)
    return
  end
  if key == '.' and #view.pending == 0 then
    local n = view.count or 1
    for _ = 1, n do
      local li = view.last_insert
      require('hx.lsp.completion').replay_begin()
      if li.cmd then
        local c2 = new_ctx()
        exec_cmd(li.cmd, c2)
        for _, ev in ipairs(li.keys) do
          if type(ev) == 'string' then
            insert_mode_key(new_ctx(), ev)
          elseif type(ev) == 'table' and ev.completion then
            require('hx.lsp.completion').replay(ev)
          end
        end
      end
    end
    view.count = nil
    return
  end
  ctx.count = view.count
  ctx.register = view.register
  view.register = nil
  local kind = handle_keymap_event(mode, ctx, key)
  if kind == 'notfound' then
    local on = view.on_next_key
    if on and on[2] == 'fallback' then
      view.on_next_key = nil
      on[1](ctx, key)
    end
  end
  if #view.pending == 0 then
    view.count = nil
  else
    view.register = ctx.register
  end
end

local function editor_handle(key)
  local ctx = new_ctx()
  S.status = nil
  local mode = S.mode
  local handled = false
  local on = view.on_next_key
  if on and on[2] == 'pseudo' then
    view.on_next_key = nil
    on[1](ctx, key)
    handled = true
  end
  if not handled then
    if mode == 'insert' then
      local consumed = false
      local comp = require('hx.lsp.completion')
      if comp.completion then
        local close
        local c1, cl1 = comp.handle_event(key)
        if c1 then
          consumed = true
          close = cl1
        else
          local c2, cl2 = comp.handle_event('ret')
          if c2 then close = cl2 end
        end
        if close then
          local cb = comp.clear_completion()
          if cb then
            if consumed then
              ctx.on_next_key = { cb, 'fallback' }
            else
              view.on_next_key = { cb, 'fallback' }
            end
          end
        end
      end
      if not consumed then
        insert_mode_key(ctx, key)
        table.insert(view.last_insert.keys, key)
      end
    else
      command_mode_key(mode, ctx, key)
    end
  end
  view.on_next_key = ctx.on_next_key
  if view.on_next_key and view.on_next_key[2] == 'pseudo' then
    table.insert(view.pseudo_pending, key)
  else
    view.pseudo_pending = {}
  end
  for _, cb in ipairs(ctx.callbacks) do
    cb()
  end
end

function M.push_insert_event(ev)
  table.insert(view.last_insert.keys, ev)
end

function M.pending_display()
  local s = ''
  if view.count then s = s .. tostring(view.count) end
  for _, k in ipairs(view.pending) do
    s = s .. K.seq_format(k)
  end
  for _, k in ipairs(view.pseudo_pending) do
    s = s .. K.seq_format(k)
  end
  return s
end

function M.after_key()
  local E = require('hx.editor')
  local win = E.win()
  if api.nvim_win_is_valid(win) then
    require('hx.render').sync_cursor(win)
    require('hx.render').redraw(win)
  end
  require('hx.ui.info').update(M.autoinfo)
  require('hx.ui.cmdline').render()
  require('hx.lsp.completion').render()
  C.render_all()
  require('hx.render').update_cursor_shape()
  pcall(vim.cmd.redrawstatus, { bang = true })
  pcall(vim.cmd.redrawtabline)
  S.dirty = false
  local ok, ev = pcall(require, 'hx.events')
  if ok then ev.post_key() end
end

local feeding = 0
function M.feed(key, from_macro)
  if M.recording and #M.replaying == 0 and not from_macro then table.insert(M.recording.keys, key) end
  feeding = feeding + 1
  local ok, err = xpcall(function()
    if not C.handle_key(key) then editor_handle(key) end
  end, debug.traceback)
  feeding = feeding - 1
  if not ok then
    S.set_status('hx: ' .. tostring(err):gsub('\n.*', ''), 'error')
    vim.schedule(function()
      vim.notify(err, vim.log.levels.ERROR)
    end)
  end
  if feeding == 0 then M.after_key() end
end

local mapped = false
function M.setup()
  if mapped then return end
  mapped = true
  for _, m in ipairs({ 'n', 'x', 's', 'o', 'i', 'c', 't' }) do
    pcall(vim.cmd, m .. 'mapclear')
  end
  local opts = { noremap = true, silent = true, nowait = true }
  for _, pair in ipairs(K.all_mappings()) do
    local lhs, key = pair[1], pair[2]
    opts.callback = function()
      M.feed(key)
    end
    pcall(api.nvim_set_keymap, 'n', lhs, '', opts)
    pcall(api.nvim_set_keymap, 'x', lhs, '', opts)
  end
  local mouse = {
    ['<LeftMouse>'] = 'left_down', ['<LeftDrag>'] = 'left_drag', ['<LeftRelease>'] = 'left_up',
    ['<M-LeftMouse>'] = 'alt_left_down', ['<ScrollWheelUp>'] = 'scroll_up',
    ['<ScrollWheelDown>'] = 'scroll_down', ['<RightMouse>'] = 'right_down',
    ['<MiddleMouse>'] = 'middle_down', ['<2-LeftMouse>'] = 'left_down', ['<3-LeftMouse>'] = 'left_down',
    ['<S-ScrollWheelUp>'] = 'scroll_up', ['<S-ScrollWheelDown>'] = 'scroll_down',
  }
  for lhs, ev in pairs(mouse) do
    for _, mode in ipairs({ 'n', 'x', 'i' }) do
      pcall(api.nvim_set_keymap, mode, lhs, '', {
        noremap = true,
        silent = true,
        callback = function()
          require('hx.mouse').handle(ev)
          M.after_key()
        end,
      })
    end
  end
  vim.on_key(function(key, typed)
    if not S.enabled then return end
    local b = key:byte(1)
    if not b or b < 0xC2 or b > 0xF4 then return end
    if api.nvim_get_mode().mode ~= 'n' then return end
    local U = require('hx.util')
    if U.seq_len(b) ~= #key then return end
    vim.schedule(function()
      M.feed(key)
    end)
    return ''
  end, api.nvim_create_namespace('hx_on_key'))
end

function M.setup_paste()
  vim.paste = function(lines, phase)
    if phase == 1 or phase == -1 then M._paste_buf = {} end
    for i, l in ipairs(lines) do
      if i == 1 and #M._paste_buf > 0 then
        M._paste_buf[#M._paste_buf] = M._paste_buf[#M._paste_buf] .. l
      else
        table.insert(M._paste_buf, l)
      end
    end
    if phase == 3 or phase == -1 then
      local s = table.concat(M._paste_buf, '\n')
      M._paste_buf = {}
      local ok = C.handle_paste and C.handle_paste(s)
      if not ok then
        local top = C.top()
        if top and top.handle_paste then
          top:handle_paste(s)
        else
          require('hx.commands').paste_bracketed_value(new_ctx(), s)
        end
      end
      M.after_key()
    end
    return true
  end
end

function M.reset()
  view.pending = {}
  view.sticky = nil
  view.count = nil
  view.on_next_key = nil
  M.autoinfo = nil
end

return M
