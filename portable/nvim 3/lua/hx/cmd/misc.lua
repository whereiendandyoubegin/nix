local api = vim.api
local S = require('hx.state')
local SL = require('hx.selection')
local U = require('hx.util')
local MV = require('hx.movement')
local R = SL.R

return function(C, H)
  local reg = C.register

  reg('command_mode', function()
    require('hx.typed').command_mode()
  end)

  reg('command_palette', function()
    require('hx.ui.pickers').command_palette()
  end)

  local function find_paths_near(text, pos)
    local row = text:line_of(pos)
    local l = text:line(row)
    local col = pos - text:line_start(row)
    local best
    for s, m, e in l:gmatch('()([%w%._%-/~%+@:]+)()') do
      local si, ei = s - 1, e - 1
      if si <= col + 1 and col <= ei then
        if m:find('[/%.]') or vim.uv.fs_stat(m) then
          best = m
          break
        end
      end
    end
    return best
  end

  local function goto_file_impl(action)
    local text = H.text()
    local sel = H.sel()
    local buf = H.buf()
    local name = api.nvim_buf_get_name(buf)
    local rel_dir = name ~= '' and vim.fn.fnamemodify(name, ':h') or vim.fn.getcwd()
    local paths = {}
    if #sel.ranges == 1 and sel.ranges[1]:len() <= 1 then
      local r = sel.ranges[1]
      local p = find_paths_near(text, r:cursor(text))
      paths[1] = p or r:fragment(text)
    else
      for _, r in ipairs(sel.ranges) do
        local s = U.trim(r:fragment(text))
        if s ~= '' then paths[#paths + 1] = s end
      end
    end
    for _, p in ipairs(paths) do
      if p:match('^%a[%w+.-]*://') then
        if p:match('^file://') then
          p = p:gsub('^file://', '')
        else
          vim.ui.open(p)
          goto continue
        end
      end
      do
        local path = vim.fn.expand(p)
        if path:sub(1, 1) ~= '/' then path = rel_dir .. '/' .. path end
        if vim.fn.isdirectory(path) == 1 then
          require('hx.ui.pickers').file_picker(path)
        else
          local ok, err = pcall(require('hx.editor').open, path, action)
          if not ok then H.error('Open file failed: ' .. tostring(err)) end
        end
      end
      ::continue::
    end
  end
  reg('goto_file', function() goto_file_impl('replace') end)
  reg('goto_file_hsplit', function() goto_file_impl('hsplit') end)
  reg('goto_file_vsplit', function() goto_file_impl('vsplit') end)

  local lns = api.nvim_create_namespace('hx_jump_labels')

  local function jump_to_label(ctx, labels, extend)
    local alphabet = {}
    for _, cp in U.chars(S.config.editor['jump-label-alphabet']) do
      alphabet[#alphabet + 1] = U.encode(cp)
    end
    if #labels == 0 then return end
    local buf = H.buf()
    local text = H.text()
    local n = #alphabet
    api.nvim_buf_clear_namespace(buf, lns, 0, -1)
    local label_group = 'HxJumpLabel'
    for i, r in ipairs(labels) do
      local idx = i - 1
      local first = alphabet[math.floor(idx / n) + 1]
      local second = alphabet[(idx % n) + 1]
      for k, posch in ipairs({ { r:from(), first }, { text:next_grapheme(r:from()), second } }) do
        local p = posch[1]
        local row = text:line_of(p)
        pcall(api.nvim_buf_set_extmark, buf, lns, row, p - text:line_start(row), {
          virt_text = { { posch[2], label_group } },
          virt_text_pos = 'overlay',
          priority = 9000,
        })
        local _ = k
      end
    end
    local primary = H.sel():prim()
    local win = H.win()
    ctx:on_next(function(c2, key)
      local ch = require('hx.keys').char(key)
      local i
      for k, a in ipairs(alphabet) do
        if a == ch then i = k - 1 end
      end
      if not i then
        api.nvim_buf_clear_namespace(buf, lns, 0, -1)
        return
      end
      local outer = i * n
      if outer > #labels then
        api.nvim_buf_clear_namespace(buf, lns, 0, -1)
        return
      end
      c2:on_next(function(_, key2)
        api.nvim_buf_clear_namespace(buf, lns, 0, -1)
        local ch2 = require('hx.keys').char(key2)
        local inner
        for k, a in ipairs(alphabet) do
          if a == ch2 then inner = k - 1 end
        end
        if not inner then return end
        local r = labels[outer + inner + 1]
        if not r then return end
        if extend then
          local anchor
          if r.anchor < r.head then
            anchor = math.min(r.anchor, primary:from())
          else
            anchor = math.max(r.anchor, primary:to())
          end
          r = R(anchor, r.head)
        else
          r = r:with_direction(true)
        end
        require('hx.doc').push_jump(win, buf)
        H.set_sel(SL.Selection.new({ r }, 1))
      end)
    end)
  end

  local function jump_to_word(ctx, extend)
    local alphabet = S.config.editor['jump-label-alphabet']
    if alphabet == '' then return end
    local limit = U.char_count(alphabet) ^ 2
    local words = {}
    local text = H.text()
    local win = H.win()
    local top, bot = api.nvim_win_call(win, function()
      return vim.fn.line('w0') - 1, vim.fn.line('w$') - 1
    end)
    local start = text:line_start(top)
    local stop = text:line_next(bot)
    local prim = H.sel():prim()
    local cursor = prim:cursor(text)
    local fwd = SL.Range.point(cursor)
    local rev = SL.Range.point(cursor)
    local cc = text:char(cursor)
    if cc and not U.rust_whitespace(cc) then
      local we = MV.move_next_word_end(text, fwd, 1)
      if we.anchor == cursor then fwd = we end
      local ws = MV.move_prev_word_start(text, rev, 1)
      if ws.anchor == text:next_grapheme(cursor) then rev = ws end
    end
    local function word_chars_before(p, n)
      local cnt = 0
      local q = p
      while cnt < n and q > 0 do
        q = text:prev_grapheme(q)
        if not U.is_word(text:char(q)) then break end
        cnt = cnt + 1
      end
      return cnt
    end
    local function word_chars_after(p, n)
      local cnt = 0
      local q = p
      while cnt < n and q < text:len() do
        if not U.is_word(text:char(q)) then break end
        q = text:next_grapheme(q)
        cnt = cnt + 1
      end
      return cnt
    end
    while true do
      local changed = false
      while fwd.head < stop do
        fwd = MV.move_next_word_end(text, fwd, 1)
        if word_chars_before(fwd.head, 2) == 2 then
          changed = true
          local a = fwd.anchor
          while a < fwd.head and not U.is_word(text:char(a)) do
            a = text:next_char(a)
          end
          fwd = R(a, fwd.head)
          words[#words + 1] = fwd
          if #words == limit then goto done end
          break
        end
      end
      while rev.head > start do
        rev = MV.move_prev_word_start(text, rev, 1)
        if word_chars_after(rev.head, 2) == 2 then
          changed = true
          local a = rev.anchor
          while a > rev.head do
            local pa = text:prev_char(a)
            if U.is_word(text:char(pa)) then break end
            a = pa
          end
          rev = R(a, rev.head)
          words[#words + 1] = rev
          if #words == limit then goto done end
          break
        end
      end
      if not changed then break end
    end
    ::done::
    jump_to_label(ctx, words, extend)
  end
  reg('goto_word', function(ctx) jump_to_word(ctx, false) end)
  reg('extend_to_word', function(ctx) jump_to_word(ctx, true) end)

  reg('goto_next_tabstop', function(ctx)
    require('hx.snippet').goto_tabstop(ctx, true)
  end)
  reg('goto_prev_tabstop', function(ctx)
    require('hx.snippet').goto_tabstop(ctx, false)
  end)

  for _, name in ipairs({ 'dap_launch', 'dap_restart', 'dap_toggle_breakpoint', 'dap_continue', 'dap_pause',
    'dap_step_in', 'dap_step_out', 'dap_next', 'dap_variables', 'dap_terminate', 'dap_edit_condition',
    'dap_edit_log', 'dap_switch_thread', 'dap_switch_stack_frame', 'dap_enable_exceptions',
    'dap_disable_exceptions' }) do
    reg(name, function()
      if name == 'dap_launch' then
        H.error('No debug adapter available for language')
      else
        H.error('No debug adapter available')
      end
    end)
  end
end
