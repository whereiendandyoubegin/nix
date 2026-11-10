local S = require('hx.state')
local SL = require('hx.selection')
local MV = require('hx.movement')
local U = require('hx.util')
local D = require('hx.doc')
local Modes = require('hx.cmd.modes')
local R = SL.R
local Sel = SL.Selection
local Tx = SL.Transaction

return function(C, H)
  local reg = C.register

  local function indent_for_newline(text, line_before, line_before_end_pos, current_line)
    local buf = H.buf()
    local ok, I = pcall(require, 'hx.indent')
    local opts = {
      indent_unit = H.indent_unit(buf),
      tab_width = H.tab_width(buf),
      heuristic = 'hybrid',
      lang = require('hx.syntax').lang_of(buf),
    }
    if ok then
      local has_tree = require('hx.syntax').has_tree(buf)
      local ok2, res = pcall(I.indent_for_newline, has_tree and buf or nil, text, line_before,
        line_before_end_pos, current_line, opts)
      if ok2 and res then return res end
    end
    local l = text:line(line_before)
    return l:match('^[ \t]*')
  end
  C.indent_for_newline = indent_for_newline

  reg('insert_mode', function()
    Modes.enter_insert_mode()
    H.set_sel(H.sel():transform(function(r)
      return R(r:to(), r:from())
    end))
  end)

  reg('append_mode', function()
    Modes.enter_insert_mode()
    local buf = H.buf()
    S.doc(buf).restore_cursor = true
    local text = H.text()
    local endp = text:len()
    local sel = H.sel()
    local last = sel.ranges[#sel.ranges]
    if not last:is_empty() and last:to() == endp then
      H.apply(Tx.change(text, { { endp, endp, '\n' } }))
      text = H.text()
    end
    H.set_sel(H.sel():transform(function(r)
      return R(r:from(), text:next_grapheme(r:to()))
    end))
  end)

  local function insert_with_indent(fallback)
    local was_select = S.mode == 'select'
    Modes.enter_insert_mode()
    local text = H.text()
    local sel = H.sel()
    local ranges = {}
    local offs = 0
    local changes = {}
    for i, r in ipairs(sel.ranges) do
      local line = r:cursor_line(text)
      local ls = text:line_start(line)
      if text:line_end(line) == ls then
        local indent = indent_for_newline(text, line, ls, line)
        local pos = offs + ls
        ranges[i] = SL.Range.point(pos + #indent)
        offs = offs + #indent
        changes[i] = { ls, ls, indent }
      else
        local pos
        if fallback == 'start' then
          local c = text:first_non_ws(line)
          pos = c and (ls + c) or ls
        else
          pos = text:line_end(line)
        end
        ranges[i] = r:put_cursor(text, pos + offs, was_select)
        changes[i] = { ls, ls, nil }
      end
    end
    local tx = Tx.change(text, changes):with_selection(Sel.new(ranges, sel.primary))
    H.apply(tx)
  end
  reg('insert_at_line_start', function() insert_with_indent('start') end)
  reg('insert_at_line_end', function() insert_with_indent('end') end)

  local function comment_token_for_line(text, line)
    local ok, CM = pcall(require, 'hx.comment')
    if not ok then return nil end
    local tokens = require('hx.languages').comment_tokens(H.buf())
    if not tokens or #tokens == 0 then return nil end
    local ok2, tok = pcall(CM.get_comment_token, text, tokens, line)
    if ok2 then return tok end
    return nil
  end

  local function open(ctx, below, continuation)
    local count = ctx:get_count()
    Modes.enter_insert_mode()
    local text = H.text()
    local sel = H.sel()
    local offs = 0
    local ranges = {}
    local changes = {}
    local cfg_continue = S.config.editor['continue-comments'] ~= false
    for _, r in ipairs(sel.ranges) do
      local curr_line = text:line_of(below and text:prev_grapheme(r:to()) or r:from())
      local next_new_line = below and curr_line + 1 or curr_line
      local above_next = math.max(0, next_new_line - 1)
      local token
      if continuation and cfg_continue and text:first_non_ws(curr_line) then
        token = comment_token_for_line(text, curr_line)
      end
      local idx, w
      if next_new_line == 0 then
        idx, w = 0, 0
      else
        idx, w = text:line_end(above_next), 1
      end
      local l = text:line(curr_line)
      local indent
      local fnw = text:first_non_ws(curr_line)
      if fnw and token then
        indent = l:sub(1, fnw)
      else
        indent = indent_for_newline(text, above_next, idx, curr_line)
      end
      local s
      if not below and next_new_line == 0 then
        s = indent .. (token and (token .. ' ') or '') .. '\n'
      else
        s = '\n' .. indent .. (token and (token .. ' ') or '')
      end
      local full = string.rep(s, count)
      local pos = offs + idx + w
      local comment_len = token and (#token + 1) or 0
      for i = 0, count - 1 do
        ranges[#ranges + 1] = SL.Range.point(pos + i * (1 + #indent + comment_len) + #indent + comment_len)
      end
      offs = offs + #full
      changes[#changes + 1] = { idx, idx, full }
    end
    local tx = Tx.change(text, changes):with_selection(Sel.new(ranges, sel.primary))
    H.apply(tx)
  end
  C.open = open
  reg('open_below', function(ctx) open(ctx, true, true) end)
  reg('open_above', function(ctx) open(ctx, false, true) end)

  local function add_newline_impl(ctx, below)
    local count = ctx:get_count()
    local text = H.text()
    local sel = H.sel()
    local changes = {}
    local seen = {}
    for _, r in ipairs(sel.ranges) do
      local sl, el = r:line_range(text)
      local line = below and el or sl
      local pos
      if below then
        pos = text:line_end(line)
      else
        pos = text:line_start(line)
      end
      if not seen[pos] then
        seen[pos] = true
        changes[#changes + 1] = { pos, pos, string.rep('\n', count) }
      end
    end
    table.sort(changes, function(a, b) return a[1] < b[1] end)
    H.apply(Tx.change(text, changes))
  end
  reg('add_newline_above', function(ctx) add_newline_impl(ctx, false) end)
  reg('add_newline_below', function(ctx) add_newline_impl(ctx, true) end)

  local function pairs_table()
    local p = require('hx.languages').auto_pairs(H.buf())
    return p
  end

  local function is_alnum(cp)
    return cp and U.category(cp) == U.WORD and cp ~= 95
  end

  local function prev_char(text, pos)
    if pos == 0 then return nil end
    return text:char(text:prev_char(pos))
  end

  local function should_close(text, r, pair)
    local cursor = r:cursor(text)
    local nc = text:char(cursor)
    local ok = not (nc and is_alnum(nc))
    if pair.open == pair.close then
      local pc = prev_char(text, cursor)
      ok = ok and not (pc and is_alnum(pc))
    end
    return ok
  end

  local function get_next_range(text, sr, len_inserted, open_len, close_len)
    open_len = open_len or 1
    close_len = close_len or (len_inserted - open_len)
    local len = text:len()
    if sr.head == len and sr.anchor == len then return R(sr.anchor + open_len, sr.head + open_len) end
    local single = sr:is_single_grapheme(text)
    if len_inserted == 0 then
      local ea = single and text:next_grapheme(sr.anchor) or sr.anchor
      return R(ea, text:next_grapheme(sr.head))
    end
    if close_len == 0 then
      local ea = (single or not sr:forward()) and sr.anchor + open_len or sr.anchor
      return R(ea, sr.head + open_len)
    end
    local end_head
    if sr.head == 0 or not sr:forward() then
      end_head = sr.head + open_len
    else
      end_head = text:prev_grapheme(sr.head) + len_inserted
    end
    local end_anchor
    local rl = sr:len()
    local one = rl > 0 and vim.fn.strchars(text:slice(sr:from(), sr:to())) == 1
    if rl == 0 then
      end_anchor = end_head
    elseif one and sr:forward() then
      end_anchor = end_head - close_len
    elseif one then
      end_anchor = end_head + close_len
    elseif sr:forward() then
      end_anchor = single and (text:prev_grapheme(sr.head) + open_len) or sr.anchor
    else
      end_anchor = single and (text:prev_grapheme(sr.anchor) + len_inserted) or (sr.anchor + len_inserted)
    end
    return R(end_anchor, end_head)
  end

  local function handle_same(text, r, pair)
    local cursor = r:cursor(text)
    local nc = text:char(cursor)
    local change, len_ins
    if nc == pair.open then
      change, len_ins = { cursor, cursor, nil }, 0
    else
      if not should_close(text, r, pair) then return nil end
      local o, c = U.encode(pair.open), U.encode(pair.close)
      return { cursor, cursor, o .. c }, get_next_range(text, r, #o + #c, #o, #c)
    end
    return change, get_next_range(text, r, len_ins)
  end

  local function hook_insert(text, r, ch, ap)
    local pair = ap[ch]
    if pair then
      if pair.open == pair.close then
        return handle_same(text, r, pair)
      elseif pair.open == ch then
        local cursor = r:cursor(text)
        local nc = text:char(cursor)
        if nc and not should_close(text, r, pair) then return nil end
        local o, c = U.encode(pair.open), U.encode(pair.close)
        return { cursor, cursor, o .. c }, get_next_range(text, r, #o + #c, #o, #c)
      elseif pair.close == ch then
        local cursor = r:cursor(text)
        if text:char(cursor) == pair.close then return { cursor, cursor, nil }, get_next_range(text, r, 0) end
        return nil
      end
    elseif U.rust_whitespace(ch) then
      local cursor = r:cursor(text)
      local cur = text:char(cursor)
      local prev = prev_char(text, cursor)
      if not cur or not prev then return nil end
      local p = ap[cur]
      if not p or p.open ~= prev or p.close ~= cur then return nil end
      return handle_same(text, r, { open = ch, close = ch })
    end
    return nil
  end

  local function hook_delete(text, r, ap)
    local cursor = r:cursor(text)
    local cur = text:char(cursor)
    local prev = prev_char(text, cursor)
    if not cur or not prev then return nil end
    local function handle_delete()
      local end_next = text:next_grapheme(cursor)
      local end_prev = text:prev_grapheme(cursor)
      local size = end_next - end_prev
      local next_head = text:next_grapheme(r.head) - size
      local single = r:is_single_grapheme(text)
      local next_anchor
      if r:forward() and single then
        next_anchor = r.anchor - (end_next - cursor)
      elseif single then
        next_anchor = r.anchor - (cursor - end_prev)
      elseif r:forward() then
        next_anchor = r.anchor
      else
        next_anchor = r.anchor - size
      end
      return { end_prev, end_next }, R(next_anchor, next_head)
    end
    if text:len() >= 4 and U.rust_whitespace(prev) and U.rust_whitespace(cur) then
      local sp = text:char(text:prev_grapheme(cursor, 2))
      local sn = text:char(text:next_grapheme(cursor))
      if sp and sn then
        local p = ap[sp]
        if p and p.open == sp and p.close == sn then return handle_delete() end
      end
    end
    local p = ap[cur]
    if not p or p.open ~= prev or p.close ~= cur then return nil end
    return handle_delete()
  end

  local function insert_char(ctx, ch)
    local text = H.text()
    local sel = H.sel()
    local cp = U.decode(ch, 1)
    local ap = pairs_table()
    local tx = Tx.change_by_and_with_selection(text, sel, function(r)
      if ap then
        local change, nr = hook_insert(text, r, cp, ap)
        if change then return change, nr end
      end
      local cursor = r:cursor(text)
      return { cursor, cursor, ch }, nil
    end)
    H.apply(tx)
    require('hx.events').post_insert_char(ch, ctx)
  end
  C.register('_insert_char', insert_char)

  reg('insert_tab', function(ctx)
    local count = 1
    local text = H.text()
    local buf = H.buf()
    local unit = H.indent_unit(buf)
    local spaces = unit ~= '\t'
    H.apply(Tx.change_by_selection(text, H.sel(), function(r)
      local cursor = r:cursor(text)
      local ind
      if spaces then
        local line = r:cursor_line(text)
        local ls = text:line_start(line)
        local offset = (cursor - ls) % #unit
        ind = string.rep(unit, count):sub(offset + 1)
      else
        ind = string.rep(unit, count)
      end
      return { cursor, cursor, ind }
    end))
  end)

  reg('smart_tab', function(ctx)
    local cfg = S.config.editor['smart-tab']
    local enable = not cfg or cfg.enable ~= false
    if enable then
      local text = H.text()
      local all_ws = true
      for _, r in ipairs(H.sel().ranges) do
        local cursor = r:cursor(text)
        local line = text:line_of(cursor)
        local left = text:slice(text:line_start(line), cursor)
        if left:find('[^%s]') then
          all_ws = false
          break
        end
      end
      if not all_ws then
        local snip = package.loaded['hx.snippet']
        if snip and snip.active(H.buf()) then
          C.run('goto_next_tabstop', ctx)
        else
          C.run('move_parent_node_end', ctx)
        end
        return
      end
    end
    C.run('insert_tab', ctx)
  end)

  local function insert_newline(ctx)
    local text = H.text()
    local sel = H.sel()
    local cfg_continue = S.config.editor['continue-comments'] ~= false
    local ap = pairs_table() or {}
    local ranges = {}
    local global_offs = 0
    local last_pos = 0
    local changes = {}
    for i, r in ipairs(sel.ranges) do
      local chars_deleted = 0
      local pos = r:cursor(text)
      local prev = pos == 0 and 32 or text:char(text:prev_char(pos))
      local curr = text:char(pos) or 32
      local current_line = text:line_of(pos)
      local line_start = text:line_start(current_line)
      local token
      if cfg_continue and text:first_non_ws(current_line) then
        token = comment_token_for_line(text, current_line)
      end
      local from, to, local_offs
      local new_text
      local before = text:slice(line_start, pos)
      local last_nonws = before:match('.*()[^ \t]')
      if last_nonws then
        local first_trailing = line_start + last_nonws
        first_trailing = line_start + last_nonws - 1
        first_trailing = text:next_char(first_trailing)
        first_trailing = math.max(last_pos, math.min(first_trailing, pos))
        last_pos = pos
        local l = text:line(current_line)
        local fnw = text:first_non_ws(current_line)
        local indent
        if fnw and token then
          indent = l:sub(1, fnw)
        else
          indent = indent_for_newline(text, current_line, pos, current_line)
        end
        local p = ap[prev]
        local on_auto_pair = p and p.open == prev and p.close == curr
        if token then
          new_text = '\n' .. indent .. token .. ' '
          local_offs = #new_text
        elseif on_auto_pair then
          local inner = indent .. H.indent_unit()
          new_text = '\n' .. inner
          local_offs = #new_text
          new_text = new_text .. '\n' .. indent
        else
          new_text = '\n' .. indent
          local_offs = #new_text
        end
        chars_deleted = pos - first_trailing
        from, to = first_trailing, pos
        local_offs = local_offs - chars_deleted
      else
        new_text = '\n'
        from, to = line_start, line_start
        local_offs = #new_text
      end
      local nr
      if r:cursor(text) > r.anchor then
        nr = R(r.anchor + global_offs, r.head + local_offs + global_offs)
      else
        nr = R(r.anchor + local_offs + global_offs, r.head + local_offs + global_offs)
      end
      ranges[i] = nr
      global_offs = global_offs + #new_text - chars_deleted
      changes[i] = { from, to, new_text }
    end
    local tx = Tx.change(text, changes):with_selection(Sel.new(ranges, sel.primary))
    H.apply(tx)
  end
  reg('insert_newline', insert_newline)

  local function dedent(text, r)
    local pos = r:cursor(text)
    local line_start = text:line_start(r:cursor_line(text))
    local frag = text:slice(line_start, pos)
    if frag == '' or frag:find('[^ \t]') then return nil end
    if pos > 0 and text:char(pos - 1) == 9 then return { text:prev_grapheme(pos), pos } end
    local tab_width = H.tab_width()
    local indent_width = H.indent_width()
    local width = 0
    for i = 1, #frag do
      if frag:byte(i) == 9 then
        width = width + tab_width
      else
        width = width + 1
      end
    end
    local drop = width % indent_width
    if drop == 0 then drop = indent_width end
    local start = pos
    for i = #frag, 1, -1 do
      if drop == 0 then break end
      if frag:byte(i) == 32 then
        start = start - 1
        drop = drop - 1
      else
        break
      end
    end
    return { start, pos }
  end

  reg('delete_char_backward', function(ctx)
    local count = ctx:get_count()
    local text = H.text()
    local ap = pairs_table()
    local tx = Tx.delete_by_and_with_selection(text, H.sel(), function(r)
      local pos = r:cursor(text)
      if pos == 0 then return { pos, pos }, nil end
      local d = dedent(text, r)
      if d then return d, nil end
      if ap then
        local del, nr = hook_delete(text, r, ap)
        if del then return del, nr end
      end
      return { text:prev_grapheme(pos, count), pos }, nil
    end)
    H.apply(tx)
  end)

  local function delete_by_selection_insert_mode(f, forward)
    local text = H.text()
    local sel = H.sel()
    local text_len = text:len()
    local insert_nl = false
    local newsel = {}
    local dels = {}
    for i, r in ipairs(sel.ranges) do
      local s, e = f(text, r)
      if forward then
        local nr = R(r.anchor, r.head)
        if r.head > r.anchor then
          insert_nl = insert_nl or e == text_len
          nr.head = text:next_char(nr.head)
          if nr.head == r.head then nr.head = r.head + 1 end
        end
        newsel[i] = nr
      end
      dels[i] = { s, e }
    end
    local tx = Tx.delete(text, dels)
    if insert_nl then
      local ch = tx.cs.changes
      local appended = false
      for _, c in ipairs(ch) do
        if c[1] == text_len then appended = true end
      end
      if not appended then
        table.insert(ch, { text_len, text_len, '\n' })
        tx = Tx.change(text, ch)
      end
    end
    if forward then
      local s = Sel.new(newsel, sel.primary)
      require('hx.state').set_sel(s, H.win(), H.buf())
    end
    H.apply(tx)
  end
  C.delete_by_selection_insert_mode = delete_by_selection_insert_mode

  reg('delete_char_forward', function(ctx)
    local count = ctx:get_count()
    delete_by_selection_insert_mode(function(text, r)
      local pos = r:cursor(text)
      return pos, text:next_grapheme(pos, count)
    end, true)
  end)

  local function exclude_cursor(text, range, cursor)
    if range:to() == cursor:to() and text:len() ~= cursor:to() then
      return R(range:from(), text:prev_grapheme(cursor:to()))
    end
    return range
  end

  reg('delete_word_backward', function(ctx)
    local count = ctx:get_count()
    delete_by_selection_insert_mode(function(text, r)
      local anchor = MV.move_prev_word_start(text, r, count):from()
      local nxt = R(anchor, r:cursor(text))
      local rr = exclude_cursor(text, nxt, r)
      return rr:from(), rr:to()
    end, false)
  end)

  reg('delete_word_forward', function(ctx)
    local count = ctx:get_count()
    delete_by_selection_insert_mode(function(text, r)
      local head = MV.move_next_word_end(text, r, count):to()
      return r:cursor(text), head
    end, true)
  end)

  reg('kill_to_line_start', function()
    delete_by_selection_insert_mode(function(text, r)
      local line = r:cursor_line(text)
      local first = text:line_start(line)
      local anchor = r:cursor(text)
      local head
      if anchor == first and line ~= 0 then
        head = text:line_end(line - 1)
      else
        local fnw = text:first_non_ws(line)
        if fnw and first + fnw < anchor then
          head = first + fnw
        else
          head = first
        end
      end
      return head, anchor
    end, false)
  end)

  reg('kill_to_line_end', function()
    delete_by_selection_insert_mode(function(text, r)
      local line = r:cursor_line(text)
      local le = text:line_end(line)
      local pos = r:cursor(text)
      if pos == le then return pos, text:line_next(line) end
      return pos, le
    end, true)
  end)

  reg('commit_undo_checkpoint', function()
    D.checkpoint(H.buf())
  end)

  reg('completion', function()
    require('hx.lsp.completion').trigger_manual()
  end)

  reg('insert_register', function(ctx)
    require('hx.input').autoinfo = require('hx.ui.info').from_registers('Insert register')
    ctx:on_next(function(c2, key)
      require('hx.input').autoinfo = nil
      local K = require('hx.keys')
      local ch = K.char(key)
      if ch then
        c2.register = ch
        local P = require('hx.cmd.edit_paste')
        P.paste(ch, 'cursor', c2:get_count())
      end
    end)
  end)

  local function insert_selection_interactive(ctx, old_mode)
    local count = ctx:get_count()
    ctx:on_next(function(c2, key)
      local K = require('hx.keys')
      local ch = K.char(key)
      if ch then
        for _ = 1, count do
          insert_char(c2, ch)
        end
      elseif key == 'ret' then
        if count ~= 1 then
          H.error('inserting multiple newlines not yet supported')
          return
        end
        insert_newline(c2)
      elseif key == 'tab' then
        for _ = 1, count do
          C.run('insert_tab', c2)
        end
      end
      S.mode = old_mode
      require('hx.render').update_cursor_shape()
    end)
  end
  reg('insert_char_interactive', function(ctx)
    local mode = S.mode
    C.run('insert_mode', ctx)
    insert_selection_interactive(ctx, mode)
  end)
  reg('append_char_interactive', function(ctx)
    local mode = S.mode
    C.run('append_mode', ctx)
    insert_selection_interactive(ctx, mode)
  end)
end
