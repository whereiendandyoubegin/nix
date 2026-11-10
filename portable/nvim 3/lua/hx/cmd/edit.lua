local S = require('hx.state')
local SL = require('hx.selection')
local U = require('hx.util')
local D = require('hx.doc')
local Regs = require('hx.registers')
local P = require('hx.cmd.edit_paste')
local Modes = require('hx.cmd.modes')
local R = SL.R
local Sel = SL.Selection
local Tx = SL.Transaction

return function(C, H)
  local reg = C.register

  local function default_reg()
    return S.config.editor['default-yank-register'] or '"'
  end

  local function selection_is_linewise(sel, text)
    local nl = text:len_lines()
    for _, r in ipairs(sel.ranges) do
      local frag = r:fragment(text)
      local _, nls = frag:gsub('\n', '')
      if nls < 1 then return false end
      local sl, el = r:line_range(text)
      local start = text:line_start(sl)
      local stop = text:line_start(math.min(el + 1, nl))
      if not (start == r:from() and stop == r:to()) then return false end
    end
    return true
  end

  local function delete_selection_impl(ctx, op, yank)
    local text = H.text()
    local sel = H.sel()
    local only_whole_lines = selection_is_linewise(sel, text)
    if ctx.register ~= '_' and yank then
      local values = sel:fragments(text)
      local ok, err = Regs.write(ctx.register or default_reg(), values)
      if not ok then
        H.error(err)
        return
      end
    end
    local dels = {}
    for i, r in ipairs(sel.ranges) do
      dels[i] = { r:from(), r:to() }
    end
    H.apply(Tx.delete(text, dels))
    if op == 'delete' then
      H.exit_select_mode()
    else
      if only_whole_lines then
        C.open(ctx, false, false)
      else
        Modes.enter_insert_mode()
      end
    end
  end
  reg('delete_selection', function(ctx) delete_selection_impl(ctx, 'delete', true) end)
  reg('delete_selection_noyank', function(ctx) delete_selection_impl(ctx, 'delete', false) end)
  reg('change_selection', function(ctx) delete_selection_impl(ctx, 'change', true) end)
  reg('change_selection_noyank', function(ctx) delete_selection_impl(ctx, 'change', false) end)

  reg('replace', function(ctx)
    ctx:on_next(function(c2, key)
      local K = require('hx.keys')
      local ch
      if key == 'ret' then
        ch = '\n'
      elseif key == 'tab' then
        ch = '\t'
      else
        local p = K.parse(key)
        ch = K.code_char(p.code)
        if p.mods.C or p.mods.A then ch = nil end
      end
      if not ch then return end
      local text = H.text()
      H.apply(Tx.change_by_selection(text, H.sel(), function(r)
        if not r:is_empty() then
          local n = 0
          local p = r:from()
          while p < r:to() do
            n = n + 1
            p = text:next_grapheme(p)
          end
          return { r:from(), r:to(), string.rep(ch, n) }
        end
        return { r:from(), r:to(), nil }
      end))
      H.exit_select_mode()
    end)
  end)

  local function switch_case_impl(f)
    local text = H.text()
    H.apply(Tx.change_by_selection(text, H.sel(), function(r)
      return { r:from(), r:to(), f(r:fragment(text)) }
    end))
    H.exit_select_mode()
  end
  reg('switch_case', function()
    switch_case_impl(function(s)
      local out = {}
      for _, cp in U.chars(s) do
        if U.is_lower(cp) then
          out[#out + 1] = vim.fn.toupper(U.encode(cp))
        elseif U.is_upper(cp) then
          out[#out + 1] = vim.fn.tolower(U.encode(cp))
        else
          out[#out + 1] = U.encode(cp)
        end
      end
      return table.concat(out)
    end)
  end)
  reg('switch_to_uppercase', function()
    switch_case_impl(function(s) return vim.fn.toupper(s) end)
  end)
  reg('switch_to_lowercase', function()
    switch_case_impl(function(s) return vim.fn.tolower(s) end)
  end)

  local function yank_impl(register)
    local text = H.text()
    local values = H.sel():fragments(text)
    local n = #values
    local ok, err = Regs.write(register, values)
    if ok then
      H.status(('yanked %d selection%s to register %s'):format(n, n == 1 and '' or 's', register))
    else
      H.error(err)
    end
  end
  reg('yank', function(ctx)
    yank_impl(ctx.register or default_reg())
    H.exit_select_mode()
  end)
  reg('yank_to_clipboard', function()
    yank_impl('+')
    H.exit_select_mode()
  end)
  reg('yank_to_primary_clipboard', function()
    yank_impl('*')
    H.exit_select_mode()
  end)

  local function yank_joined_impl(sep, register)
    local text = H.text()
    local frags = H.sel():fragments(text)
    local n = #frags
    local ok, err = Regs.write(register, { table.concat(frags, sep) })
    if ok then
      H.status(('joined and yanked %d selection%s to register %s'):format(n, n == 1 and '' or 's', register))
    else
      H.error(err)
    end
  end
  C.yank_joined_impl = yank_joined_impl
  reg('yank_joined', function(ctx)
    yank_joined_impl('\n', ctx.register or default_reg())
    H.exit_select_mode()
  end)
  reg('yank_joined_to_clipboard', function()
    yank_joined_impl('\n', '+')
    H.exit_select_mode()
  end)
  reg('yank_joined_to_primary_clipboard', function()
    yank_joined_impl('\n', '*')
    H.exit_select_mode()
  end)

  local function yank_main(register)
    local text = H.text()
    local s = H.sel():prim():fragment(text)
    local ok, err = Regs.write(register, { s })
    if ok then
      H.status(('yanked primary selection to register %s'):format(register))
    else
      H.error(err)
    end
  end
  C.yank_main_selection_to_register = yank_main
  reg('yank_main_selection_to_clipboard', function()
    yank_main('+')
    H.exit_select_mode()
  end)
  reg('yank_main_selection_to_primary_clipboard', function()
    yank_main('*')
    H.exit_select_mode()
  end)

  reg('paste_after', function(ctx)
    P.paste(ctx.register or default_reg(), 'after', ctx:get_count())
    H.exit_select_mode()
  end)
  reg('paste_before', function(ctx)
    P.paste(ctx.register or default_reg(), 'before', ctx:get_count())
    H.exit_select_mode()
  end)
  reg('paste_clipboard_after', function(ctx)
    P.paste('+', 'after', ctx:get_count())
    H.exit_select_mode()
  end)
  reg('paste_clipboard_before', function(ctx)
    P.paste('+', 'before', ctx:get_count())
    H.exit_select_mode()
  end)
  reg('paste_primary_clipboard_after', function(ctx)
    P.paste('*', 'after', ctx:get_count())
    H.exit_select_mode()
  end)
  reg('paste_primary_clipboard_before', function(ctx)
    P.paste('*', 'before', ctx:get_count())
    H.exit_select_mode()
  end)
  reg('replace_with_yanked', function(ctx)
    P.replace_selections_with_register(ctx.register or default_reg(), ctx:get_count())
    H.exit_select_mode()
  end)
  reg('replace_selections_with_clipboard', function(ctx)
    P.replace_selections_with_register('+', ctx:get_count())
    H.exit_select_mode()
  end)
  reg('replace_selections_with_primary_clipboard', function(ctx)
    P.replace_selections_with_register('*', ctx:get_count())
    H.exit_select_mode()
  end)

  reg('_paste_bracketed_value', function(ctx, contents)
    local count = ctx:get_count()
    local mode = S.mode
    local action = (mode == 'insert' or mode == 'select') and 'cursor' or 'before'
    P.paste_impl({ contents }, action, count, mode)
    H.exit_select_mode()
  end)
  C.impl._paste_bracketed_value = function(ctx, contents)
    local count = ctx:get_count()
    local mode = S.mode
    local action = (mode == 'insert' or mode == 'select') and 'cursor' or 'before'
    P.paste_impl({ contents }, action, count, mode)
    H.exit_select_mode()
  end

  local function get_lines()
    local text = H.text()
    local set, lines = {}, {}
    for _, r in ipairs(H.sel().ranges) do
      local s, e = r:line_range(text)
      for l = s, e do
        if not set[l] then
          set[l] = true
          lines[#lines + 1] = l
        end
      end
    end
    table.sort(lines)
    return lines
  end

  reg('indent', function(ctx)
    local count = ctx:get_count()
    local text = H.text()
    local unit = H.indent_unit()
    local indent = string.rep(unit, count)
    local changes = {}
    for _, line in ipairs(get_lines()) do
      local l = text:line(line)
      if l:find('%S') then
        local pos = text:line_start(line)
        local ind = indent
        if unit ~= '\t' then
          local fnw = (l:find('[^ \t]') or 1) - 1
          local offset = fnw % #unit
          ind = indent:sub(offset + 1)
        end
        changes[#changes + 1] = { pos, pos, ind }
      end
    end
    H.apply(Tx.change(text, changes))
    H.exit_select_mode()
  end)

  reg('unindent', function(ctx)
    local count = ctx:get_count()
    local text = H.text()
    local tab_width = H.tab_width()
    local indent_width = count * H.indent_width()
    local changes = {}
    for _, line in ipairs(get_lines()) do
      local l = text:line(line)
      local width, pos = 0, 0
      for i = 1, #l do
        local c = l:byte(i)
        if c == 32 then
          width = width + 1
        elseif c == 9 then
          width = (math.floor(width / tab_width) + 1) * tab_width
        else
          break
        end
        pos = pos + 1
        if width >= indent_width then break end
      end
      if pos > 0 then
        local start = text:line_start(line)
        changes[#changes + 1] = { start, start + pos, nil }
      end
    end
    H.apply(Tx.change(text, changes))
    H.exit_select_mode()
  end)

  reg('format_selections', function()
    require('hx.lsp.format').format_selections()
  end)

  local function join_impl(select_space)
    local text = H.text()
    local MV = require('hx.movement')
    local changes = {}
    local tokens = require('hx.languages').comment_tokens(H.buf()) or {}
    local sorted = { unpack(tokens) }
    table.sort(sorted, function(a, b) return #a > #b end)
    local function is_sp(c)
      return c == 32 or c == 9
    end
    local nl = text:len_lines()
    for _, r in ipairs(H.sel().ranges) do
      local s, e = r:line_range(text)
      if s == e then e = math.min(e + 1, nl - 1) end
      local fl = text:line_start(s)
      fl = MV.skip_while(text, fl, is_sp) or fl
      local first = text:slice(fl, math.min(text:len(), fl + 64))
      local current_token
      for _, t in ipairs(sorted) do
        if first:sub(1, #t) == t then
          current_token = t
          break
        end
      end
      for line = s, e - 1 do
        local start = text:line_end(line)
        local stop = text:line_start(line + 1)
        stop = MV.skip_while(text, stop, is_sp) or stop
        local from_end = text:slice(stop, math.min(text:len(), stop + 64))
        for _, t in ipairs(sorted) do
          if from_end:sub(1, #t) == t then
            if t == current_token then
              stop = stop + #t
              stop = MV.skip_while(text, stop, is_sp) or stop
            else
              current_token = t
            end
            break
          end
        end
        local sep
        if stop == text:line_end(line + 1) then
          sep = nil
        else
          sep = ' '
        end
        changes[#changes + 1] = { start, stop, sep }
      end
    end
    if #changes == 0 then return end
    table.sort(changes, function(a, b) return a[1] < b[1] end)
    local dedup = {}
    for _, c in ipairs(changes) do
      local last = dedup[#dedup]
      if not (last and last[1] == c[1] and last[2] == c[2] and last[3] == c[3]) then dedup[#dedup + 1] = c end
    end
    changes = dedup
    local tx
    if select_space then
      local offset = 0
      local ranges = {}
      for _, c in ipairs(changes) do
        if c[3] then
          ranges[#ranges + 1] = SL.Range.point(c[1] - offset)
          offset = offset + c[2] - c[1] - 1
        else
          offset = offset + c[2] - c[1]
        end
      end
      tx = Tx.change(text, changes)
      if #ranges > 0 then tx:with_selection(Sel.new(ranges, 1)) end
    else
      tx = Tx.change(text, changes)
    end
    H.apply(tx)
  end
  reg('join_selections', function() join_impl(false) end)
  reg('join_selections_space', function() join_impl(true) end)

  local function toggle_comments_impl(fn)
    local CM = require('hx.comment')
    local buf = H.buf()
    local text = H.text()
    local sel = H.sel()
    local L = require('hx.languages')
    local tokens = L.comment_tokens(buf)
    local block = L.block_comment_tokens(buf)
    local cursor_line = text:line_of(sel:prim():cursor(text))
    local line_token
    if tokens then line_token = CM.get_comment_token(text, tokens, cursor_line) or tokens[1] end
    local tx = fn(CM, line_token, block, text, sel)
    if tx then H.apply(tx) end
    H.exit_select_mode()
  end

  reg('toggle_comments', function()
    toggle_comments_impl(function(CM, line_token, block_tokens, text, sel)
      if line_token and not block_tokens then return CM.toggle_line_comments(text, sel, line_token) end
      local split = CM.split_lines_of_selection(text, sel)
      local bt = block_tokens or { CM.default_block_token() }
      local line_commented, line_changes = CM.find_block_comments(bt, text, split)
      if line_commented then
        return (CM.create_block_comment_transaction(text, split, line_commented, line_changes))
      end
      local block_commented, changes = CM.find_block_comments(bt, text, sel)
      if block_commented then
        return (CM.create_block_comment_transaction(text, sel, block_commented, changes))
      end
      if not line_token and block_tokens then
        return (CM.create_block_comment_transaction(text, split, line_commented, line_changes))
      end
      return CM.toggle_line_comments(text, sel, line_token)
    end)
  end)

  reg('toggle_line_comments', function()
    toggle_comments_impl(function(CM, line_token, block_tokens, text, sel)
      if not line_token and block_tokens then
        return CM.toggle_block_comments(text, CM.split_lines_of_selection(text, sel), block_tokens)
      end
      return CM.toggle_line_comments(text, sel, line_token)
    end)
  end)

  reg('toggle_block_comments', function()
    toggle_comments_impl(function(CM, line_token, block_tokens, text, sel)
      if line_token and not block_tokens then return CM.toggle_line_comments(text, sel, line_token) end
      return CM.toggle_block_comments(text, sel, block_tokens or { CM.default_block_token() })
    end)
  end)

  local function increment_impl(ctx, sign)
    local INC = require('hx.increment')
    local amount = sign * ctx:get_count()
    local increase_by = ctx.register == '#' and sign or 0
    local text = H.text()
    local sel = H.sel()
    local ranges = {}
    local diff = 0
    local changes = {}
    for _, r in ipairs(sel.ranges) do
      local frag = r:fragment(text)
      local new_from = r:from() + diff
      local inc = INC.integer(frag, amount) or INC.date_time(frag, amount)
      amount = amount + increase_by
      if not inc then
        ranges[#ranges + 1] = R(new_from, r:to() + diff)
      else
        ranges[#ranges + 1] = R(new_from, new_from + #inc)
        diff = diff + #inc - #frag
        changes[#changes + 1] = { r:from(), r:to(), inc }
      end
    end
    if #changes > 0 then
      H.apply(Tx.change(text, changes):with_selection(Sel.new(ranges, sel.primary)))
      H.exit_select_mode()
    end
  end
  reg('increment', function(ctx) increment_impl(ctx, 1) end)
  reg('decrement', function(ctx) increment_impl(ctx, -1) end)

  reg('undo', function(ctx) D.undo(ctx:get_count()) end)
  reg('redo', function(ctx) D.redo(ctx:get_count()) end)
  reg('earlier', function(ctx)
    for _ = 1, ctx:get_count() do
      local before = vim.fn.changenr()
      D.earlier(1)
      if vim.fn.changenr() == before then break end
    end
  end)
  reg('later', function(ctx)
    for _ = 1, ctx:get_count() do
      local before = vim.fn.changenr()
      D.later(1)
      if vim.fn.changenr() == before then break end
    end
  end)

  local I = function()
    return require('hx.input')
  end
  reg('select_register', function(ctx)
    I().autoinfo = require('hx.ui.info').from_registers('Select register')
    ctx:on_next(function(_, key)
      I().autoinfo = nil
      local ch = require('hx.keys').char(key)
      if ch then I().view.register = ch end
    end)
  end)

  reg('copy_between_registers', function(ctx)
    I().autoinfo = require('hx.ui.info').from_registers('Copy from register')
    ctx:on_next(function(c2, key)
      I().autoinfo = nil
      local src = require('hx.keys').char(key)
      if not src then return end
      local values = Regs.read(src)
      if not values then
        H.error(('register %s is empty'):format(src))
        return
      end
      I().autoinfo = require('hx.ui.info').from_registers('Copy into register')
      c2:on_next(function(_, key2)
        I().autoinfo = nil
        local dest = require('hx.keys').char(key2)
        if not dest then return end
        local ok, err = Regs.write(dest, values)
        if ok then
          H.status(('yanked %d value%s from register %s to %s'):format(#values, #values == 1 and '' or 's', src, dest))
        else
          H.error(err)
        end
      end)
    end)
  end)

  reg('record_macro', function(ctx)
    local inp = I()
    if inp.recording then
      local rec = inp.recording
      inp.recording = nil
      table.remove(rec.keys)
      local s = require('hx.keys').format_macro(rec.keys)
      local ok, err = Regs.write(rec.reg, { s })
      if ok then
        H.status(('Recorded to register [%s]'):format(rec.reg))
      else
        H.error(err)
      end
    else
      local r = ctx.register or '@'
      ctx.register = nil
      inp.recording = { reg = r, keys = {} }
      H.status(('Recording to register [%s]'):format(r))
    end
  end)

  reg('replay_macro', function(ctx)
    local inp = I()
    local r = ctx.register or '@'
    if vim.tbl_contains(inp.replaying, r) then
      H.error(('Cannot replay from register [%s] because already replaying from same register'):format(r))
      return
    end
    local vals = Regs.read(r)
    if not vals or #vals ~= 1 then
      H.error(('Register [%s] empty'):format(r))
      return
    end
    local keys, err = require('hx.keys').parse_macro(vals[1])
    if not keys then
      H.error('Invalid macro: ' .. tostring(err))
      return
    end
    table.insert(inp.replaying, r)
    local count = ctx:get_count()
    ctx:push_callback(function()
      for _ = 1, count do
        for _, k in ipairs(keys) do
          inp.feed(k, true)
        end
      end
      for i = #inp.replaying, 1, -1 do
        if inp.replaying[i] == r then
          table.remove(inp.replaying, i)
          break
        end
      end
    end)
  end)
end
