local M = {}

local byte, char = string.byte, string.char
local floor = math.floor

function M.seq_len(b)
  if b == nil then return 0 end
  if b < 0x80 then return 1 end
  if b >= 0xF0 then return 4 end
  if b >= 0xE0 then return 3 end
  if b >= 0xC0 then return 2 end
  return 1
end

function M.decode(s, i)
  local b = byte(s, i)
  if not b then return nil, 0 end
  if b < 0x80 then return b, 1 end
  local n = M.seq_len(b)
  if n == 2 then
    local b2 = byte(s, i + 1) or 0x80
    return (b - 0xC0) * 64 + (b2 - 0x80), 2
  elseif n == 3 then
    local b2, b3 = byte(s, i + 1, i + 2)
    b2, b3 = b2 or 0x80, b3 or 0x80
    return ((b - 0xE0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80), 3
  elseif n == 4 then
    local b2, b3, b4 = byte(s, i + 1, i + 3)
    b2, b3, b4 = b2 or 0x80, b3 or 0x80, b4 or 0x80
    return (((b - 0xF0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)) * 64 + (b4 - 0x80), 4
  end
  return b, 1
end

function M.encode(cp)
  if cp < 0x80 then return char(cp) end
  if cp < 0x800 then return char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end

function M.chars(s)
  local i = 1
  return function()
    if i > #s then return nil end
    local cp, n = M.decode(s, i)
    local at = i
    i = i + n
    return at, cp, n
  end
end

function M.char_count(s)
  local n = 0
  for i = 1, #s do
    local b = byte(s, i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

function M.prev_boundary(s, i)
  if i <= 0 then return 0 end
  local j = i - 1
  while j > 0 do
    local b = byte(s, j + 1)
    if b < 0x80 or b >= 0xC0 then break end
    j = j - 1
  end
  return j
end

function M.next_boundary(s, i)
  if i >= #s then return #s end
  return i + M.seq_len(byte(s, i + 1))
end

local function is_line_ending(cp)
  return cp == 10 or cp == 13
end
M.is_line_ending = is_line_ending

local ws_set = {
  [0x09] = true, [0x20] = true, [0xA0] = true, [0x180E] = true, [0x202F] = true,
  [0x205F] = true, [0x3000] = true, [0xFEFF] = true,
}
function M.is_whitespace(cp)
  if ws_set[cp] then return true end
  return cp >= 0x2000 and cp <= 0x200B
end

function M.rust_whitespace(cp)
  return (cp >= 9 and cp <= 13) or cp == 32 or cp == 0x85 or cp == 0xA0 or cp == 0x1680
    or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029 or cp == 0x202F
    or cp == 0x205F or cp == 0x3000
end

local punct_ranges = {
  { 0x21, 0x2F }, { 0x3A, 0x40 }, { 0x5B, 0x5E }, { 0x60, 0x60 }, { 0x7B, 0x7E },
  { 0xA1, 0xA9 }, { 0xAB, 0xAC }, { 0xAE, 0xB1 }, { 0xB4, 0xB4 }, { 0xB6, 0xB8 }, { 0xBB, 0xBB },
  { 0xBF, 0xBF }, { 0xD7, 0xD7 }, { 0xF7, 0xF7 },
  { 0x2C2, 0x2C5 }, { 0x2D2, 0x2DF }, { 0x2E5, 0x2EB }, { 0x2ED, 0x2ED }, { 0x2EF, 0x2FF },
  { 0x37E, 0x37E }, { 0x387, 0x387 }, { 0x55A, 0x55F }, { 0x589, 0x58A },
  { 0x5BE, 0x5BE }, { 0x5C0, 0x5C0 }, { 0x5C3, 0x5C3 }, { 0x5C6, 0x5C6 }, { 0x5F3, 0x5F4 },
  { 0x609, 0x60D }, { 0x61B, 0x61F }, { 0x66A, 0x66D }, { 0x6D4, 0x6D4 },
  { 0x964, 0x965 }, { 0x970, 0x970 }, { 0xE3F, 0xE3F }, { 0xE4F, 0xE4F }, { 0xE5A, 0xE5B },
  { 0x2010, 0x2027 }, { 0x2030, 0x205E }, { 0x207A, 0x207E }, { 0x208A, 0x208E },
  { 0x20A0, 0x20C0 }, { 0x2118, 0x2118 }, { 0x2140, 0x2144 }, { 0x214B, 0x214B },
  { 0x2190, 0x21FF }, { 0x2200, 0x22FF }, { 0x2308, 0x230B }, { 0x2320, 0x2321 },
  { 0x2329, 0x232A }, { 0x237C, 0x237C }, { 0x239B, 0x23B3 }, { 0x23DC, 0x23E1 },
  { 0x25B7, 0x25B7 }, { 0x25C1, 0x25C1 }, { 0x25F8, 0x25FF }, { 0x266F, 0x266F },
  { 0x2768, 0x2775 }, { 0x27C0, 0x27FF }, { 0x2900, 0x2AFF }, { 0x2B30, 0x2B44 },
  { 0x2B47, 0x2B4C }, { 0x2CF9, 0x2CFC }, { 0x2CFE, 0x2CFF }, { 0x2E00, 0x2E5D },
  { 0x3001, 0x3003 }, { 0x3008, 0x3011 }, { 0x3014, 0x301F }, { 0x3030, 0x3030 },
  { 0x303D, 0x303D }, { 0x30A0, 0x30A0 }, { 0x30FB, 0x30FB },
  { 0xFB29, 0xFB29 }, { 0xFD3E, 0xFD3F }, { 0xFE10, 0xFE19 }, { 0xFE30, 0xFE52 },
  { 0xFE54, 0xFE66 }, { 0xFE68, 0xFE6B }, { 0xFF01, 0xFF0F }, { 0xFF1A, 0xFF20 },
  { 0xFF3B, 0xFF40 }, { 0xFF5B, 0xFF65 }, { 0xFFE0, 0xFFE6 }, { 0xFFE8, 0xFFEE },
}

local unknown_ranges = {
  { 0x00, 0x08 }, { 0x0E, 0x1F }, { 0x7F, 0x9F }, { 0xA6, 0xA6 }, { 0xA9, 0xA9 }, { 0xAE, 0xAE },
  { 0xB0, 0xB0 }, { 0x2100, 0x2117 }, { 0x2119, 0x213F }, { 0x2300, 0x2307 }, { 0x230C, 0x231F },
  { 0x2322, 0x2328 }, { 0x232B, 0x237B }, { 0x237D, 0x239A }, { 0x23B4, 0x23DB },
  { 0x23E2, 0x23FF }, { 0x2400, 0x24FF }, { 0x2500, 0x25B6 }, { 0x25B8, 0x25C0 },
  { 0x25C2, 0x25F7 }, { 0x2600, 0x266E }, { 0x2670, 0x2767 }, { 0x2794, 0x27BF },
  { 0x2800, 0x28FF }, { 0x2B00, 0x2B2F }, { 0x2B45, 0x2B46 }, { 0x2B4D, 0x2BFF },
  { 0xE000, 0xF8FF }, { 0x1F000, 0x1FAFF }, { 0xFE00, 0xFE0F }, { 0x200C, 0x200D },
}

local function in_ranges(cp, ranges)
  local lo, hi = 1, #ranges
  while lo <= hi do
    local mid = floor((lo + hi) / 2)
    local r = ranges[mid]
    if cp < r[1] then
      hi = mid - 1
    elseif cp > r[2] then
      lo = mid + 1
    else
      return true
    end
  end
  return false
end

local function in_ranges_linear(cp, ranges)
  for _, r in ipairs(ranges) do
    if cp >= r[1] and cp <= r[2] then return true end
  end
  return false
end

local cat_cache = {}

M.WHITESPACE, M.EOL, M.WORD, M.PUNCT, M.UNKNOWN = 1, 2, 3, 4, 5

function M.category(cp)
  if cp < 128 then
    if cp == 10 or cp == 13 then return 2 end
    if cp == 9 or cp == 32 then return 1 end
    if (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122) or cp == 95 then
      return 3
    end
    if cp >= 33 and cp <= 126 then return 4 end
    if cp == 11 or cp == 12 then return 1 end
    return 5
  end
  local c = cat_cache[cp]
  if c then return c end
  if M.rust_whitespace(cp) then
    c = 1
  elseif in_ranges(cp, punct_ranges) then
    c = 4
  elseif in_ranges_linear(cp, unknown_ranges) then
    c = 5
  elseif (cp >= 0x300 and cp <= 0x36F) then
    c = 5
  else
    c = 3
  end
  cat_cache[cp] = c
  return c
end

function M.is_word(cp)
  return M.category(cp) == 3
end

function M.is_punctuation(cp)
  return M.category(cp) == 4
end

function M.is_ws_any(cp)
  return M.rust_whitespace(cp)
end

local lower_cache, upper_cache = {}, {}
function M.lower(cp)
  if cp < 128 then
    if cp >= 65 and cp <= 90 then return cp + 32 end
    return cp
  end
  local r = lower_cache[cp]
  if r then return r end
  local s = vim.fn.tolower(M.encode(cp))
  r = M.decode(s, 1) or cp
  lower_cache[cp] = r
  return r
end

function M.upper(cp)
  if cp < 128 then
    if cp >= 97 and cp <= 122 then return cp - 32 end
    return cp
  end
  local r = upper_cache[cp]
  if r then return r end
  local s = vim.fn.toupper(M.encode(cp))
  r = M.decode(s, 1) or cp
  upper_cache[cp] = r
  return r
end

function M.is_lower(cp)
  return M.upper(cp) ~= cp
end

function M.is_upper(cp)
  return M.lower(cp) ~= cp
end

function M.is_extender(cp)
  if cp < 0x300 then return false end
  return (cp >= 0x300 and cp <= 0x36F) or (cp >= 0x1AB0 and cp <= 0x1AFF)
    or (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xFE20 and cp <= 0xFE2F)
    or cp == 0x200D or (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0xE0100 and cp <= 0xE01EF)
    or (cp >= 0xE0020 and cp <= 0xE007F)
end

function M.width(s)
  return vim.fn.strdisplaywidth(s)
end

function M.str_width(s)
  return vim.api.nvim_strwidth(s)
end

function M.truncate(s, w)
  if w <= 0 then return '' end
  if vim.api.nvim_strwidth(s) <= w then return s end
  local out, cur = {}, 0
  for _, cp in M.chars(s) do
    local ch = M.encode(cp)
    local cw = vim.api.nvim_strwidth(ch)
    if cur + cw > w then break end
    out[#out + 1] = ch
    cur = cur + cw
  end
  return table.concat(out)
end

function M.pad_right(s, w)
  local sw = vim.api.nvim_strwidth(s)
  if sw >= w then return M.truncate(s, w) end
  return s .. string.rep(' ', w - sw)
end

function M.split_lines(s)
  local out = {}
  local start = 1
  while true do
    local i = s:find('\n', start, true)
    if not i then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
  return out
end

function M.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function M.trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.starts_with(s, p)
  return s:sub(1, #p) == p
end

function M.ends_with(s, p)
  return p == '' or s:sub(-#p) == p
end

function M.rust_debug_str(s)
  local out = { '"' }
  for _, cp in M.chars(s) do
    if cp == 34 then
      out[#out + 1] = '\\"'
    elseif cp == 92 then
      out[#out + 1] = '\\\\'
    elseif cp == 10 then
      out[#out + 1] = '\\n'
    elseif cp == 13 then
      out[#out + 1] = '\\r'
    elseif cp == 9 then
      out[#out + 1] = '\\t'
    elseif cp == 0 then
      out[#out + 1] = '\\0'
    else
      out[#out + 1] = M.encode(cp)
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

function M.notify_err(msg)
  require('hx.state').set_status(msg, 'error')
end

function M.home_tilde(path)
  local home = vim.env.HOME
  if home and path:sub(1, #home) == home then return '~' .. path:sub(#home + 1) end
  return path
end

return M
