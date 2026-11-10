local T = require('hx.theme')
local U = require('hx.util')

local M = {}

local LANG_ALIASES = { py = 'python', python3 = 'python', py3 = 'python' }

function M.highlight_code(text, lang, base_style)
  lang = LANG_ALIASES[lang] or lang
  if not lang or lang == '' then return nil end
  local ok = pcall(vim.treesitter.language.add, lang)
  if not ok then return nil end
  local Syn = require('hx.syntax')
  local query = Syn.get_query(lang, 'highlights')
  if not query then return nil end
  local okp, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not okp or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local root = tree:root()
  local n = #text
  local cap_at, depth_at = {}, {}
  local spans_ = Syn.capture_spans(root, text, query, 0, select(2, text:gsub('\n', '')) + 1)
  local row_start = { [0] = 0 }
  local r = 0
  for pos in text:gmatch('()\n') do
    r = r + 1
    row_start[r] = pos
  end
  for _, sp in ipairs(spans_) do
    local sb = (row_start[sp[1]] or n) + sp[2]
    local eb = (row_start[sp[3]] or n) + sp[4]
    for b = sb + 1, math.min(eb, n) do
      if not depth_at[b] or sp[6] >= depth_at[b] then
        depth_at[b] = sp[6]
        cap_at[b] = sp[5]
      end
    end
  end
  local lines = {}
  local spans = {}
  local i = 1
  while i <= n do
    local c = text:sub(i, i)
    if c == '\n' then
      lines[#lines + 1] = spans
      spans = {}
      i = i + 1
    else
      local j = i
      local cap = cap_at[i]
      while j + 1 <= n and text:sub(j + 1, j + 1) ~= '\n' and cap_at[j + 1] == cap do
        j = j + 1
      end
      local chunk = text:sub(i, j):gsub('\t', '    ')
      local style = base_style
      if cap then style = T.patch(base_style, T.get(cap)) end
      spans[#spans + 1] = { chunk, style }
      i = j + 1
    end
  end
  if #spans > 0 then lines[#lines + 1] = spans end
  return lines
end

local function styled_multiline(text, style)
  local out = {}
  for l in (text .. '\n'):gmatch('(.-)\n') do
    out[#out + 1] = { { l, style } }
  end
  if text:sub(-1) == '\n' then out[#out] = nil end
  return out
end

local function code_block(text, lang, themed)
  local text_style = themed and T.get('ui.text') or {}
  local code_style = themed and T.get('markup.raw.inline') or {}
  if not themed then return styled_multiline(text, code_style) end
  local hl = M.highlight_code(text, lang, text_style)
  if not hl then return styled_multiline(text, code_style) end
  return hl
end

local function inline(text, base, themed)
  local spans = {}
  local text_style = base
  local code_style = themed and T.get('markup.raw.inline') or {}
  local i = 1
  local n = #text
  local buf = {}
  local style_stack = { text_style }
  local function cur()
    return style_stack[#style_stack]
  end
  local function flush()
    if #buf > 0 then
      spans[#spans + 1] = { table.concat(buf), cur() }
      buf = {}
    end
  end
  local open = {}
  while i <= n do
    local c = text:sub(i, i)
    if c == '\\' and i < n and text:sub(i + 1, i + 1):match('%p') then
      buf[#buf + 1] = text:sub(i + 1, i + 1)
      i = i + 2
    elseif c == '`' then
      local ticks = text:match('^`+', i)
      local close = text:find(ticks, i + #ticks, true)
      if close then
        flush()
        local code = text:sub(i + #ticks, close - 1)
        if code:match('^ .* $') and #code > 2 then code = code:sub(2, -2) end
        spans[#spans + 1] = { code, code_style }
        i = close + #ticks
      else
        buf[#buf + 1] = ticks
        i = i + #ticks
      end
    elseif c == '*' or c == '_' then
      local run = text:match('^' .. (c == '*' and '%*+' or '_+'), i)
      local kind = #run >= 2 and 'strong' or 'em'
      local key = c .. kind
      local prev = i > 1 and text:sub(i - 1, i - 1) or ' '
      local nxt = text:sub(i + #run, i + #run)
      local can_open = nxt ~= '' and not nxt:match('%s')
      local can_close = not prev:match('%s')
      if c == '_' and prev:match('%w') and nxt:match('%w') then
        buf[#buf + 1] = run
        i = i + #run
      elseif open[key] and can_close then
        flush()
        table.remove(style_stack)
        open[key] = nil
        i = i + (kind == 'strong' and 2 or 1)
      elseif can_open and text:find(c == '*' and (kind == 'strong' and '%*%*' or '%*') or (kind == 'strong' and '__' or '_'), i + #run) then
        flush()
        local st = vim.deepcopy(text_style)
        st.mods = st.mods or {}
        if kind == 'strong' then st.mods.bold = true else st.mods.italic = true end
        style_stack[#style_stack + 1] = st
        open[key] = true
        i = i + (kind == 'strong' and 2 or 1)
      else
        buf[#buf + 1] = run
        i = i + #run
      end
    elseif c == '~' and text:sub(i, i + 1) == '~~' then
      flush()
      if open.strike then
        table.remove(style_stack)
        open.strike = nil
      else
        local st = vim.deepcopy(text_style)
        st.mods = st.mods or {}
        st.mods.crossed_out = true
        style_stack[#style_stack + 1] = st
        open.strike = true
      end
      i = i + 2
    elseif c == '[' then
      local label, rest = text:match('^%[([^%]]*)%]%(([^)]*)%)', i)
      if label then
        buf[#buf + 1] = label
        i = i + #label + #rest + 4
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    elseif c == '<' then
      local tag = text:match('^</?[%a][^>]*>', i)
      if tag then
        flush()
        if tag:match('^<code') then
          local close = text:find('</code>', i + #tag, true)
          if close then
            spans[#spans + 1] = { text:sub(i + #tag, close - 1), code_style }
            i = close + 7
          else
            i = i + #tag
          end
        else
          spans[#spans + 1] = { tag, code_style }
          i = i + #tag
        end
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    elseif c == '&' then
      local ent = text:match('^&%a+;', i)
      local map = { ['&lt;'] = '<', ['&gt;'] = '>', ['&amp;'] = '&', ['&quot;'] = '"', ['&nbsp;'] = '\u{a0}' }
      if ent and map[ent] then
        buf[#buf + 1] = map[ent]
        i = i + #ent
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return spans
end

function M.parse(contents, themed)
  local text_style = themed and T.get('ui.text') or {}
  local heading = {}
  for k = 1, 6 do
    heading[k] = themed and T.get('markup.heading.' .. k) or {}
  end
  local rule_style = themed and T.get('punctuation.special') or {}
  local num_style = themed and T.get('markup.list.numbered') or {}
  local bullet_style = themed and T.get('markup.list.unnumbered') or {}
  local lines = {}
  local function push(spans)
    if #spans > 0 then lines[#lines + 1] = spans end
  end
  local function blank()
    lines[#lines + 1] = {}
  end
  local src = U.split_lines((contents or ''):gsub('\r\n', '\n'))
  local i = 1
  local list_stack = {}
  local para = {}
  local function flush_para()
    if #para > 0 then
      local indent = #list_stack > 0 and string.rep('  ', #list_stack - 1) or ''
      local first = true
      for _, pl in ipairs(para) do
        local spans = inline(pl, text_style, themed)
        if not first and #list_stack > 0 then table.insert(spans, 1, { indent, nil }) end
        push(spans)
        first = false
      end
      para = {}
      if #list_stack == 0 then blank() end
    end
  end
  local function close_lists()
    if #list_stack > 0 then
      flush_para()
      list_stack = {}
      blank()
    end
  end
  while i <= #src do
    local l = src[i]
    local fence, lang = l:match('^%s*(```+)%s*([^`%s]*)')
    if not fence then fence, lang = l:match('^%s*(~~~+)%s*(%S*)') end
    if fence then
      flush_para()
      local body = {}
      i = i + 1
      while i <= #src and not src[i]:match('^%s*' .. fence:gsub('~', '%%~')) do
        body[#body + 1] = src[i]
        i = i + 1
      end
      i = i + 1
      local code = table.concat(body, '\n') .. (#body > 0 and '\n' or '')
      for _, cl in ipairs(code_block(code, lang, themed)) do
        lines[#lines + 1] = cl
      end
      blank()
    elseif l:match('^%s*$') then
      flush_para()
      local nxt = src[i + 1]
      if #list_stack > 0 and not (nxt and (nxt:match('^%s*[%-%*%+]%s') or nxt:match('^%s*%d+[%.%)]%s'))) then
        close_lists()
      end
      i = i + 1
    elseif l:match('^%s*#+%s') or l:match('^%s*#+$') then
      flush_para()
      close_lists()
      local hashes, title = l:match('^%s*(#+)%s*(.-)%s*#*%s*$')
      local lvl = math.min(#hashes, 6)
      local spans = {}
      for _, sp in ipairs(inline(title, text_style, themed)) do
        spans[#spans + 1] = { sp[1], heading[lvl] }
      end
      push(spans)
      blank()
      i = i + 1
    elseif l:match('^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%-%*_%s]*$') and not l:match('^%s*[%-%*]%s+%S') then
      flush_para()
      close_lists()
      lines[#lines + 1] = { { '───', rule_style } }
      blank()
      i = i + 1
    elseif l:match('^%s*[%-%*%+]%s+') or l:match('^%s*%d+[%.%)]%s+') then
      flush_para()
      local ind = #l:match('^%s*')
      local num = l:match('^%s*(%d+)[%.%)]')
      local item = l:gsub('^%s*[%-%*%+]%s+', ''):gsub('^%s*%d+[%.%)]%s+', '')
      while #list_stack > 0 and ind < list_stack[#list_stack].indent do
        table.remove(list_stack)
      end
      if #list_stack == 0 or ind > list_stack[#list_stack].indent then
        list_stack[#list_stack + 1] = { indent = ind, number = num and tonumber(num) or nil }
      end
      local top = list_stack[#list_stack]
      local bullet, bst
      if top.number then
        bullet, bst = top.number .. '. ', num_style
        top.number = top.number + 1
      else
        bullet, bst = '• ', bullet_style
      end
      local prefix = string.rep('  ', #list_stack - 1) .. bullet
      local spans = { { prefix, bst } }
      for _, sp in ipairs(inline(item, text_style, themed)) do
        spans[#spans + 1] = sp
      end
      push(spans)
      i = i + 1
    elseif l:match('^    ') and #para == 0 and #list_stack == 0 then
      local body = {}
      while i <= #src and (src[i]:match('^    ') or src[i]:match('^%s*$')) do
        body[#body + 1] = src[i]:sub(5)
        i = i + 1
      end
      while #body > 0 and body[#body]:match('^%s*$') do
        table.remove(body)
      end
      for _, cl in ipairs(code_block(table.concat(body, '\n') .. '\n', '', themed)) do
        lines[#lines + 1] = cl
      end
      blank()
    else
      local content = l:gsub('^%s+', '')
      if #list_stack > 0 then
        local spans = { { string.rep('  ', #list_stack - 1), nil } }
        for _, sp in ipairs(inline(content, text_style, themed)) do
          spans[#spans + 1] = sp
        end
        push(spans)
      else
        para[#para + 1] = content:gsub('%s%s+$', ''):gsub('\\$', '')
      end
      i = i + 1
    end
  end
  flush_para()
  if #list_stack > 0 then blank() end
  if #lines > 0 and #lines[#lines] == 0 then table.remove(lines) end
  return lines
end

return M
