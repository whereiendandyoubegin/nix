local api = vim.api
local S = require('hx.state')
local SL = require('hx.selection')
local MV = require('hx.movement')
local D = require('hx.doc')
local E = require('hx.editor')
local R = SL.R
local Sel = SL.Selection

return function(C, H)
  local reg = C.register

  local function transform(f)
    local text = H.text()
    H.set_sel(H.sel():transform(function(r)
      return f(text, r)
    end))
  end

  local function move_impl(kind, forward, extend, ctx)
    local count = ctx:get_count()
    local win = H.win()
    transform(function(text, r)
      if kind == 'h' then
        return MV.move_horizontally(text, r, forward, count, extend)
      elseif kind == 'v' then
        return MV.move_vertically(text, r, forward, count, extend, H.tab_width())
      else
        return MV.move_vertically_visual(text, r, forward, count, extend, win)
      end
    end)
  end
  reg('move_char_left', function(ctx) move_impl('h', false, false, ctx) end)
  reg('move_char_right', function(ctx) move_impl('h', true, false, ctx) end)
  reg('move_line_up', function(ctx) move_impl('v', false, false, ctx) end)
  reg('move_line_down', function(ctx) move_impl('v', true, false, ctx) end)
  reg('move_visual_line_up', function(ctx) move_impl('vv', false, false, ctx) end)
  reg('move_visual_line_down', function(ctx) move_impl('vv', true, false, ctx) end)
  reg('extend_char_left', function(ctx) move_impl('h', false, true, ctx) end)
  reg('extend_char_right', function(ctx) move_impl('h', true, true, ctx) end)
  reg('extend_line_up', function(ctx) move_impl('v', false, true, ctx) end)
  reg('extend_line_down', function(ctx) move_impl('v', true, true, ctx) end)
  reg('extend_visual_line_up', function(ctx) move_impl('vv', false, true, ctx) end)
  reg('extend_visual_line_down', function(ctx) move_impl('vv', true, true, ctx) end)

  local function goto_line_end_impl(extend)
    transform(function(text, r)
      local line = r:cursor_line(text)
      local ls = text:line_start(line)
      local pos = math.max(text:prev_grapheme(text:line_end(line)), ls)
      return r:put_cursor(text, pos, extend)
    end)
  end
  reg('goto_line_end', function() goto_line_end_impl(H.extend()) end)
  reg('extend_to_line_end', function() goto_line_end_impl(true) end)

  local function goto_line_end_newline_impl(extend)
    transform(function(text, r)
      local line = r:cursor_line(text)
      return r:put_cursor(text, text:line_end(line), extend)
    end)
  end
  reg('goto_line_end_newline', function() goto_line_end_newline_impl(H.extend()) end)
  reg('extend_to_line_end_newline', function() goto_line_end_newline_impl(true) end)

  local function goto_line_start_impl(extend)
    transform(function(text, r)
      local line = r:cursor_line(text)
      return r:put_cursor(text, text:line_start(line), extend)
    end)
  end
  reg('goto_line_start', function() goto_line_start_impl(H.extend()) end)
  reg('extend_to_line_start', function() goto_line_start_impl(true) end)

  local function goto_first_nonws_impl(extend)
    transform(function(text, r)
      local line = r:cursor_line(text)
      local c = text:first_non_ws(line)
      if c then return r:put_cursor(text, text:line_start(line) + c, extend) end
      return r
    end)
  end
  reg('goto_first_nonwhitespace', function() goto_first_nonws_impl(H.extend()) end)
  reg('extend_to_first_nonwhitespace', function() goto_first_nonws_impl(true) end)

  local function goto_buffer(forward, count)
    local docs = E.documents()
    local cur = E.buf()
    local idx
    for i, b in ipairs(docs) do
      if b == cur then idx = i end
    end
    if not idx then
      if #docs == 0 then return end
      idx = 1
    end
    local n = #docs
    local target
    if forward then
      target = docs[((idx - 1 + count) % n) + 1]
    else
      target = docs[((idx - 1 - count) % n + n) % n + 1]
    end
    E.switch_buffer(target)
  end
  reg('goto_next_buffer', function(ctx) goto_buffer(true, ctx:get_count()) end)
  reg('goto_previous_buffer', function(ctx) goto_buffer(false, ctx:get_count()) end)

  reg('goto_last_accessed_file', function()
    local v = S.view(H.win())
    local alt = table.remove(v.access)
    while alt and not api.nvim_buf_is_valid(alt) do
      alt = table.remove(v.access)
    end
    if alt then
      local cur = H.buf()
      E.switch_buffer(alt)
    else
      H.error('no last accessed buffer')
    end
  end)

  reg('goto_last_modified_file', function()
    local v = S.view(H.win())
    local cur = H.buf()
    local alt
    for _, b in ipairs(v.last_modified) do
      if b and b ~= cur and api.nvim_buf_is_valid(b) then
        alt = b
        break
      end
    end
    if alt then
      E.switch_buffer(alt)
    else
      H.error('no last modified buffer')
    end
  end)

  reg('goto_last_modification', function()
    local d = S.doc(H.buf())
    local pos = d.last_edit_pos
    if pos then
      local text = H.text()
      pos = math.min(pos, text:len())
      local sel = H.sel():transform(function(r)
        return r:put_cursor(text, pos, H.extend())
      end)
      H.push_jump()
      H.set_sel(sel)
    end
  end)

  local word_fns = {
    'next_word_start', 'prev_word_start', 'next_word_end', 'prev_word_end', 'next_long_word_start',
    'prev_long_word_start', 'next_long_word_end', 'prev_long_word_end', 'next_sub_word_start',
    'prev_sub_word_start', 'next_sub_word_end', 'prev_sub_word_end',
  }
  for _, w in ipairs(word_fns) do
    local mf = MV['move_' .. w]
    reg('move_' .. w, function(ctx)
      local count = ctx:get_count()
      transform(function(text, r)
        return mf(text, r, count)
      end)
    end)
    reg('extend_' .. w, function(ctx)
      local count = ctx:get_count()
      transform(function(text, r)
        local word = mf(text, r, count)
        local pos = word:cursor(text)
        return r:put_cursor(text, pos, true)
      end)
    end)
  end

  local function goto_para(f, ctx)
    local count = ctx:get_count()
    H.apply_motion(function()
      local text = H.text()
      local extend = H.extend()
      H.set_sel(H.sel():transform(function(r)
        return f(text, r, count, extend)
      end))
    end)
  end
  reg('goto_prev_paragraph', function(ctx) goto_para(MV.move_prev_paragraph, ctx) end)
  reg('goto_next_paragraph', function(ctx) goto_para(MV.move_next_paragraph, ctx) end)

  local function goto_line_without_jumplist(count, extend)
    if not count then return end
    local text = H.text()
    local max_line
    local nl = text:len_lines()
    if #text:line(nl - 1) == 0 and not text:has_eol(nl - 1) then
      max_line = math.max(0, nl - 2)
    else
      max_line = nl - 1
    end
    local line = math.min(count - 1, max_line)
    local pos = text:line_start(line)
    H.set_sel(H.sel():transform(function(r)
      return r:put_cursor(text, pos, extend)
    end))
  end
  C.goto_line_without_jumplist = goto_line_without_jumplist

  local function goto_line_impl(ctx, extend)
    if ctx.count then
      H.push_jump()
      goto_line_without_jumplist(ctx.count, extend)
    end
  end
  reg('goto_line', function(ctx) goto_line_impl(ctx, false) end)

  local function goto_file_start_impl(ctx, extend)
    if ctx.count then
      goto_line_impl(ctx, extend)
    else
      local text = H.text()
      local sel = H.sel():transform(function(r)
        return r:put_cursor(text, 0, extend)
      end)
      H.push_jump()
      H.set_sel(sel)
    end
  end
  reg('goto_file_start', function(ctx) goto_file_start_impl(ctx, false) end)
  reg('extend_to_file_start', function(ctx) goto_file_start_impl(ctx, true) end)

  local function goto_file_end_impl(extend)
    local text = H.text()
    local pos = text:len()
    local sel = H.sel():transform(function(r)
      return r:put_cursor(text, pos, extend)
    end)
    H.push_jump()
    H.set_sel(sel)
  end
  reg('goto_file_end', function() goto_file_end_impl(false) end)
  reg('extend_to_file_end', function() goto_file_end_impl(true) end)

  local function goto_last_line_impl(extend)
    local text = H.text()
    local nl = text:len_lines()
    local line
    if #text:line(nl - 1) == 0 and not text:has_eol(nl - 1) then
      line = math.max(0, nl - 2)
    else
      line = nl - 1
    end
    local pos = text:line_start(line)
    local sel = H.sel():transform(function(r)
      return r:put_cursor(text, pos, extend)
    end)
    H.push_jump()
    H.set_sel(sel)
  end
  reg('goto_last_line', function() goto_last_line_impl(false) end)
  reg('extend_to_last_line', function() goto_last_line_impl(true) end)

  local function goto_column_impl(ctx, extend)
    local count = ctx:get_count()
    local text = H.text()
    local sel = H.sel():transform(function(r)
      local line = r:cursor_line(text)
      local ls = text:line_start(line)
      local le = text:line_end(line)
      local pos = math.min(text:next_grapheme(ls, count - 1), le)
      return r:put_cursor(text, pos, extend)
    end)
    H.push_jump()
    H.set_sel(sel)
  end
  reg('goto_column', function(ctx) goto_column_impl(ctx, false) end)
  reg('extend_to_column', function(ctx) goto_column_impl(ctx, true) end)

  local function pos_at_visual_row(win, vrow)
    local text = H.text()
    local view = api.nvim_win_call(win, vim.fn.winsaveview)
    local top = view.topline - 1
    local skip = view.skipcol or 0
    local row = top
    local acc = 0
    local nl = text.nlines or text:len_lines()
    while row < nl do
      local h = api.nvim_win_text_height(win, { start_row = row, end_row = row }).all
      if row == top and skip > 0 then
        local width = api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
        h = h - math.floor(skip / math.max(1, width))
      end
      if acc + h > vrow then
        local seg = vrow - acc
        if seg == 0 then return text:line_start(row) end
        local width = api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
        local l = text:line(row)
        local target = seg * width
        local col = vim.fn.byteidx(l, vim.fn.charidx(l, math.min(#l, vim.fn.virtcol2col(win, row + 1, target + 1) - 1)) or 0)
        if col < 0 then col = 0 end
        return text:line_start(row) + col
      end
      acc = acc + h
      row = row + 1
    end
    return text:line_start(math.max(0, nl - 1))
  end
  H.pos_at_visual_row = pos_at_visual_row

  local function visual_lines_in_view(win)
    local height = api.nvim_win_get_height(win)
    local text = H.text()
    local view = api.nvim_win_call(win, vim.fn.winsaveview)
    local top = view.topline - 1
    local acc = 0
    local row = top
    local nl = text.nlines or text:len_lines()
    while row < nl and acc < height do
      acc = acc + api.nvim_win_text_height(win, { start_row = row, end_row = row }).all
      row = row + 1
    end
    return math.min(acc, height)
  end
  H.visual_lines_in_view = visual_lines_in_view

  local function goto_window(ctx, align)
    local count = ctx:get_count() - 1
    local win = H.win()
    local height = api.nvim_win_get_height(win)
    local scrolloff = math.min(vim.wo[win].scrolloff, math.floor(math.max(0, height - 1) / 2))
    local last_visual_line = math.max(0, visual_lines_in_view(win) - 1)
    local vl
    if align == 'top' then
      vl = scrolloff + count
    elseif align == 'center' then
      vl = math.floor(last_visual_line / 2)
    else
      vl = math.max(0, last_visual_line - (scrolloff + count))
    end
    vl = math.max(vl, scrolloff)
    vl = math.min(vl, math.max(0, last_visual_line - scrolloff))
    local pos = pos_at_visual_row(win, vl)
    local text = H.text()
    local extend = H.extend()
    H.set_sel(H.sel():transform(function(r)
      return r:put_cursor(text, pos, extend)
    end))
  end
  reg('goto_window_top', function(ctx) goto_window(ctx, 'top') end)
  reg('goto_window_center', function(ctx) goto_window(ctx, 'center') end)
  reg('goto_window_bottom', function(ctx) goto_window(ctx, 'bottom') end)

  local function find_nth_char(text, n, ch, pos, forward)
    if n == 0 then return nil end
    if forward then
      local p = pos
      local len = text:len()
      if p > len then return nil end
      while p < len do
        local cp = text:char(p)
        if cp == ch then
          n = n - 1
          if n == 0 then return p end
        end
        p = text:next_char(p)
      end
      return nil
    else
      local p = pos
      while p > 0 do
        p = text:prev_char(p)
        local cp = text:char(p)
        if cp == ch then
          n = n - 1
          if n == 0 then return p end
        end
      end
      return nil
    end
  end

  local function find_char_line_ending_motion(count, forward, inclusive, extend)
    local text = H.text()
    H.set_sel(H.sel():transform(function(r)
      local cursor_anchor = r:cursor(text)
      local cursor_head = text:next_grapheme(cursor_anchor)
      local cursor_line = r:cursor_line(text)
      local pos
      if forward then
        local line_end = text:line_end(cursor_line)
        local on_edge
        if inclusive then
          on_edge = line_end == cursor_anchor
        else
          on_edge = line_end == cursor_head or line_end == cursor_anchor
        end
        local line = cursor_line + count - 1 + (on_edge and 1 or 0)
        if line >= text:len_lines() - 1 then return r end
        pos = text:line_end(line) - (inclusive and 0 or 1)
      else
        if inclusive then
          local line = cursor_line - count
          if line < 0 then return r end
          pos = text:line_end(line)
        else
          local on_edge = text:line_start(cursor_line) == cursor_anchor
          local line = cursor_line - count + 1 - (on_edge and 1 or 0)
          if line <= 0 then return r end
          pos = text:line_start(line)
        end
      end
      if extend then return r:put_cursor(text, pos, true) end
      return SL.Range.point(r:cursor(text)):put_cursor(text, pos, true)
    end))
  end

  local function find_char(ctx, forward, inclusive, extend)
    local count = ctx:get_count()
    ctx:on_next(function(_, key)
      local K = require('hx.keys')
      local motion
      if key == 'ret' then
        motion = function()
          find_char_line_ending_motion(count, forward, inclusive, extend)
        end
      else
        local ch
        if key == 'tab' then
          ch = '\t'
        else
          ch = K.char(key)
          if not ch then
            local p = K.parse(key)
            ch = K.code_char(p.code)
          end
        end
        if not ch then return end
        local cp = require('hx.util').decode(ch, 1)
        motion = function()
          local text = H.text()
          H.set_sel(H.sel():transform(function(r)
            local cursor_anchor = r:cursor(text)
            local cursor_head = text:next_grapheme(cursor_anchor)
            local start
            if inclusive and forward then
              start = cursor_head
            elseif inclusive then
              start = cursor_anchor
            elseif forward then
              start = text:next_char(cursor_head)
              if cursor_head >= text:len() then start = cursor_head + 1 end
            else
              start = text:prev_char(cursor_anchor)
            end
            local pos = find_nth_char(text, count, cp, start, forward)
            if not pos then return r end
            if not inclusive then
              if forward then
                pos = text:prev_char(pos)
              else
                pos = text:next_char(pos)
              end
            end
            if extend then return r:put_cursor(text, pos, true) end
            return SL.Range.point(r:cursor(text)):put_cursor(text, pos, true)
          end))
        end
      end
      H.apply_motion(motion)
    end)
  end
  reg('find_till_char', function(ctx) find_char(ctx, true, false, false) end)
  reg('find_next_char', function(ctx) find_char(ctx, true, true, false) end)
  reg('extend_till_char', function(ctx) find_char(ctx, true, false, true) end)
  reg('extend_next_char', function(ctx) find_char(ctx, true, true, true) end)
  reg('till_prev_char', function(ctx) find_char(ctx, false, false, false) end)
  reg('find_prev_char', function(ctx) find_char(ctx, false, true, false) end)
  reg('extend_till_prev_char', function(ctx) find_char(ctx, false, false, true) end)
  reg('extend_prev_char', function(ctx) find_char(ctx, false, true, true) end)

  reg('repeat_last_motion', function(ctx)
    local m = S.last_motion
    if m then
      for _ = 1, ctx:get_count() do
        m()
      end
    end
  end)

  local function win_scroll(win, n)
    if n == 0 then return end
    api.nvim_win_call(win, function()
      local key = n > 0 and '\5' or '\25'
      vim.cmd('silent! normal! ' .. math.abs(n) .. key)
    end)
  end
  H.win_scroll = win_scroll

  local function scroll(ctx, offset, forward, sync_cursor)
    local win = H.win()
    local text = H.text()
    local sel = H.sel()
    local range = sel:prim()
    local cursor = range:cursor(text)
    local height = api.nvim_win_get_height(win)
    local scrolloff = math.min(vim.wo[win].scrolloff, math.floor(math.max(0, height - 1) / 2))
    require('hx.render').sync_cursor(win)
    win_scroll(win, forward and offset or -offset)
    if sync_cursor then
      local extend = H.extend()
      H.set_sel(H.sel():transform(function(r)
        return MV.move_vertically_visual(text, r, forward, offset, extend, win)
      end))
      return
    end
    local head
    if forward then
      head = pos_at_visual_row(win, scrolloff)
      if head <= cursor then return end
    else
      head = pos_at_visual_row(win, height - scrolloff - 1)
      if head >= cursor then return end
    end
    local anchor = H.extend() and range.anchor or head
    local nsel = sel:replace(sel.primary, R(anchor, head))
    H.set_sel(nsel)
  end
  H.scroll = scroll

  local function inner_height()
    return api.nvim_win_get_height(H.win())
  end
  reg('page_up', function(ctx) scroll(ctx, inner_height(), false, false) end)
  reg('page_down', function(ctx) scroll(ctx, inner_height(), true, false) end)
  reg('half_page_up', function(ctx) scroll(ctx, math.floor(inner_height() / 2), false, false) end)
  reg('half_page_down', function(ctx) scroll(ctx, math.floor(inner_height() / 2), true, false) end)
  reg('page_cursor_up', function(ctx) scroll(ctx, inner_height(), false, true) end)
  reg('page_cursor_down', function(ctx) scroll(ctx, inner_height(), true, true) end)
  reg('page_cursor_half_up', function(ctx) scroll(ctx, math.floor(inner_height() / 2), false, true) end)
  reg('page_cursor_half_down', function(ctx) scroll(ctx, math.floor(inner_height() / 2), true, true) end)

  reg('jump_forward', function(ctx) D.jump_forward(ctx:get_count()) end)
  reg('jump_backward', function(ctx) D.jump_backward(ctx:get_count()) end)
  reg('save_selection', function()
    H.push_jump()
    H.status('Selection saved to jumplist')
  end)

  local function diags()
    return require('hx.lsp.diagnostics').doc_diagnostics(H.buf())
  end
  local function show_diag_now()
    local ok, dh = pcall(require, 'hx.lsp.diagnostics')
    if ok then dh.immediately_show(H.buf()) end
  end
  reg('goto_first_diag', function()
    local d = diags()[1]
    if not d then return end
    H.push_jump()
    H.set_sel(Sel.single(d.s, d.e))
    show_diag_now()
  end)
  reg('goto_last_diag', function()
    local ds = diags()
    local d = ds[#ds]
    if not d then return end
    H.push_jump()
    H.set_sel(Sel.single(d.s, d.e))
    show_diag_now()
  end)
  reg('goto_next_diag', function()
    H.apply_motion(function()
      local text = H.text()
      local cursor = H.sel():prim():cursor(text)
      for _, d in ipairs(diags()) do
        if d.s > cursor then
          H.push_jump()
          H.set_sel(Sel.single(d.s, d.e))
          show_diag_now()
          return
        end
      end
    end)
  end)
  reg('goto_prev_diag', function()
    H.apply_motion(function()
      local text = H.text()
      local cursor = H.sel():prim():cursor(text)
      local ds = diags()
      for i = #ds, 1, -1 do
        local d = ds[i]
        if d.s < cursor then
          H.push_jump()
          H.set_sel(Sel.single(d.e, d.s))
          show_diag_now()
          return
        end
      end
    end)
  end)

  local function hunk_range(text, h)
    local anchor = text:line_start(h.after_start)
    local head
    if h.after_end == h.after_start then
      head = anchor + 1
    else
      head = text:line_start(h.after_end)
    end
    return R(anchor, head)
  end

  local function hunks()
    local ok, diff = pcall(require, 'hx.diff')
    if not ok then return nil end
    return diff.hunks(H.buf())
  end

  local function goto_first_change_impl(reverse)
    local hs = hunks()
    if not hs or #hs == 0 then return end
    local h = reverse and hs[#hs] or hs[1]
    local r = hunk_range(H.text(), h)
    H.push_jump()
    H.set_sel(Sel.single(r.anchor, r.head))
  end
  reg('goto_first_change', function() goto_first_change_impl(false) end)
  reg('goto_last_change', function() goto_first_change_impl(true) end)

  local function goto_next_change_impl(ctx, forward)
    local count = ctx:get_count() - 1
    H.apply_motion(function()
      local hs = hunks()
      if not hs then
        H.status('Diff is not available in current buffer')
        return
      end
      local text = H.text()
      local extend = H.extend()
      local sel = H.sel():transform(function(r)
        local line = r:cursor_line(text)
        local idx
        if forward then
          for i, h in ipairs(hs) do
            if h.after_start > line then
              idx = i
              break
            end
          end
          if idx then idx = math.min(idx + count, #hs) end
        else
          for i = #hs, 1, -1 do
            local h = hs[i]
            local hend = h.after_end > h.after_start and h.after_end or h.after_start + 1
            if hend <= line then
              idx = i
              break
            end
          end
          if idx then idx = math.max(1, idx - count) end
        end
        if not idx then return r end
        local nr = hunk_range(text, hs[idx])
        if extend then
          local head = nr.head < r.anchor and nr.anchor or nr.head
          return R(r.anchor, head)
        end
        return nr:with_direction(forward)
      end)
      H.push_jump()
      H.set_sel(sel)
    end)
  end
  reg('goto_next_change', function(ctx) goto_next_change_impl(ctx, true) end)
  reg('goto_prev_change', function(ctx) goto_next_change_impl(ctx, false) end)

  local function goto_ts_object(ctx, object, forward)
    local count = ctx:get_count()
    H.apply_motion(function()
      local buf = H.buf()
      if not require('hx.syntax').has_tree(buf) then
        H.status('Syntax-tree is not available in current buffer')
        return
      end
      local text = H.text()
      local extend = H.extend()
      local sel = H.sel():transform(function(r)
        local nr = MV.goto_treesitter_object(buf, text, r, object, forward, count)
        if extend then
          local head = nr.head < r.anchor and nr.anchor or nr.head
          return R(r.anchor, head)
        end
        return nr:with_direction(forward)
      end)
      H.push_jump()
      H.set_sel(sel)
    end)
  end
  for name, obj in pairs({ function_ = 'function', class = 'class', parameter = 'parameter',
    comment = 'comment', test = 'test', entry = 'entry', xml_element = 'xml-element' }) do
    local n = name:gsub('_$', '')
    reg('goto_next_' .. n, function(ctx) goto_ts_object(ctx, obj, true) end)
    reg('goto_prev_' .. n, function(ctx) goto_ts_object(ctx, obj, false) end)
  end

  local function move_parent(forward, extend)
    local buf = H.buf()
    if not require('hx.syntax').has_tree(buf) then return end
    H.apply_motion(function()
      local text = H.text()
      H.set_sel(MV.move_parent_node_end(buf, text, H.sel(), forward, extend))
    end)
  end
  reg('move_parent_node_end', function() move_parent(true, H.extend()) end)
  reg('move_parent_node_start', function() move_parent(false, H.extend()) end)
  reg('extend_parent_node_end', function() move_parent(true, true) end)
  reg('extend_parent_node_start', function() move_parent(false, true) end)
end
