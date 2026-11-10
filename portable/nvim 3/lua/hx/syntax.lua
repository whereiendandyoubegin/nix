local api = vim.api
local ts = vim.treesitter
local M = {}

local query_cache = {}

local function setup_predicates()
  local RE = require('hx.regex')
  local re_cache = {}
  local function get_re(p)
    local r = re_cache[p]
    if r == nil then
      r = RE.new(p) or false
      re_cache[p] = r
    end
    return r
  end
  local function node_text(node, src)
    return ts.get_node_text(node, src)
  end
  local function handler(match, _, src, pred)
    local nodes = match[pred[2]]
    if not nodes then return true end
    if type(nodes) ~= 'table' then nodes = { nodes } end
    local re = get_re(pred[3])
    if not re then return false end
    for _, node in ipairs(nodes) do
      local t = node_text(node, src)
      if not re:find(t, 0, #t) then return false end
    end
    return true
  end
  ts.query.add_predicate('match?', handler, { force = true, all = true })
  ts.query.add_predicate('not-match?', function(...)
    return not handler(...)
  end, { force = true, all = true })
  ts.query.add_predicate('is-not?', function()
    return true
  end, { force = true, all = true })
  ts.query.add_predicate('is?', function()
    return true
  end, { force = true, all = true })
end

local function split_patterns(src)
  local pats = {}
  local i, n = 1, #src
  local depth = 0
  local start = nil
  while i <= n do
    local c = src:sub(i, i)
    if c == ';' then
      local e = src:find('\n', i, true) or n
      i = e + 1
    elseif c == '"' then
      local j = i + 1
      while j <= n do
        local cj = src:sub(j, j)
        if cj == '\\' then
          j = j + 2
        elseif cj == '"' then
          break
        else
          j = j + 1
        end
      end
      if depth == 0 and not start then start = i end
      i = j + 1
      if depth == 0 then
        local cap_e = select(2, src:find('^%s*@[%w_.%-]+', i))
        if cap_e then i = cap_e + 1 end
        pats[#pats + 1] = { start, i - 1 }
        start = nil
      end
    elseif c == '(' or c == '[' then
      if depth == 0 then start = i end
      depth = depth + 1
      i = i + 1
    elseif c == ')' or c == ']' then
      depth = depth - 1
      i = i + 1
      if depth == 0 then
        while true do
          local s, e = src:find('^%s*[%*%+%?]', i)
          if s then
            i = e + 1
          else
            local s2, e2 = src:find('^%s*@[%w_.%-]+', i)
            if s2 then
              i = e2 + 1
            else
              break
            end
          end
        end
        pats[#pats + 1] = { start, i - 1 }
        start = nil
      end
    elseif c == '_' and depth == 0 then
      i = i + 1
    else
      i = i + 1
    end
  end
  return pats
end

local function rewrite_priorities(src, base)
  local pats = split_patterns(src)
  local out = {}
  local last = 1
  local total = #pats
  for idx, p in ipairs(pats) do
    out[#out + 1] = src:sub(last, p[1] - 1)
    local body = src:sub(p[1], p[2])
    local prio = base + (total - idx)
    out[#out + 1] = '(' .. body .. ' (#set! priority ' .. prio .. '))'
    last = p[2] + 1
  end
  out[#out + 1] = src:sub(last)
  return table.concat(out)
end
M._rewrite = rewrite_priorities

local function read_query_file(lang, name)
  local files = api.nvim_get_runtime_file(('queries/%s/%s.scm'):format(lang, name), true)
  local cfg = vim.fn.stdpath('config')
  local chosen
  for _, f in ipairs(files) do
    if f:find(M.cfg_root or cfg, 1, true) == 1 then
      chosen = f
      break
    end
  end
  chosen = chosen or files[1]
  if not chosen then return nil end
  local fh = io.open(chosen, 'r')
  if not fh then return nil end
  local s = fh:read('*a')
  fh:close()
  local inh = s:match('^;+%s*inherits%s*:?%s*([%w_,]+)')
  if inh then
    local parts = {}
    for l in inh:gmatch('[^,]+') do
      parts[#parts + 1] = read_query_file(l, name) or ''
    end
    s = table.concat(parts, '\n') .. '\n' .. s
  end
  return s
end

function M.get_query(lang, name)
  local key = lang .. '/' .. name
  local q = query_cache[key]
  if q ~= nil then return q or nil end
  local src = read_query_file(lang, name)
  if not src or not pcall(ts.language.add, lang) or not ts.language.inspect then
    query_cache[key] = false
    return nil
  end
  if not pcall(ts.language.inspect, lang) then
    query_cache[key] = false
    return nil
  end
  local ok, parsed = pcall(ts.query.parse, lang, src)
  if not ok then
    vim.schedule(function()
      vim.notify(('hx: failed to parse %s query: %s'):format(key, parsed), vim.log.levels.WARN)
    end)
    query_cache[key] = false
    return nil
  end
  query_cache[key] = parsed
  return parsed
end

local function lang_of(buf)
  local ft = vim.bo[buf].filetype
  if ft == '' then return nil end
  return ts.language.get_lang(ft) or ft
end
M.lang_of = lang_of

function M.parser(buf)
  local lang = lang_of(buf)
  if not lang then return nil end
  local ok, p = pcall(ts.get_parser, buf, lang, { error = false })
  if not ok or not p then return nil end
  return p, lang
end

function M.has_tree(buf)
  local p = M.parser(buf)
  return p ~= nil
end

function M.tree(buf)
  local p, lang = M.parser(buf)
  if not p then return nil end
  local trees = p:parse(true)
  if not trees or not trees[1] then return nil end
  return trees[1], lang, p
end

function M.root(buf)
  local t, lang = M.tree(buf)
  if not t then return nil end
  return t:root(), lang
end

M.highlighted = {}
function M.attach(buf)
  local lang = lang_of(buf)
  if not lang then return end
  local ok = pcall(ts.language.add, lang)
  if not ok then return end
  if not M.get_query(lang, 'highlights') then return end
  local p = M.parser(buf)
  if not p then return end
  M.highlighted[buf] = true
  pcall(ts.stop, buf)
  p:register_cbs({
    on_changedtree = function()
      M.dirty = true
    end,
  }, true)
  p:parse(true)
end

local hns = vim.api.nvim_create_namespace('hx_syntax')
local hframe = {}

local function node_depth(node, cache)
  local id = node:id()
  local d = cache[id]
  if d then return d end
  d = 0
  local p = node:parent()
  while p do
    d = d + 1
    p = p:parent()
  end
  cache[id] = d
  return d
end

function M.capture_spans(root, source, query, top, bot)
  local by_node = {}
  local order = {}
  for id, node, _, match in query:iter_captures(root, source, top, bot + 1) do
    local name = query.captures[id]
    if name:sub(1, 1) ~= '_' then
      local pat = match and match:info() or 0
      local nid = node:id()
      local cur = by_node[nid]
      if not cur then
        by_node[nid] = { node = node, name = name, pat = pat }
        order[#order + 1] = nid
      elseif pat < cur.pat then
        cur.name, cur.pat = name, pat
      end
    end
  end
  local out = {}
  local cache = {}
  for _, nid in ipairs(order) do
    local e = by_node[nid]
    local sr, sc, er, ec = e.node:range()
    out[#out + 1] = { sr, sc, er, ec, e.name, node_depth(e.node, cache) }
  end
  return out
end

function M.setup_highlighter()
  local T = require('hx.theme')
  vim.api.nvim_set_decoration_provider(hns, {
    on_win = function(_, win, buf, top, bot)
      hframe[win] = nil
      if not M.highlighted[buf] then return false end
      local p, lang = M.parser(buf)
      if not p then return false end
      local q = M.get_query(lang, 'highlights')
      if not q then return false end
      local ok, trees = pcall(function()
        return p:parse({ top, bot + 1 })
      end)
      if not ok or not trees or not trees[1] then return false end
      local root = trees[1]:root()
      local ok2, spans = pcall(M.capture_spans, root, buf, q, top, bot)
      if not ok2 then return false end
      local rows = {}
      for _, sp in ipairs(spans) do
        local sr, sc, er, ec = sp[1], sp[2], sp[3], sp[4]
        local g = T.group_for(T.get(sp[5]))
        for r = math.max(sr, top), math.min(er, bot) do
          local s = r == sr and sc or 0
          local e = r == er and ec or -1
          rows[r] = rows[r] or {}
          table.insert(rows[r], { s, e, g, 100 + math.min(sp[6], 3000) })
        end
      end
      hframe[win] = rows
      return true
    end,
    on_line = function(_, win, buf, row)
      local f = hframe[win]
      if not f then return end
      local list = f[row]
      if not list then return end
      local len
      for _, sp in ipairs(list) do
        local e = sp[2]
        if e == -1 then
          len = len or #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or '')
          e = len
        end
        if e > sp[1] then
          pcall(vim.api.nvim_buf_set_extmark, buf, hns, row, sp[1], {
            end_row = row,
            end_col = e,
            hl_group = sp[3],
            ephemeral = true,
            priority = sp[4],
          })
        end
      end
    end,
  })
end

local function srange(node)
  local _, _, sb, _, _, eb = node:range(true)
  return sb, eb
end
M.byte_range = srange

function M.named_descendant_for_byte_range(buf, from, to)
  local root = M.root(buf)
  if not root then return nil end
  local function pos(b)
    local t = require('hx.text').get(buf)
    local row = t:line_of(b)
    return row, b - t:line_start(row)
  end
  local sr, sc = pos(from)
  local er, ec = pos(to)
  return root:named_descendant_for_range(sr, sc, er, ec)
end

function M.reset_to_byte_range(root, start, stop)
  local node = root
  while true do
    local s, e = srange(node)
    if start < s or stop > e then
      node = node:parent() or node
      break
    end
    local found
    for child in node:iter_children() do
      local _, ce = srange(child)
      if ce > start then
        found = child
        break
      end
    end
    if not found then break end
    node = found
  end
  return node
end

function M.capture_nodes_any(buf, query_name, names)
  local root, lang = M.root(buf)
  if not root then return nil end
  local q = M.get_query(lang, query_name)
  if not q then return nil end
  local want = {}
  for _, n in ipairs(names) do
    want[n] = true
  end
  local out = {}
  for _, match in q:iter_matches(root, buf, 0, -1, { all = true }) do
    for id, nodes in pairs(match) do
      local name = q.captures[id]
      if want[name] then
        local s, e
        for _, nd in ipairs(nodes) do
          local ns, ne = srange(nd)
          if not s or ns < s then s = ns end
          if not e or ne > e then e = ne end
        end
        if s then out[#out + 1] = { s = s, e = e, name = name } end
      end
    end
  end
  return out
end

function M.capture_nodes(buf, query_name, name)
  return M.capture_nodes_any(buf, query_name, { name })
end

function M.scopes_at(buf, pos)
  local t = require('hx.text').get(buf)
  local row = t:line_of(pos)
  local col = pos - t:line_start(row)
  local caps = ts.get_captures_at_pos(buf, row, col)
  local out = {}
  for _, c in ipairs(caps) do
    out[#out + 1] = c.capture
  end
  return out
end

function M.setup(root)
  M.cfg_root = root
  setup_predicates()
  M.setup_highlighter()
end

return M
