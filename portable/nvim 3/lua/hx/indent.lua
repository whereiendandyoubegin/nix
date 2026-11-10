local U = require('hx.util')
local Text = require('hx.text')
local ts = vim.treesitter

local M = {}

local decode = U.decode

local rust_ws = U.rust_whitespace

local function grapheme_width(g)
  if g:byte(1) <= 127 then return 1 end
  local w = vim.api.nvim_strwidth(g)
  return w > 1 and w or 1
end

local function graphemes(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local cp, len = decode(s, i)
    local j = i + len
    if cp == 13 and s:byte(j) == 10 then
      j = j + 1
    else
      while j <= n do
        local cp2, len2 = decode(s, j)
        if U.is_extender(cp2) then
          j = j + len2
        else
          break
        end
      end
    end
    out[#out + 1] = s:sub(i, j - 1)
    i = j
  end
  return out
end

local function tab_width_at(visual_x, tab_width)
  return tab_width - (visual_x % tab_width)
end

local function visual_end_col(s, tab_width)
  local last = s:match('[^\n]*$') or s
  local col = 0
  for _, g in ipairs(graphemes(last)) do
    if g == '\t' then
      col = col + (tab_width - (col % tab_width))
    else
      col = col + grapheme_width(g)
    end
  end
  return col
end

local function pos_at_visual_col(s, col, tab_width)
  local first = s:match('^[^\r\n]*') or ''
  local off = 0
  local remaining = col
  for _, g in ipairs(graphemes(first)) do
    local w
    if g == '\t' then
      w = tab_width - ((col - remaining) % tab_width)
    else
      w = grapheme_width(g)
    end
    if w > remaining then break end
    remaining = remaining - w
    off = off + #g
  end
  return off
end

local function line_with_eol(text, row)
  local l = text:line(row)
  if text:has_eol(row) then l = l .. '\n' end
  return l
end

local function first_non_whitespace(text, row)
  local l = text:line(row)
  local i, n = 1, #l
  while i <= n do
    local cp, len = decode(l, i)
    if not rust_ws(cp) then return i - 1 end
    i = i + len
  end
  return nil
end
M.first_non_whitespace = first_non_whitespace

M.MAX_INDENT = 16
local INDENTS = string.rep(' ', M.MAX_INDENT)

local IndentStyle = {}
IndentStyle.__index = IndentStyle
M.IndentStyle = IndentStyle

function IndentStyle.tabs()
  return setmetatable({ tabs = true }, IndentStyle)
end

function IndentStyle.spaces(n)
  return setmetatable({ tabs = false, n = n }, IndentStyle)
end

function IndentStyle.from_str(indent)
  if type(indent) == 'table' then return indent end
  if indent:sub(1, 1) == ' ' then
    return IndentStyle.spaces(U.clamp(#indent, 1, M.MAX_INDENT))
  end
  return IndentStyle.tabs()
end

function IndentStyle:as_str()
  if self.tabs then return '\t' end
  return INDENTS:sub(1, U.clamp(self.n, 1, M.MAX_INDENT))
end

function IndentStyle:indent_width(tab_width)
  if self.tabs then return tab_width end
  return self.n
end

function IndentStyle:__eq(o)
  return self.tabs == o.tabs and (self.tabs or self.n == o.n)
end

function M.auto_detect_indent_style(text)
  if type(text) == 'string' then text = Text.from_string(text) end
  local hist = {}
  for i = 0, M.MAX_INDENT do
    hist[i] = 0
  end
  local prev_is_tabs, prev_count = false, 0
  local is_eol, is_ws = U.is_line_ending, U.is_whitespace
  local nlines = math.min(text:len_lines(), 1000)
  for row = 0, nlines - 1 do
    local l = line_with_eol(text, row)
    local skip = false
    local is_tabs
    local c = #l > 0 and decode(l, 1) or nil
    if c == 9 then
      is_tabs = true
    elseif c == 32 then
      is_tabs = false
    elseif c and is_eol(c) then
      skip = true
    else
      prev_is_tabs, prev_count = false, 0
      skip = true
    end
    if not skip then
      local count, done = 1, false
      local i = 2
      while i <= #l do
        local ch, len = decode(l, i)
        i = i + len
        if ch == 9 and is_tabs and not done then
          count = count + 1
        elseif ch == 32 and not is_tabs and not done then
          count = count + 1
        elseif is_ws(ch) then
          done = true
        elseif is_eol(ch) then
          skip = true
          break
        else
          break
        end
        if count > 256 then
          skip = true
          break
        end
      end
      if not skip then
        if (prev_is_tabs == is_tabs or prev_count == 0) and prev_count < count then
          if is_tabs then
            hist[0] = hist[0] + 1
          else
            local amount = count - prev_count
            if amount <= M.MAX_INDENT then hist[amount] = hist[amount] + 1 end
          end
        end
        prev_is_tabs, prev_count = is_tabs, count
      end
    end
  end
  hist[0] = hist[0] * 2
  if hist[1] > 1 then hist[1] = math.floor(hist[1] / 2) end
  local indent = 0
  for i = 0, M.MAX_INDENT do
    if hist[i] >= hist[indent] then indent = i end
  end
  local freq = hist[indent]
  local freq2 = 0
  for i = 0, M.MAX_INDENT do
    if i ~= indent and hist[i] > freq2 then freq2 = hist[i] end
  end
  if freq >= 1 and (freq2 / freq) < 0.66 then
    if indent == 0 then return IndentStyle.tabs() end
    return IndentStyle.spaces(indent)
  end
  return nil
end

function M.indent_level_for_line(line, tab_width, indent_width)
  local len = 0
  for i = 1, #line do
    local b = line:byte(i)
    if b == 9 then
      len = len + tab_width_at(len, tab_width)
    elseif b == 32 then
      len = len + 1
    else
      break
    end
  end
  return math.floor(len / indent_width)
end

local function whitespace_with_same_width(s)
  local out = {}
  for _, g in ipairs(graphemes(s)) do
    if g == '\t' then
      out[#out + 1] = '\t'
    else
      out[#out + 1] = string.rep(' ', grapheme_width(g))
    end
  end
  return table.concat(out)
end
M.whitespace_with_same_width = whitespace_with_same_width

function M.normalize_indentation(prefix, line, indent_style, tab_width)
  indent_style = IndentStyle.from_str(indent_style)
  local off = visual_end_col(prefix, tab_width)
  local len, original_len = 0, 0
  for i = 1, #line do
    local b = line:byte(i)
    if b == 9 then
      len = len + tab_width_at(len + off, tab_width)
    elseif b == 32 then
      len = len + 1
    else
      break
    end
    original_len = original_len + 1
  end
  local dst = ''
  if indent_style.tabs then
    dst = string.rep('\t', math.floor(len / tab_width))
    len = len % tab_width
  end
  return dst .. string.rep(' ', len), original_len
end

local function add_indent_level(base_indent, added, indent_style, tab_width)
  if added >= 0 then return base_indent .. indent_style:as_str():rep(added) end
  local base_width = visual_end_col(base_indent, tab_width)
  local target = math.max(0, base_width - (-added) * indent_style:indent_width(tab_width))
  return base_indent:sub(1, pos_at_visual_col(base_indent, target, tab_width))
end
M.add_indent_level = add_indent_level

local Indentation = {}
Indentation.__index = Indentation
M.Indentation = Indentation

function Indentation.new(t)
  t = t or {}
  return setmetatable({
    indent = t.indent or 0,
    indent_always = t.indent_always or 0,
    outdent = t.outdent or 0,
    outdent_always = t.outdent_always or 0,
    align = t.align,
  }, Indentation)
end

function Indentation:net_indent()
  return (self.indent + self.indent_always) - (self.outdent + self.outdent_always)
end

function Indentation:relative_indent(other, other_leading_ws, indent_style, tab_width)
  indent_style = IndentStyle.from_str(indent_style)
  if self.align == other.align then
    local diff = self:net_indent() - other:net_indent()
    return add_indent_level(other_leading_ws, diff, indent_style, tab_width)
  end
  return nil
end

function Indentation:to_string(indent_style, tab_width)
  indent_style = IndentStyle.from_str(indent_style)
  local base = self.align and whitespace_with_same_width(self.align) or ''
  return add_indent_level(base, self:net_indent(), indent_style, tab_width)
end

local predicates_registered = false
local function register_predicates()
  if predicates_registered then return end
  predicates_registered = true
  local function pass(_, _, _, pred)
    return pred[1]:sub(1, 4) ~= 'not-'
  end
  for _, name in ipairs({ 'kind-eq?', 'same-line?', 'one-line?' }) do
    ts.query.add_predicate(name, pass, { force = true, all = true })
  end
end

local builtin_predicates = {
  ['eq?'] = true, ['not-eq?'] = true, ['any-eq?'] = true, ['any-not-eq?'] = true,
  ['match?'] = true, ['not-match?'] = true, ['any-match?'] = true, ['any-not-match?'] = true,
  ['any-of?'] = true, ['not-any-of?'] = true,
}

local iq_cache = {}

function M.get_indent_query(lang)
  local cached = iq_cache[lang]
  if cached ~= nil then return cached or nil end
  register_predicates()
  local q = require('hx.syntax').get_query(lang, 'indents')
  if not q then
    iq_cache[lang] = false
    return nil
  end
  local ids = {}
  for id, name in ipairs(q.captures) do
    ids[name] = id
  end
  local header_patterns, predicates = {}, {}
  local valid = true
  for pattern, list in pairs(q.info.patterns or {}) do
    for _, pred in ipairs(list) do
      local name = pred[1]
      local function cap(i)
        if type(pred[i + 1]) ~= 'number' then valid = false end
        return pred[i + 1]
      end
      local function str(i)
        if type(pred[i + 1]) ~= 'string' then valid = false end
        return pred[i + 1]
      end
      local function nargs(n)
        if #pred - 1 ~= n then valid = false end
      end
      local p = predicates[pattern]
      local function entry()
        p = p or { not_kind_eq = {} }
        predicates[pattern] = p
        return p
      end
      if name == 'set!' then
        if pred[2] == 'scope' then
          if pred[3] == 'header' then
            header_patterns[pattern] = true
          else
            valid = false
          end
        else
          valid = false
        end
      elseif name == 'not-kind-eq?' then
        nargs(2)
        table.insert(entry().not_kind_eq, { cap(1), str(2) })
      elseif name == 'same-line?' or name == 'not-same-line?' then
        nargs(2)
        entry().same_line = { cap(1), cap(2), name == 'not-same-line?' }
      elseif name == 'one-line?' or name == 'not-one-line?' then
        nargs(1)
        entry().one_line = { cap(1), name == 'not-one-line?' }
      elseif not builtin_predicates[name] then
        valid = false
      end
    end
  end
  if not valid then
    vim.schedule(function()
      vim.notify(('hx: invalid indent query for %s'):format(lang), vim.log.levels.WARN)
    end)
    iq_cache[lang] = false
    return nil
  end
  local iq = {
    lang = lang,
    query = q,
    header_patterns = header_patterns,
    predicates = predicates,
    indent_capture = ids['indent'],
    indent_always_capture = ids['indent.always'],
    outdent_capture = ids['outdent'],
    outdent_always_capture = ids['outdent.always'],
    align_capture = ids['align'],
    anchor_capture = ids['anchor'],
    extend_capture = ids['extend'],
    extend_prevent_once_capture = ids['extend.prevent-once'],
    opaque_capture = ids['opaque'],
  }
  iq_cache[lang] = iq
  return iq
end

function M.clear_cache()
  iq_cache = {}
end

function M.syntax_for(buf, lang)
  if type(buf) == 'table' then return buf end
  if not buf then return nil end
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local S = require('hx.syntax')
  local parser
  if lang then
    local ok, p = pcall(ts.get_parser, buf, lang, { error = false })
    if ok then parser = p end
  else
    parser = S.parser(buf)
  end
  if not parser then return nil end
  local ok, trees = pcall(parser.parse, parser, true)
  if not ok or not trees or not trees[1] then return nil end
  return { buf = buf, parser = parser, lang = parser:lang(), tree = trees[1] }
end

local function byte_range(node)
  local _, _, sb, _, _, eb = node:range(true)
  return sb, eb
end

local function rc(text, pos)
  local row = text:line_of(pos)
  return row, pos - text:line_start(row)
end

local function layer_for_byte(syn, text, b)
  local r, c = rc(text, b)
  local ok, lt = pcall(syn.parser.language_for_range, syn.parser, { r, c, r, c })
  if ok and lt then return lt end
  return syn.parser
end

local function tree_for_byte(syn, text, b)
  local lt = layer_for_byte(syn, text, b)
  if lt ~= syn.parser then
    local r, c = rc(text, b)
    local ok, tree = pcall(lt.tree_for_range, lt, { r, c, r, c }, { ignore_injections = true })
    if ok and tree then return tree end
  end
  return syn.tree
end

local function start_line(text, node, new_line_byte_pos)
  local sr, _, sb = node:start()
  if new_line_byte_pos and sb >= new_line_byte_pos then sr = sr + 1 end
  return sr
end

local function end_line(text, node, new_line_byte_pos)
  local er, _, eb = node:end_()
  if new_line_byte_pos and eb > new_line_byte_pos then er = er + 1 end
  return er
end

local function first_node(match, capture)
  local nodes = capture and match[capture]
  return nodes and nodes[1]
end

local function are_satisfied(preds, match, text, new_line_byte_pos)
  for _, nk in ipairs(preds.not_kind_eq) do
    local node = first_node(match, nk[1])
    if node and node:type() == nk[2] then return false end
  end
  if preds.same_line then
    local c1, c2, negated = preds.same_line[1], preds.same_line[2], preds.same_line[3]
    local n1, n2 = first_node(match, c1), first_node(match, c2)
    local ok = false
    if n1 and n2 then
      local same = start_line(text, n1, new_line_byte_pos) == start_line(text, n2, new_line_byte_pos)
      ok = same ~= negated
    end
    if not ok then return false end
  end
  if preds.one_line then
    local node = first_node(match, preds.one_line[1])
    local ok = false
    if node then
      local one = end_line(text, node, new_line_byte_pos) == start_line(text, node, new_line_byte_pos)
      ok = one ~= preds.one_line[2]
    end
    if not ok then return false end
  end
  return true
end

local function query_indents(iq, root, src, text, range_start, range_end, new_line_byte_pos)
  local indent_captures, extend_captures, opaque_ranges = {}, {}, {}
  local q = iq.query
  local start_row = text:line_of(math.max(range_start, 0))
  local stop_row = text:line_of(math.max(range_end, 0)) + 1
  local ok, err = pcall(function()
    for pattern, match in q:iter_matches(root, src, start_row, stop_row, { all = true, match_limit = 256 }) do
      local preds = iq.predicates[pattern]
      if not (preds and not are_satisfied(preds, match, text, new_line_byte_pos)) then
        local added = {}
        local anchor
        local cap_ids = vim.tbl_keys(match)
        table.sort(cap_ids)
        local header = iq.header_patterns[pattern] or false
        for _, capture in ipairs(cap_ids) do
          for _, node in ipairs(match[capture]) do
            local id = node:id()
            local ctype
            if capture == iq.indent_capture then
              ctype = 'indent'
            elseif capture == iq.indent_always_capture then
              ctype = 'indent_always'
            elseif capture == iq.outdent_capture then
              ctype = 'outdent'
            elseif capture == iq.outdent_always_capture then
              ctype = 'outdent_always'
            elseif capture == iq.align_capture then
              ctype = 'align'
            elseif capture == iq.anchor_capture then
              if not anchor then anchor = node end
            elseif capture == iq.extend_capture then
              local l = extend_captures[id] or {}
              extend_captures[id] = l
              l[#l + 1] = 'extend'
            elseif capture == iq.extend_prevent_once_capture then
              local l = extend_captures[id] or {}
              extend_captures[id] = l
              l[#l + 1] = 'prevent_once'
            elseif capture == iq.opaque_capture then
              local s, e = byte_range(node)
              opaque_ranges[#opaque_ranges + 1] = { s, e }
            end
            if ctype then added[#added + 1] = { id, { type = ctype, header = header } } end
          end
        end
        for _, a in ipairs(added) do
          local id, cap = a[1], a[2]
          local keep = true
          if cap.type == 'align' then
            if not anchor then
              keep = false
            else
              local as = byte_range(anchor)
              local line_start = text:line_start(text:line_of(as))
              cap.align = text:slice(line_start, as)
            end
          end
          if keep then
            local l = indent_captures[id] or {}
            indent_captures[id] = l
            l[#l + 1] = cap
          end
        end
      end
    end
  end)
  if not ok then return nil, err end
  return { indent_captures = indent_captures, extend_captures = extend_captures, opaque_ranges = opaque_ranges }
end

local function extend_nodes(node, deepest_preceding, extend_captures, text, line, tab_width, indent_width)
  local stop_extend = false
  local node_id = node:id()
  while deepest_preceding:id() ~= node_id do
    local extend_node = false
    local node_captured = false
    local captures = extend_captures[deepest_preceding:id()]
    if captures then
      for _, capture in ipairs(captures) do
        if capture == 'prevent_once' then
          stop_extend = true
        else
          node_captured = true
          local er = deepest_preceding:end_()
          if er == line then
            extend_node = true
          else
            local cursor_indent = M.indent_level_for_line(text:line(line), tab_width, indent_width)
            local node_indent =
              M.indent_level_for_line(text:line((deepest_preceding:start())), tab_width, indent_width)
            if cursor_indent > node_indent then extend_node = true end
          end
        end
      end
    end
    if node_captured and stop_extend then
      stop_extend = false
    elseif extend_node and not stop_extend then
      return deepest_preceding
    end
    local parent = deepest_preceding:parent()
    if not parent then return node end
    deepest_preceding = parent
  end
  return node
end

local function candidate_body_for_new_line(deepest_preceding, byte_pos)
  local node = deepest_preceding
  while true do
    local parent = node:parent()
    if not parent then break end
    local _, ne = byte_range(node)
    if ne > byte_pos then break end
    local nid = node:id()
    local found = false
    for child in parent:iter_children() do
      if found then
        local cs = byte_range(child)
        if cs >= byte_pos then return child end
        break
      end
      if child:id() == nid then found = true end
    end
    node = parent
  end
  return nil
end

local function init_indent_query(iq, root, src, text, tab_width, indent_width, line, byte_pos, new_line_byte_pos)
  local r, c = rc(text, byte_pos)
  local node = root:descendant_for_range(r, c, r, c)
  if not node then return nil end

  local deepest_preceding
  for child in node:iter_children() do
    local _, ce = byte_range(child)
    if ce <= byte_pos then deepest_preceding = child end
  end
  if deepest_preceding then
    while deepest_preceding:child_count() > 0 do
      deepest_preceding = deepest_preceding:child(deepest_preceding:child_count() - 1)
    end
  end
  local candidate_body
  if new_line_byte_pos and deepest_preceding then
    candidate_body = candidate_body_for_new_line(deepest_preceding, byte_pos)
  end
  local upper = candidate_body and select(2, byte_range(candidate_body)) or byte_pos + 1
  local qstart = byte_pos
  if deepest_preceding then qstart = select(2, byte_range(deepest_preceding)) - 1 end

  local result = query_indents(iq, root, src, text, qstart, upper, new_line_byte_pos)
  if not result then return nil end

  local descended = false
  if candidate_body then
    local defs = result.indent_captures[candidate_body:id()]
    if defs then
      for _, d in ipairs(defs) do
        if d.header then
          descended = true
          break
        end
      end
    end
    if descended then node = candidate_body end
  end
  if deepest_preceding and not descended then
    node = extend_nodes(node, deepest_preceding, result.extend_captures, text, line, tab_width, indent_width)
  end
  return node, result.indent_captures, result.opaque_ranges
end

local function opaque_hit(s, e, byte_pos, text)
  return s <= byte_pos and byte_pos < e and text:line_of(s) < text:line_of(byte_pos)
end

local function containment_accounting(iq, root, src, text, tab_width, indent_width, line, byte_pos, new_line)
  local nlb = new_line and byte_pos or nil
  local start_node, captures, opaque_ranges =
    init_indent_query(iq, root, src, text, tab_width, indent_width, line, byte_pos, nlb)
  if not start_node then return nil end

  for _, r in ipairs(opaque_ranges) do
    if opaque_hit(r[1], r[2], byte_pos, text) then return Indentation.new(), true end
  end

  local target_line = line + (new_line and 1 or 0)
  local indent_levels, indent_always, outdent, outdent_always = 0, 0, 0, 0
  local align
  local counted = {}

  local node = start_node
  while node do
    local defs = captures[node:id()]
    if defs then
      local has_indent, has_indent_always, has_outdent, has_outdent_always = false, false, false, false
      local header_scoped = false
      local node_align
      for _, def in ipairs(defs) do
        local t = def.type
        if t == 'indent' then
          has_indent = true
          header_scoped = header_scoped or def.header
        elseif t == 'indent_always' then
          has_indent_always = true
          header_scoped = header_scoped or def.header
        elseif t == 'outdent' then
          has_outdent = true
        elseif t == 'outdent_always' then
          has_outdent_always = true
        elseif t == 'align' then
          node_align = def.align
        end
      end
      local node_start = start_line(text, node, nlb)
      local stop = end_line(text, node, nlb)
      local start = node_start
      if header_scoped then
        local p = node:parent()
        if p then start = start_line(text, p, nlb) end
      end
      local contains = start < target_line and target_line <= stop
      local opens_target = node_start == target_line
      if (has_indent or has_indent_always) and (has_outdent or has_outdent_always) then
      else
        if has_indent and contains and not counted[start] then
          counted[start] = true
          indent_levels = indent_levels + 1
        end
        if has_indent_always and contains then indent_always = indent_always + 1 end
        if has_outdent and opens_target then outdent = outdent + 1 end
        if has_outdent_always and opens_target then outdent_always = outdent_always + 1 end
      end
      if node_align and contains and align == nil then align = node_align end
    end
    node = node:parent()
  end

  if align ~= nil then
    indent_levels = 0
    indent_always = 0
  end
  return Indentation.new({
    indent = indent_levels,
    indent_always = indent_always,
    outdent = outdent,
    outdent_always = outdent_always,
    align = align,
  }), false
end

local function injection_base_level(syn, text, byte_pos, tab_width, indent_width)
  local layer = layer_for_byte(syn, text, byte_pos)
  local function in_layer(row)
    local fnw = first_non_whitespace(text, row)
    if not fnw then return false end
    return layer_for_byte(syn, text, text:line_start(row) + fnw) == layer
  end
  local bl = text:line_of(byte_pos)
  local first
  if in_layer(bl) then
    first = bl
    while first > 0 and in_layer(first - 1) do
      first = first - 1
    end
  else
    local total = text:len_lines()
    first = bl + 1
    while first + 1 < total and not in_layer(first) do
      first = first + 1
    end
  end
  return M.indent_level_for_line(text:line(first), tab_width, indent_width)
end

function M.treesitter_indent_for_pos(query, syntax, tab_width, indent_width, text, line, pos, new_line)
  local syn = M.syntax_for(syntax)
  if not syn or not query then return nil end
  text = text or Text.get(syn.buf)
  local byte_pos = pos
  local layer = layer_for_byte(syn, text, byte_pos)
  local injected
  if layer ~= syn.parser and layer:lang() ~= syn.lang then injected = M.get_indent_query(layer:lang()) end
  query = injected or query
  local tree = injected and tree_for_byte(syn, text, byte_pos) or syn.tree
  local root = tree:root()

  local result, opaque =
    containment_accounting(query, root, syn.buf, text, tab_width, indent_width, line, byte_pos, new_line)
  if not result then return nil end
  if opaque then
    local l = line_with_eol(text, line)
    local first = first_non_whitespace(text, line) or #l
    return Indentation.new({ align = l:sub(1, first) })
  end
  if injected then
    result.indent = result.indent + injection_base_level(syn, text, byte_pos, tab_width, indent_width)
  end
  return result
end

function M.is_opaque_interior(query, syntax, text, byte_pos)
  local syn = M.syntax_for(syntax)
  if not syn or not query or not query.opaque_capture then return false end
  text = text or Text.get(syn.buf)
  local root = tree_for_byte(syn, text, byte_pos):root()
  local hit = false
  local start_row = text:line_of(byte_pos)
  local stop_row = text:line_of(byte_pos + 1) + 1
  pcall(function()
    for _, match in query.query:iter_matches(root, syn.buf, start_row, stop_row, { all = true, match_limit = 256 }) do
      for _, node in ipairs(match[query.opaque_capture] or {}) do
        local s, e = byte_range(node)
        if opaque_hit(s, e, byte_pos, text) then
          hit = true
          return
        end
      end
    end
  end)
  return hit
end

function M.is_outdent_token_at(query, syntax, text, byte_pos)
  local syn = M.syntax_for(syntax)
  if not syn or not query then return false end
  text = text or Text.get(syn.buf)
  local root = tree_for_byte(syn, text, byte_pos):root()
  local r, c = rc(text, byte_pos)
  local node = root:descendant_for_range(r, c, r, c)
  if not node then return false end
  local result = query_indents(query, root, syn.buf, text, byte_pos, byte_pos + 1, nil)
  if not result then return false end
  while true do
    for _, cap in ipairs(result.indent_captures[node:id()] or {}) do
      if cap.type == 'outdent' or cap.type == 'outdent_always' then return true end
    end
    local parent = node:parent()
    if parent and byte_range(parent) == byte_range(node) then
      node = parent
    else
      return false
    end
  end
end

local MAX_ATTEMPTS = 4

function M.indent_for_newline(buf, text, line_before, line_before_end_pos, current_line, opts)
  opts = opts or {}
  local indent_style = IndentStyle.from_str(opts.indent_unit or opts.indent_style or '    ')
  local tab_width = opts.tab_width or 4
  local heuristic = opts.heuristic or opts.indent_heuristic or 'hybrid'
  if type(text) == 'string' then
    text = Text.from_string(text)
  elseif text == nil then
    text = Text.get(buf)
  end
  local indent_width = indent_style:indent_width(tab_width)

  local syn = buf and M.syntax_for(buf, opts.lang) or nil
  local query = syn and M.get_indent_query(opts.lang or syn.lang) or nil
  if (heuristic == 'tree-sitter' or heuristic == 'hybrid') and query and syn then
    local indent = M.treesitter_indent_for_pos(
      query, syn, tab_width, indent_width, text, line_before, line_before_end_pos, true)
    if indent then
      if heuristic == 'hybrid' then
        local attempts = 0
        for line_idx = line_before, 0, -1 do
          local fnw = first_non_whitespace(text, line_idx)
          if fnw then
            local computed = M.treesitter_indent_for_pos(
              query, syn, tab_width, indent_width, text, line_idx, text:line_start(line_idx) + fnw, false)
            if computed then
              local leading = text:line(line_idx):sub(1, fnw)
              local s = indent:relative_indent(computed, leading, indent_style, tab_width)
              if s then return s end
            end
            attempts = attempts + 1
            if attempts == MAX_ATTEMPTS then break end
          end
        end
      end
      return indent:to_string(indent_style, tab_width)
    end
  end
  local level = M.indent_level_for_line(text:line(current_line), tab_width, indent_width)
  return indent_style:as_str():rep(level)
end

function M.get_scopes(buf, text, pos)
  local scopes = {}
  local syn = buf and M.syntax_for(buf) or nil
  if syn then
    text = text or Text.get(syn.buf)
    local r, c = rc(text, pos)
    local node = syn.tree:root():descendant_for_range(r, c, r, c)
    while node do
      scopes[#scopes + 1] = node:type()
      node = node:parent()
    end
  end
  local out = {}
  for i = #scopes, 1, -1 do
    out[#out + 1] = scopes[i]
  end
  return out
end

return M
