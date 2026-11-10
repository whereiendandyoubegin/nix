local U = require('hx.util')
local M = {}

local SCORE_MATCH = 16
local PENALTY_GAP_START = 3
local PENALTY_GAP_EXTENSION = 1
local PREFIX_BONUS_SCALE = 2
local BONUS_BOUNDARY = SCORE_MATCH / 2
local MAX_PREFIX_BONUS = BONUS_BOUNDARY
local BONUS_NON_WORD = BONUS_BOUNDARY
local BONUS_CAMEL123 = BONUS_BOUNDARY - PENALTY_GAP_START
local BONUS_CONSECUTIVE = PENALTY_GAP_START + PENALTY_GAP_EXTENSION
local BONUS_FIRST_CHAR_MULTIPLIER = 2
local MAX_MATRIX_SIZE = 100 * 1024

local WS, NONWORD, DELIM, LOWER, UPPER, LETTER, NUMBER = 0, 1, 2, 3, 4, 5, 6

local DEFAULT_DELIMS = { [47] = true, [44] = true, [58] = true, [59] = true, [124] = true }
local PATH_DELIMS = { [47] = true, [58] = true }

local function make_config(opts)
  local path = opts.path
  return {
    delims = path and PATH_DELIMS or DEFAULT_DELIMS,
    bonus_boundary_white = path and BONUS_BOUNDARY or (BONUS_BOUNDARY + 2),
    bonus_boundary_delimiter = BONUS_BOUNDARY + 1,
    initial = path and DELIM or WS,
    ignore_case = not opts.case_sensitive,
    prefer_prefix = opts.prefer_prefix or false,
  }
end

local function ascii_ws(c)
  return c == 32 or c == 9 or c == 10 or c == 12 or c == 13
end

local function char_class(c, cfg)
  if c < 128 then
    if c >= 97 and c <= 122 then return LOWER end
    if c >= 65 and c <= 90 then return UPPER end
    if c >= 48 and c <= 57 then return NUMBER end
    if ascii_ws(c) then return WS end
    if cfg.delims[c] then return DELIM end
    return NONWORD
  end
  if U.is_lower(c) then return LOWER end
  if U.is_upper(c) then return UPPER end
  local cat = U.category(c)
  if cat == U.WORD then
    if U.is_numeric and U.is_numeric(c) then return NUMBER end
    return LETTER
  end
  if U.rust_whitespace(c) then return WS end
  return NONWORD
end

local NORM = require('hx.fuzzy_normalize')

local function normalize(c, cfg)
  if c < 128 then
    if cfg.ignore_case and c >= 65 and c <= 90 then return c + 32 end
    return c
  end
  if cfg.normalize then c = NORM[c] or c end
  if cfg.ignore_case then return U.lower(c) end
  return c
end

local function class_and_norm(c, cfg)
  local cls = char_class(c, cfg)
  if cfg.ignore_case then
    if c < 128 then
      if cls == UPPER then c = c + 32 end
      return c, cls
    end
  end
  if c >= 128 then c = normalize(c, cfg) end
  return c, cls
end

local function bonus_for(cfg, prev, cls)
  if cls > DELIM then
    if prev == WS then return cfg.bonus_boundary_white end
    if prev == DELIM then return cfg.bonus_boundary_delimiter end
    if prev == NONWORD then return BONUS_BOUNDARY end
  end
  if (prev == LOWER and cls == UPPER) or (prev ~= NUMBER and cls == NUMBER) then
    return BONUS_CAMEL123
  elseif cls == WS then
    return cfg.bonus_boundary_white
  elseif cls == NONWORD then
    return BONUS_NON_WORD
  end
  return 0
end

local function sat(a)
  return a < 0 and 0 or a
end

local function decode_all(s)
  local cps = {}
  local ascii = true
  local n = 0
  for _, cp in U.chars(s) do
    cps[n] = cp
    n = n + 1
    if cp >= 128 then ascii = false end
  end
  return cps, n, ascii
end

local function calculate_score(cfg, h, nd, m, start, stop, idx)
  local prev_class = start > 0 and char_class(h[start - 1], cfg) or cfg.initial
  local ni = 0
  local needle_char = nd[0]
  local in_gap = false
  local consecutive = 1
  if idx then idx[#idx + 1] = start end
  local class = char_class(h[start], cfg)
  local first_bonus = bonus_for(cfg, prev_class, class)
  local score = SCORE_MATCH + first_bonus * BONUS_FIRST_CHAR_MULTIPLIER
  prev_class = class
  if ni + 1 < m then
    ni = ni + 1
    needle_char = nd[ni]
  end
  for i = start + 1, stop - 1 do
    local c, cls = class_and_norm(h[i], cfg)
    if c == needle_char then
      if idx then idx[#idx + 1] = i end
      local bonus = bonus_for(cfg, prev_class, cls)
      if consecutive ~= 0 then
        if bonus >= BONUS_BOUNDARY and bonus > first_bonus then first_bonus = bonus end
        bonus = math.max(bonus, first_bonus, BONUS_CONSECUTIVE)
      else
        first_bonus = bonus
      end
      score = score + SCORE_MATCH + bonus
      in_gap = false
      consecutive = consecutive + 1
      if ni + 1 < m then
        ni = ni + 1
        needle_char = nd[ni]
      end
    else
      score = sat(score - (in_gap and PENALTY_GAP_EXTENSION or PENALTY_GAP_START))
      in_gap = true
      consecutive = 0
    end
    prev_class = cls
  end
  if cfg.prefer_prefix then
    if start ~= 0 then
      local penalty = PENALTY_GAP_START + PENALTY_GAP_START * (start - 1)
      score = score + sat(MAX_PREFIX_BONUS - math.floor(penalty / PREFIX_BONUS_SCALE))
    else
      score = score + MAX_PREFIX_BONUS
    end
  end
  return score
end

local function greedy(cfg, h, n, ascii, nd, m, start, stop, idx)
  if not ascii then
    local first_char_end = stop
    local found = false
    local j = 1
    if m >= 2 then
      for i = first_char_end, n - 1 do
        if normalize(h[i], cfg) == nd[j] then
          if j == m - 1 then
            stop = i + 1
            found = true
            break
          end
          j = j + 1
        end
      end
      if not found then return nil end
    end
  end
  local j = m - 1
  for i = stop - 1, start, -1 do
    if normalize(h[i], cfg) == nd[j] then
      if j == 0 then
        start = i
        break
      end
      j = j - 1
    end
  end
  return calculate_score(cfg, h, nd, m, start, stop, idx)
end

local UNMATCHED = { score = 0, matched = true, cb = 0, unmatched = true }

local function next_m_cell(p_score, bonus, m)
  if m.unmatched then
    return { score = p_score + bonus + SCORE_MATCH, matched = false, cb = bonus }
  end
  local cb = math.max(m.cb, BONUS_CONSECUTIVE)
  if bonus >= BONUS_BOUNDARY and bonus > cb then cb = bonus end
  local score_match = m.score + math.max(cb, bonus)
  local score_skip = p_score + bonus
  if score_match > score_skip then
    return { score = score_match + SCORE_MATCH, matched = true, cb = cb }
  end
  return { score = score_skip + SCORE_MATCH, matched = false, cb = bonus }
end

local function optimal(cfg, h, n, ascii, nd, m, start, greedy_end, stop, idx)
  local L = stop - start
  local csize = ascii and 1 or 4
  local layout = csize * L + L + 2 * m + 4 * (L + 1 - m) + L * m
  local max_layout = 4 * 2048 + 2048 + 2 * 2048 + 4 * 2048 + MAX_MATRIX_SIZE
  if L * m > MAX_MATRIX_SIZE or L > 65535 or m > 2048 or layout > max_layout then
    return greedy(cfg, h, n, ascii, nd, m, start, greedy_end, idx)
  end
  local prev_class = start > 0 and char_class(h[start - 1], cfg) or cfg.initial
  local hs, bonus, row_offs = {}, {}, { [0] = 0 }
  local cur = 0
  local matched = false
  for i = 0, L - 1 do
    local c, cls = class_and_norm(h[start + i], cfg)
    hs[i] = c
    bonus[i] = bonus_for(cfg, prev_class, cls)
    prev_class = cls
    if c == nd[cur] then
      if cur < m - 1 then
        row_offs[cur] = i
        cur = cur + 1
      elseif not matched then
        row_offs[cur] = i
        matched = true
      end
    end
  end
  if not matched then return nil end
  local Mx = {}
  local Pm = idx and {} or nil
  local prefix_bonus = 0
  if cfg.prefer_prefix then
    if start == 0 then
      prefix_bonus = MAX_PREFIX_BONUS * PREFIX_BONUS_SCALE
    else
      prefix_bonus = sat(MAX_PREFIX_BONUS * PREFIX_BONUS_SCALE - PENALTY_GAP_START - (start - 1) * PENALTY_GAP_EXTENSION)
    end
  end
  for r = 0, m - 2 do
    local first = r == 0
    local row_off = row_offs[r]
    local next_row_off = row_offs[r + 1] - 1
    local prev_p, prev_m = 0, 0
    local cells = Mx[r]
    local nxt = {}
    Mx[r + 1] = nxt
    local pm = Pm and {} or nil
    if Pm then Pm[r] = pm end
    local nc, nnc = nd[r], nd[r + 1]
    if first then
      cells = {}
      Mx[0] = cells
    end
    for j = row_off, L - 2 do
      local a = sat(prev_m - PENALTY_GAP_START)
      local b = sat(prev_p - PENALTY_GAP_EXTENSION)
      local p, p_matched
      if a > b then p, p_matched = a, true else p, p_matched = b, false end
      local mc
      if first then
        if hs[j] == nc then
          mc = { score = bonus[j] * BONUS_FIRST_CHAR_MULTIPLIER + SCORE_MATCH + math.floor(prefix_bonus / PREFIX_BONUS_SCALE),
            matched = false, cb = bonus[j] }
        else
          mc = UNMATCHED
        end
        prefix_bonus = sat(prefix_bonus - PENALTY_GAP_EXTENSION)
        cells[j] = mc
      else
        mc = cells[j] or UNMATCHED
      end
      if j >= next_row_off then
        if hs[j + 1] == nnc then
          nxt[j + 1] = next_m_cell(p, bonus[j + 1], mc)
        else
          nxt[j + 1] = UNMATCHED
        end
      end
      if pm then pm[j] = p_matched end
      prev_p = p
      prev_m = mc.score
    end
  end
  local last = Mx[m - 1]
  local best, bj = -1, nil
  for j = row_offs[m - 1], L - 1 do
    local c = last[j]
    if c and not c.unmatched and c.score >= best then
      best = c.score
      bj = j
    end
  end
  if not bj then return nil end
  if idx then
    local out = {}
    local r, j = m - 1, bj
    out[r] = j
    while r > 0 do
      local c = Mx[r][j]
      if c.matched then
        j = j - 1
      else
        local k = j - 1
        while k > 0 and not Pm[r - 1][k] do
          k = k - 1
        end
        j = k - 1
      end
      r = r - 1
      out[r] = j
    end
    for rr = 0, m - 1 do
      idx[#idx + 1] = start + out[rr]
    end
  end
  return best
end

function M.score(hay, needle_cps, opts)
  opts = opts or {}
  local cfg = make_config(opts)
  local h, n, ascii = decode_all(hay)
  local nd = {}
  local m = #needle_cps
  local nascii = true
  cfg.normalize = true
  for i = 1, m do
    local c = needle_cps[i]
    if c >= 128 then nascii = false end
    if NORM[c] then cfg.normalize = false end
  end
  for i = 1, m do
    nd[i - 1] = normalize(needle_cps[i], cfg)
  end
  local idx = opts.indices and {} or nil
  local function ret(s)
    if s == nil then return nil end
    if idx then
      local out = {}
      for i, v in ipairs(idx) do
        out[i] = v + 1
      end
      return s, out
    end
    return s
  end
  if m > n then return nil end
  if m == 0 then return 0, {} end
  if ascii and not nascii then return nil end
  if m == n then
    for i = 0, n - 1 do
      if normalize(h[i], cfg) ~= nd[i] then return nil end
    end
    return ret(calculate_score(cfg, h, nd, m, 0, n, idx))
  end
  if ascii then
    if m == 1 then
      local c = nd[0]
      local max_score, max_pos = 0, 0
      for i = 0, n - 1 do
        if normalize(h[i], cfg) == c then
          local pc = i > 0 and char_class(h[i - 1], cfg) or cfg.initial
          local b = bonus_for(cfg, pc, char_class(h[i], cfg))
          local s = b * BONUS_FIRST_CHAR_MULTIPLIER + SCORE_MATCH
          if s > max_score then
            max_pos, max_score = i, s
            if b >= cfg.bonus_boundary_white then break end
          end
        end
      end
      if max_score == 0 then return nil end
      if idx then idx[1] = max_pos end
      return ret(max_score)
    end
    local start
    for i = 0, n - m do
      if normalize(h[i], cfg) == nd[0] then
        start = i
        break
      end
    end
    if not start then return nil end
    local pos = start + 1
    for j = 1, m - 1 do
      local found
      for i = pos, n - 1 do
        if normalize(h[i], cfg) == nd[j] then
          found = i
          break
        end
      end
      if not found then return nil end
      pos = found + 1
    end
    local greedy_end = pos
    local stop = greedy_end
    for i = n - 1, greedy_end, -1 do
      if normalize(h[i], cfg) == nd[m - 1] then
        stop = i + 1
        break
      end
    end
    if m == stop - start then
      return ret(calculate_score(cfg, h, nd, m, start, greedy_end, idx))
    end
    return ret(optimal(cfg, h, n, ascii, nd, m, start, greedy_end, stop, idx))
  end
  local start
  for i = 0, n - m do
    if normalize(h[i], cfg) == nd[0] then
      start = i
      break
    end
  end
  if not start then return nil end
  if m == 1 then
    local c = nd[0]
    local max_score, max_pos = 0, 0
    local prev_class = start > 0 and char_class(h[start - 1], cfg) or cfg.initial
    for i = start, n - 1 do
      local cc, cls = class_and_norm(h[i], cfg)
      if cc == c then
        local b = bonus_for(cfg, prev_class, cls)
        prev_class = cls
        local s = b * BONUS_FIRST_CHAR_MULTIPLIER + SCORE_MATCH
        if s > max_score then
          max_pos, max_score = i, s
          if b >= cfg.bonus_boundary_white then break end
        end
      end
    end
    if idx then idx[1] = max_pos end
    return ret(max_score)
  end
  local stop
  for i = n - 1, start + 1, -1 do
    if normalize(h[i], cfg) == nd[m - 1] then
      stop = i + 1
      break
    end
  end
  if not stop or stop - start < m then return nil end
  if m == stop - start then
    for i = 0, m - 1 do
      if normalize(h[start + i], cfg) ~= nd[i] then return nil end
    end
    return ret(calculate_score(cfg, h, nd, m, start, stop, idx))
  end
  return ret(optimal(cfg, h, n, ascii, nd, m, start, start + 1, stop, idx))
end

local function has_upper(cps)
  for _, cp in ipairs(cps) do
    if U.is_upper(cp) then return true end
  end
  return false
end

local function decode_list(s)
  local cps = {}
  for _, cp in U.chars(s) do
    cps[#cps + 1] = cp
  end
  return cps
end

function M.filter(pattern, items, path)
  local needle = decode_list(pattern)
  local cs = has_upper(needle)
  if not cs then
    for i, cp in ipairs(needle) do
      needle[i] = U.lower(cp)
    end
  end
  local res = {}
  for idx, it in ipairs(items) do
    local s = M.score(it, needle, { case_sensitive = cs, path = path })
    if s then res[#res + 1] = { it, s, idx } end
  end
  table.sort(res, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[3] < b[3]
  end)
  local out = {}
  for i, r in ipairs(res) do
    out[i] = r[1]
  end
  return out, res
end

function M.parse_pattern(s)
  local atoms = {}
  local cur = {}
  local i = 1
  local function push()
    local a = table.concat(cur)
    cur = {}
    if a == '' then return end
    local atom = { kind = 'fuzzy', negative = false }
    if a:sub(1, 1) == '!' then
      atom.negative = true
      a = a:sub(2)
      atom.kind = 'substring'
    end
    if a:sub(1, 1) == "'" then
      atom.kind = 'substring'
      a = a:sub(2)
    elseif a:sub(1, 1) == '^' then
      atom.kind = 'prefix'
      a = a:sub(2)
    end
    if a:sub(-1) == '$' and a:sub(-2, -2) ~= '\\' then
      atom.kind = atom.kind == 'prefix' and 'exact' or 'postfix'
      a = a:sub(1, -2)
    end
    a = a:gsub('\\(.)', '%1')
    if a == '' then return end
    atom.text = a
    atom.cps = decode_list(a)
    atom.case_sensitive = has_upper(atom.cps)
    if not atom.case_sensitive then
      for k, cp in ipairs(atom.cps) do
        atom.cps[k] = U.lower(cp)
      end
    end
    atoms[#atoms + 1] = atom
  end
  while i <= #s do
    local c = s:sub(i, i)
    if c == '\\' and i < #s then
      cur[#cur + 1] = s:sub(i, i + 1)
      i = i + 2
    elseif c == ' ' then
      push()
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  push()
  return atoms
end

local function plain_find(hay, atom)
  local h = atom.case_sensitive and hay or hay:lower()
  local t = atom.case_sensitive and atom.text or atom.text:lower()
  if atom.kind == 'substring' then return h:find(t, 1, true) end
  if atom.kind == 'prefix' then return h:sub(1, #t) == t and 1 or nil end
  if atom.kind == 'postfix' then return (#t == 0 or h:sub(-#t) == t) and (#h - #t + 1) or nil end
  if atom.kind == 'exact' then return h == t and 1 or nil end
end

function M.match_atoms(hay, atoms, path, want_indices)
  local total = 0
  local idx = want_indices and {} or nil
  for _, a in ipairs(atoms) do
    if a.kind == 'fuzzy' then
      local s, ind = M.score(hay, a.cps, { case_sensitive = a.case_sensitive, path = path, indices = want_indices })
      if not s then return nil end
      total = total + s
      if idx and ind then
        for _, k in ipairs(ind) do
          idx[#idx + 1] = k
        end
      end
    else
      local f = plain_find(hay, a)
      if a.negative then
        if f then return nil end
      else
        if not f then return nil end
        total = total + #a.cps * SCORE_MATCH
        if idx then
          local start = U.char_count(hay:sub(1, f - 1)) + 1
          for k = 0, #a.cps - 1 do
            idx[#idx + 1] = start + k
          end
        end
      end
    end
  end
  return total, idx
end

return M
