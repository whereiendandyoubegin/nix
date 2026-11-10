local S = require('hx.state')
local SL = require('hx.selection')
local MV = require('hx.movement')
local Syn = require('hx.syntax')
local U = require('hx.util')
local R = SL.R
local Sel = SL.Selection

return function(C, H)
  local reg = C.register

  reg('select_all', function()
    local text = H.text()
    H.set_sel(Sel.single(0, text:len()))
  end)

  reg('select_mode', function()
    local text = H.text()
    local len = text:len()
    H.set_sel(H.sel():transform(function(r)
      if r:is_empty() and r.head == len then return R(text:prev_grapheme(r.anchor), r.head) end
      return r
    end))
    S.set_mode('select')
  end)

  reg('exit_select_mode', function()
    if S.mode == 'select' then S.set_mode('normal') end
  end)

  reg('normal_mode', function()
    require('hx.cmd.modes').enter_normal_mode()
  end)

  reg('collapse_selection', function()
    local text = H.text()
    H.set_sel(H.sel():transform(function(r)
      local p = r:cursor(text)
      return R(p, p)
    end))
  end)

  reg('flip_selections', function()
    H.set_sel(H.sel():transform(function(r)
      return r:flip()
    end))
  end)

  reg('ensure_selections_forward', function()
    H.set_sel(H.sel():transform(function(r)
      return r:with_direction(true)
    end))
  end)

  reg('split_selection_on_newline', function()
    H.set_sel(SL.split_on_newline(H.text(), H.sel()))
  end)

  reg('merge_selections', function()
    H.set_sel(H.sel():merge_ranges())
  end)

  reg('merge_consecutive_selections', function()
    H.set_sel(H.sel():merge_consecutive_ranges())
  end)

  reg('keep_primary_selection', function()
    local r = H.sel():prim()
    H.set_sel(Sel.single(r.anchor, r.head))
  end)

  reg('remove_primary_selection', function()
    local sel = H.sel()
    if #sel.ranges == 1 then
      H.error('no selections remaining')
      return
    end
    H.set_sel(sel:remove(sel.primary))
  end)

  local function rotate(ctx, forward)
    local count = ctx:get_count()
    local sel = H.sel():copy()
    local len = #sel.ranges
    local idx = sel.primary - 1
    if forward then
      idx = (idx + count) % len
    else
      idx = (idx + (math.max(0, len - count) % len)) % len
    end
    sel.primary = idx + 1
    H.set_sel(sel)
  end
  reg('rotate_selections_forward', function(ctx) rotate(ctx, true) end)
  reg('rotate_selections_backward', function(ctx) rotate(ctx, false) end)
  reg('rotate_selections_first', function()
    local sel = H.sel():copy()
    sel.primary = 1
    H.set_sel(sel)
  end)
  reg('rotate_selections_last', function()
    local sel = H.sel():copy()
    sel.primary = #sel.ranges
    H.set_sel(sel)
  end)

  local function reorder(ctx, strategy)
    local text = H.text()
    local sel = H.sel()
    local frags = sel:fragments(text)
    local n = #frags
    local rotate_by = ctx.count and math.min(ctx.count, n) or 1
    local primary
    local out = {}
    if strategy == 'fwd' then
      for i = 1, n do
        out[((i - 1 + rotate_by) % n) + 1] = frags[i]
      end
      primary = ((sel.primary - 1) + n + rotate_by) % n + 1
    elseif strategy == 'back' then
      for i = 1, n do
        out[((i - 1 - rotate_by) % n + n) % n + 1] = frags[i]
      end
      primary = ((sel.primary - 1) + n - rotate_by) % n + 1
    else
      if rotate_by % 2 == 0 then return end
      for i = 1, n do
        out[n - i + 1] = frags[i]
      end
      primary = (n - 1) - (sel.primary - 1) + 1
    end
    local changes = {}
    for i, r in ipairs(sel.ranges) do
      changes[i] = { r:from(), r:to(), out[i] }
    end
    local nsel = sel:copy()
    nsel.primary = primary
    H.set_sel(nsel)
    H.apply(SL.Transaction.change(text, changes))
  end
  reg('rotate_selection_contents_forward', function(ctx) reorder(ctx, 'fwd') end)
  reg('rotate_selection_contents_backward', function(ctx) reorder(ctx, 'back') end)
  reg('reverse_selection_contents', function(ctx) reorder(ctx, 'rev') end)

  reg('trim_selections', function(ctx)
    local text = H.text()
    local sel = H.sel()
    local ranges = {}
    local ws = U.rust_whitespace
    for _, r in ipairs(sel.ranges) do
      local all_ws = true
      if not r:is_empty() then
        local p = r:from()
        while p < r:to() do
          if not ws(text:char(p)) then
            all_ws = false
            break
          end
          p = text:next_char(p)
        end
      end
      if not (r:is_empty() or all_ws) then
        local start, stop = r:from(), r:to()
        start = MV.skip_while(text, start, ws) or start
        stop = MV.backwards_skip_while(text, stop, ws) or stop
        ranges[#ranges + 1] = R(start, stop):with_direction(r:forward())
      end
    end
    if #ranges > 0 then
      local prim = sel:prim()
      local idx = #ranges
      for i, r in ipairs(ranges) do
        if r:overlaps(prim) then
          idx = i
          break
        end
      end
      H.set_sel(Sel.new(ranges, idx))
    else
      C.run('collapse_selection', ctx)
      C.run('keep_primary_selection', ctx)
    end
  end)

  reg('align_selections', function()
    local text = H.text()
    local sel = H.sel()
    local ts = H.tab_width()
    local column_widths = {}
    local coords = {}
    local previous_line = -1
    local col_idx, running = 0, 0
    for _, r in ipairs(sel.ranges) do
      local hrow = text:line_of(r.head)
      local arow = text:line_of(r.anchor)
      if hrow ~= arow then
        H.error('align cannot work with multi line selections')
        return
      end
      local col = text:visual_col(r.head, ts)
      if hrow ~= previous_line then
        col_idx, running, previous_line = 0, 0, hrow
      end
      local width = col - running
      column_widths[col_idx + 1] = math.max(column_widths[col_idx + 1] or 0, width)
      coords[#coords + 1] = { row = hrow, col = col }
      running = running + width
      col_idx = col_idx + 1
    end
    local positions = {}
    local sum = 0
    for i, w in ipairs(column_widths) do
      sum = sum + w
      positions[i] = sum
    end
    previous_line = -1
    local changes = {}
    for i, r in ipairs(sel.ranges) do
      local c = coords[i]
      if c.row ~= previous_line then
        col_idx, running, previous_line = 0, 0, c.row
      end
      local inserts = positions[col_idx + 1] - c.col - running
      col_idx = col_idx + 1
      running = running + inserts
      changes[#changes + 1] = { r:from(), r:from(), string.rep(' ', inserts) }
    end
    H.apply(SL.Transaction.change(text, changes))
    H.exit_select_mode()
  end)

  local function pos_at_visual_coords(text, row, col, ts)
    local l = text:line(row)
    local ls = text:line_start(row)
    local w = 0
    local i = 1
    while i <= #l do
      local cp, n = U.decode(l, i)
      local cw = cp == 9 and (ts - w % ts) or vim.api.nvim_strwidth(l:sub(i, i + n - 1))
      if w + cw > col then return ls + i - 1 end
      w = w + cw
      i = i + n
    end
    return ls + #l
  end

  local function copy_selection_on_line(ctx, forward)
    local count = ctx:get_count()
    local text = H.text()
    local sel = H.sel()
    local ts = H.tab_width()
    local ranges = {}
    for _, r in ipairs(sel.ranges) do
      ranges[#ranges + 1] = r
    end
    local primary_index = 1
    local nl = text:len_lines()
    for idx, r in ipairs(sel.ranges) do
      local is_primary = idx == sel.primary
      local head, anchor
      if r.anchor < r.head then
        head, anchor = text:prev_char(r.head), r.anchor
      else
        head, anchor = r.head, math.max(0, text:prev_char(r.anchor))
        if r.anchor == 0 then anchor = 0 end
      end
      local hrow, hcol = text:line_of(head), text:visual_col(head, ts)
      local arow, acol = text:line_of(anchor), text:visual_col(anchor, ts)
      local height = math.abs(hrow - arow) + 1
      if is_primary then primary_index = #ranges + 1 end
      ranges[#ranges + 1] = r
      local sels, i = 0, 0
      while sels < count do
        local offset = (i + 1) * height
        local anchor_row = forward and arow + offset or math.max(0, arow - offset)
        local head_row = forward and hrow + offset or math.max(0, hrow - offset)
        if anchor_row >= nl or head_row >= nl then break end
        local a = pos_at_visual_coords(text, anchor_row, acol, ts)
        local h = pos_at_visual_coords(text, head_row, hcol, ts)
        if text:visual_col(a, ts) == acol and text:visual_col(h, ts) == hcol then
          if is_primary then primary_index = #ranges + 1 end
          ranges[#ranges + 1] = SL.Range.point(a):put_cursor(text, h, true)
          sels = sels + 1
        end
        if anchor_row == 0 and head_row == 0 then break end
        i = i + 1
      end
    end
    H.set_sel(Sel.new(ranges, primary_index))
  end
  reg('copy_selection_on_next_line', function(ctx) copy_selection_on_line(ctx, true) end)
  reg('copy_selection_on_prev_line', function(ctx) copy_selection_on_line(ctx, false) end)

  local function extend_line_impl(ctx, below)
    local count = ctx:get_count()
    local text = H.text()
    local nl = text:len_lines()
    local function lts(l)
      return text:line_start(math.min(l, nl))
    end
    H.set_sel(H.sel():transform(function(r)
      local sl, el = r:line_range(text)
      local start = text:line_start(sl)
      local stop = lts(el + 1)
      local anchor, head
      if r:from() == start and r:to() == stop then
        if below then
          anchor, head = start, lts(math.min(el + count + 1, nl))
        else
          anchor, head = stop, text:line_start(math.max(0, sl - count))
        end
      else
        if below then
          anchor, head = start, lts(math.min(el + count, nl))
        else
          anchor, head = stop, text:line_start(math.max(0, sl - (count - 1)))
        end
      end
      return R(anchor, head)
    end))
  end
  reg('extend_line_below', function(ctx) extend_line_impl(ctx, true) end)
  reg('extend_line_above', function(ctx) extend_line_impl(ctx, false) end)
  reg('extend_line', function(ctx) extend_line_impl(ctx, H.sel():prim():forward()) end)

  local function select_line_impl(ctx, below)
    local count0 = ctx:get_count()
    local text = H.text()
    local nl = text:len_lines()
    local function sat(a, b)
      return math.min(a + b, nl)
    end
    local function lts(l)
      return text:line_start(math.min(l, nl))
    end
    H.set_sel(H.sel():transform(function(r)
      local count = count0
      local sl, el = r:line_range(text)
      local start = text:line_start(sl)
      local stop = lts(sat(el, 1))
      local fwd = r:forward()
      if r:from() ~= start or r:to() ~= stop then count = math.max(0, count - 1) end
      local al, hl
      if not below and fwd then
        al, hl = sl, math.max(0, el - count)
      elseif not below then
        al, hl = el, math.max(0, sl - count)
      elseif fwd then
        al, hl = sl, sat(el, count)
      else
        al, hl = el, sat(sl, count)
      end
      local a, h
      if al < hl then
        a, h = lts(al), lts(sat(hl, 1))
      elseif al == hl then
        if not below then
          a, h = lts(sat(al, 1)), lts(hl)
        else
          a, h = lts(hl), lts(sat(al, 1))
        end
      else
        a, h = lts(sat(al, 1)), lts(hl)
      end
      return R(a, h)
    end))
  end
  reg('select_line_below', function(ctx) select_line_impl(ctx, true) end)
  reg('select_line_above', function(ctx) select_line_impl(ctx, false) end)

  reg('extend_to_line_bounds', function()
    local text = H.text()
    local nl = text:len_lines()
    H.set_sel(H.sel():transform(function(r)
      local sl, el = r:line_range(text)
      local start = text:line_start(sl)
      local stop = text:line_start(math.min(el + 1, nl))
      return R(start, stop):with_direction(r:forward())
    end))
  end)

  reg('shrink_to_line_bounds', function()
    local text = H.text()
    local nl = text:len_lines()
    H.set_sel(H.sel():transform(function(r)
      local sl, el = r:line_range(text)
      if sl == el then return r end
      local start = text:line_start(sl)
      local stop = text:line_start(math.min(el + 1, nl))
      if start ~= r:from() then start = text:line_start(math.min(sl + 1, nl)) end
      if stop ~= r:to() then stop = text:line_start(el) end
      return R(start, stop):with_direction(r:forward())
    end))
  end)

  local function regex_cmd(ctx, prompt, fn)
    local regname = ctx.register or '/'
    require('hx.ui.prompt').regex_prompt({
      prompt = prompt,
      register = regname,
      callback = function(regex, event)
        if event ~= 'update' and event ~= 'validate' then return end
        fn(regex, event)
      end,
    })
  end

  reg('select_regex', function(ctx)
    regex_cmd(ctx, 'select:', function(regex, event)
      local s = SL.select_on_matches(H.text(), H.sel(), regex)
      if s then
        H.set_sel(s)
      elseif event == 'validate' then
        H.error('nothing selected')
      end
    end)
  end)

  reg('split_selection', function(ctx)
    regex_cmd(ctx, 'split:', function(regex)
      H.set_sel(SL.split_on_matches(H.text(), H.sel(), regex))
    end)
  end)

  local function keep_or_remove(ctx, remove)
    regex_cmd(ctx, remove and 'remove:' or 'keep:', function(regex, event)
      local s = SL.keep_or_remove_matches(H.text(), H.sel(), regex, remove)
      if s then
        H.set_sel(s)
      elseif event == 'validate' then
        H.error('no selections remaining')
      end
    end)
  end
  reg('keep_selections', function(ctx) keep_or_remove(ctx, false) end)
  reg('remove_selections', function(ctx) keep_or_remove(ctx, true) end)

  local function root()
    return Syn.root(H.buf())
  end
  local function srange(n)
    return Syn.byte_range(n)
  end

  reg('expand_selection', function()
    H.apply_motion(function()
      local rt = root()
      if not rt then return end
      local cur = H.sel()
      local sel = cur:transform(function(r)
        local from, to = r:from(), r:to()
        local node = Syn.reset_to_byte_range(rt, from, to)
        while true do
          local s, e = srange(node)
          if s == from and e == to then
            local p = node:parent()
            if not p then break end
            node = p
          else
            break
          end
        end
        local s, e = srange(node)
        return R(e, s):with_direction(r:forward())
      end)
      if not cur:eq(sel) then
        local v = S.view(H.win())
        v.object_selections = v.object_selections or {}
        table.insert(v.object_selections, cur:copy())
        H.set_sel(sel)
      end
    end)
  end)

  local function select_node_impl(motion, direction)
    local rt = root()
    if not rt then return end
    H.set_sel(H.sel():transform(function(r)
      local node = Syn.reset_to_byte_range(rt, r:from(), r:to())
      node = motion(node) or node
      local s, e = srange(node)
      local fwd = direction
      if fwd == nil then fwd = r:forward() end
      return R(s, e):with_direction(fwd)
    end))
  end

  reg('shrink_selection', function()
    H.apply_motion(function()
      local v = S.view(H.win())
      v.object_selections = v.object_selections or {}
      local cur = H.sel()
      local prev = table.remove(v.object_selections)
      if prev then
        local contained = true
        for _, pr in ipairs(prev.ranges) do
          local ok = false
          for _, cr in ipairs(cur.ranges) do
            if cr:contains_range(pr) then
              ok = true
              break
            end
          end
          if not ok then
            contained = false
            break
          end
        end
        if contained then
          H.set_sel(prev)
          return
        end
        v.object_selections = {}
      end
      select_node_impl(function(node)
        return node:child(0)
      end, nil)
    end)
  end)

  reg('select_next_sibling', function()
    H.apply_motion(function()
      select_node_impl(function(node)
        local n = node
        while true do
          local s = n:next_sibling()
          if s then return s end
          local p = n:parent()
          if not p then return n end
          n = p
        end
      end, true)
    end)
  end)

  reg('select_prev_sibling', function()
    H.apply_motion(function()
      select_node_impl(function(node)
        local n = node
        while true do
          local s = n:prev_sibling()
          if s then return s end
          local p = n:parent()
          if not p then return n end
          n = p
        end
      end, false)
    end)
  end)

  local function select_children(node, r)
    local out = {}
    for child in node:iter_children() do
      if child:named() then
        local s, e = srange(child)
        out[#out + 1] = R(s, e):with_direction(r:forward())
      end
    end
    if #out == 0 then return { r } end
    return out
  end

  reg('select_all_siblings', function()
    H.apply_motion(function()
      local rt = root()
      if not rt then return end
      H.set_sel(H.sel():transform_iter(function(r)
        local node = Syn.reset_to_byte_range(rt, r:from(), r:to())
        local p = node:parent()
        while p and p:child_count() <= 1 do
          p = p:parent()
        end
        if not p then return { r } end
        return select_children(p, r)
      end))
    end)
  end)

  reg('select_all_children', function()
    H.apply_motion(function()
      local rt = root()
      if not rt then return end
      H.set_sel(H.sel():transform_iter(function(r)
        local node = Syn.reset_to_byte_range(rt, r:from(), r:to())
        return select_children(node, r)
      end))
    end)
  end)

  reg('match_brackets', function()
    local MB = require('hx.match_brackets')
    local text = H.text()
    local buf = H.buf()
    local is_select = S.mode == 'select'
    local has_tree = Syn.has_tree(buf)
    H.set_sel(H.sel():transform(function(r)
      local pos = r:cursor(text)
      local m
      if has_tree then
        m = MB.find_matching_bracket_fuzzy(buf, text, pos)
      else
        m = MB.find_matching_bracket_plaintext(text, pos)
      end
      if m then return r:put_cursor(text, m, is_select) end
      return r
    end))
  end)
end
