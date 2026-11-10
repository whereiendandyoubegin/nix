local M = {}

local floor = math.floor

local B = 16777216

local function bn_trim(a)
  while #a > 0 and a[#a] == 0 do
    a[#a] = nil
  end
  return a
end

local function bn_from_int(n)
  local a = {}
  while n > 0 do
    a[#a + 1] = n % B
    n = floor(n / B)
  end
  return a
end

local function bn_mul_add(a, m, d)
  local carry = d
  for i = 1, #a do
    local v = a[i] * m + carry
    a[i] = v % B
    carry = floor(v / B)
  end
  while carry > 0 do
    a[#a + 1] = carry % B
    carry = floor(carry / B)
  end
  return a
end

local function bn_cmp(a, b)
  if #a ~= #b then return #a < #b and -1 or 1 end
  for i = #a, 1, -1 do
    if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
  end
  return 0
end

local function bn_add(a, b)
  local r, carry = {}, 0
  for i = 1, math.max(#a, #b) do
    local v = (a[i] or 0) + (b[i] or 0) + carry
    r[i] = v % B
    carry = floor(v / B)
  end
  if carry > 0 then r[#r + 1] = carry end
  return r
end

local function bn_sub(a, b)
  local r, borrow = {}, 0
  for i = 1, #a do
    local v = a[i] - (b[i] or 0) - borrow
    if v < 0 then
      v = v + B
      borrow = 1
    else
      borrow = 0
    end
    r[i] = v
  end
  return bn_trim(r)
end

local function bn_divmod_small(a, d)
  local q, rem = {}, 0
  for i = #a, 1, -1 do
    local v = rem * B + a[i]
    q[i] = floor(v / d)
    rem = v % d
  end
  return bn_trim(q), rem
end

local DIGITS = '0123456789abcdefghijklmnopqrstuvwxyz'

local function bn_to_radix(a, radix, upper)
  if #a == 0 then return '0' end
  local out = {}
  local cur = { unpack(a) }
  while #cur > 0 do
    local rem
    cur, rem = bn_divmod_small(cur, radix)
    out[#out + 1] = DIGITS:sub(rem + 1, rem + 1)
  end
  local s = string.reverse(table.concat(out))
  if upper then s = s:upper() end
  return s
end

local function pow2(n)
  local a = { 1 }
  for _ = 1, n do
    a = bn_add(a, a)
  end
  return a
end
local I128_MAX = bn_sub(pow2(127), { 1 })
local I128_MIN_MAG = pow2(127)
local U128_LIMIT = pow2(128)

local function s_add(x, y)
  if x.neg == y.neg then return { neg = x.neg, mag = bn_add(x.mag, y.mag) } end
  local c = bn_cmp(x.mag, y.mag)
  if c == 0 then return { neg = false, mag = {} } end
  if c > 0 then return { neg = x.neg, mag = bn_sub(x.mag, y.mag) } end
  return { neg = y.neg, mag = bn_sub(y.mag, x.mag) }
end

local function s_from_int(n)
  if n < 0 then return { neg = true, mag = bn_from_int(-n) } end
  return { neg = false, mag = bn_from_int(n) }
end

local function saturate_i128(x)
  if x.neg then
    if bn_cmp(x.mag, I128_MIN_MAG) > 0 then return { neg = true, mag = I128_MIN_MAG } end
  elseif bn_cmp(x.mag, I128_MAX) > 0 then
    return { neg = false, mag = I128_MAX }
  end
  return x
end

local function parse_radix(s, radix, signed)
  local neg = false
  local i = 1
  local c = s:sub(1, 1)
  if c == '+' then
    i = 2
  elseif c == '-' and signed then
    neg = true
    i = 2
  end
  if i > #s then return nil end
  local mag = {}
  for k = i, #s do
    local ch = s:sub(k, k):lower()
    local d = DIGITS:find(ch, 1, true)
    if not d or d > radix then return nil end
    bn_mul_add(mag, radix, d - 1)
  end
  bn_trim(mag)
  if #mag == 0 then neg = false end
  return { neg = neg, mag = mag }
end

local function zero_pad(s, width)
  local sign = ''
  if s:sub(1, 1) == '-' then
    sign = '-'
    s = s:sub(2)
  end
  local n = width - #sign - #s
  if n > 0 then s = string.rep('0', n) .. s end
  return sign .. s
end

local function s_to_dec(x)
  local s = bn_to_radix(x.mag, 10)
  if x.neg and s ~= '0' then s = '-' .. s end
  return s
end

local SEPARATOR = '_'

function M.integer(selected_text, amount)
  local t = selected_text
  if t == '' or t:sub(-1) == SEPARATOR or t:sub(1, 1) == SEPARATOR then return nil end

  local radix = 10
  if t:sub(1, 2) == '0x' then
    radix = 16
  elseif t:sub(1, 2) == '0o' then
    radix = 8
  elseif t:sub(1, 2) == '0b' then
    radix = 2
  end

  local chars = {}
  for _, cp in require('hx.util').chars(t) do
    chars[#chars + 1] = cp
  end
  local sep_rtl = {}
  for i = #chars, 1, -1 do
    if chars[i] == 95 then sep_rtl[#sep_rtl + 1] = #chars - i end
  end
  local word = t:gsub(SEPARATOR, '')

  local new_text
  if radix == 10 then
    local number = word
    local value = parse_radix(number, 10, true)
    if not value then return nil end
    if value.neg then
      if bn_cmp(value.mag, I128_MIN_MAG) > 0 then return nil end
    elseif bn_cmp(value.mag, I128_MAX) > 0 then
      return nil
    end
    local new_value = saturate_i128(s_add(value, s_from_int(amount)))
    local vneg = value.neg
    local nneg = new_value.neg and #new_value.mag > 0
    local format_length = #number
    if vneg and not nneg then
      format_length = #number - 1
    elseif not vneg and nneg then
      format_length = #number + 1
    end
    format_length = format_length - #sep_rtl
    if number:sub(1, 1) == '0' or number:sub(1, 2) == '-0' then
      new_text = zero_pad(s_to_dec(new_value), format_length)
    else
      new_text = s_to_dec(new_value)
    end
  else
    local number = word:sub(3)
    local value = parse_radix(number, radix, false)
    if not value then return nil end
    if bn_cmp(value.mag, U128_LIMIT) >= 0 then return nil end
    if bn_cmp(value.mag, I128_MIN_MAG) >= 0 then
      value = { neg = true, mag = bn_sub(U128_LIMIT, value.mag) }
    end
    local new_value = saturate_i128(s_add(value, s_from_int(amount)))
    if new_value.neg then new_value = { neg = false, mag = {} } end
    local format_length = #t - 2 - #sep_rtl
    if radix == 2 then
      new_text = '0b' .. zero_pad(bn_to_radix(new_value.mag, 2), format_length)
    elseif radix == 8 then
      new_text = '0o' .. zero_pad(bn_to_radix(new_value.mag, 8), format_length)
    else
      local lower, upper = 0, 0
      for k = 1, #number do
        local b = number:byte(k)
        if b >= 97 and b <= 122 then lower = lower + 1 end
        if b >= 65 and b <= 90 then upper = upper + 1 end
      end
      new_text = '0x' .. zero_pad(bn_to_radix(new_value.mag, 16, upper > lower), format_length)
    end
  end

  for _, rtl in ipairs(sep_rtl) do
    if rtl < #new_text then
      local new_index = #new_text - rtl
      if new_index > 0 then
        new_text = new_text:sub(1, new_index) .. SEPARATOR .. new_text:sub(new_index + 1)
      end
    end
  end

  if #new_text > #t and #sep_rtl > 0 then
    local spacing
    if #sep_rtl >= 2 then
      spacing = sep_rtl[#sep_rtl] - sep_rtl[#sep_rtl - 1] - 1
    else
      spacing = sep_rtl[1]
    end
    local prefix_length = radix == 10 and 0 or 2
    local found = new_text:find(SEPARATOR, 1, true)
    if found and spacing > 0 then
      local index = found - 1
      while index - prefix_length > spacing do
        index = index - spacing
        new_text = new_text:sub(1, index) .. SEPARATOR .. new_text:sub(index + 1)
      end
    end
  end

  return new_text
end

local WEEKDAYS = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }
local WEEKDAYS_LONG = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }
local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
local MONTHS_LONG = {
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
  'November', 'December',
}

local function is_digit(s, i)
  local b = s:byte(i)
  return b and b >= 48 and b <= 57
end
local function in_set(s, i, lo, hi)
  local b = s:byte(i)
  return b and b >= lo:byte() and b <= hi:byte()
end

local function digits_n(n)
  return function(s, i)
    for k = i, i + n - 1 do
      if not is_digit(s, k) then return {} end
    end
    return { i + n }
  end
end
local function class_digit(lo, hi)
  return function(s, i)
    if in_set(s, i, lo, hi) and is_digit(s, i + 1) then return { i + 2 } end
    return {}
  end
end
local function opt_class_digit(lo, hi)
  return function(s, i)
    local r = {}
    if in_set(s, i, lo, hi) and is_digit(s, i + 1) then r[#r + 1] = i + 2 end
    if is_digit(s, i) then r[#r + 1] = i + 1 end
    return r
  end
end
local function alternation(words)
  return function(s, i)
    local r = {}
    for _, w in ipairs(words) do
      if s:sub(i, i + #w - 1) == w then r[#r + 1] = i + #w end
    end
    return r
  end
end

local FIELDS = {
  Y = { m = digits_n(4), unit = 'Years' },
  y = { m = digits_n(2), unit = 'Years' },
  m = { m = class_digit('0', '1'), unit = 'Months' },
  d = { m = class_digit('0', '3'), unit = 'Days' },
  ['-d'] = { m = opt_class_digit('1', '3'), unit = 'Days' },
  a = { m = alternation(WEEKDAYS), unit = 'Days' },
  A = { m = alternation(WEEKDAYS_LONG), unit = 'Days' },
  b = { m = alternation(MONTHS), unit = 'Months' },
  h = { m = alternation(MONTHS), unit = 'Months' },
  B = { m = alternation(MONTHS_LONG), unit = 'Months' },
  H = { m = class_digit('0', '2'), unit = 'Hours' },
  M = { m = class_digit('0', '5'), unit = 'Minutes' },
  S = { m = class_digit('0', '5'), unit = 'Seconds' },
  I = { m = class_digit('0', '1'), unit = 'Hours' },
  ['-I'] = { m = opt_class_digit('1', '1'), unit = 'Hours' },
  P = { m = alternation({ 'am', 'pm' }), unit = 'AmPm' },
  p = { m = alternation({ 'AM', 'PM' }), unit = 'AmPm' },
}

local function is_date(u)
  return u == 'Years' or u == 'Months' or u == 'Days'
end
local function is_time(u)
  return u == 'Hours' or u == 'Minutes' or u == 'Seconds'
end

local function compile(fmt)
  local items, fields = {}, {}
  local i = 1
  while true do
    local j = fmt:find('%', i, true)
    if not j then
      if i <= #fmt then items[#items + 1] = { lit = fmt:sub(i) } end
      break
    end
    if j > i then items[#items + 1] = { lit = fmt:sub(i, j - 1) } end
    local spec = fmt:sub(j + 1, j + 1)
    local len = 1
    if spec == '-' then
      spec = fmt:sub(j + 1, j + 2)
      len = 2
    end
    local f = assert(FIELDS[spec], spec)
    items[#items + 1] = { spec = spec, field = f }
    fields[#fields + 1] = f
    i = j + 1 + len
  end
  local has_date, has_time = false, false
  for _, f in ipairs(fields) do
    if is_date(f.unit) then has_date = true end
    if is_time(f.unit) then has_time = true end
  end
  return { fmt = fmt, items = items, has_date = has_date, has_time = has_time }
end

local function regex_match(format, s)
  local items = format.items
  local caps = {}
  local function go(k, i)
    if k > #items then return i == #s + 1 end
    local it = items[k]
    if it.lit then
      if s:sub(i, i + #it.lit - 1) ~= it.lit then return false end
      return go(k + 1, i + #it.lit)
    end
    for _, e in ipairs(it.field.m(s, i)) do
      caps[k] = s:sub(i, e - 1)
      if go(k + 1, e) then return true end
    end
    caps[k] = nil
    return false
  end
  if go(1, 1) then return caps end
  return nil
end

local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end

local function is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end
local MDAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function month_days(y, m)
  if m == 2 and is_leap(y) then return 29 end
  return MDAYS[m]
end

local function weekday(days)
  return (days + 4) % 7
end

local function index_of(list, v)
  for i, x in ipairs(list) do
    if x == v then return i end
  end
end

local function parse(format, caps)
  local v = {}
  local wd, ampm, h12
  for k, it in ipairs(format.items) do
    local c = caps[k]
    local sp = it.spec
    if sp == 'Y' then
      v.y = tonumber(c)
    elseif sp == 'y' then
      local n = tonumber(c)
      v.y = n < 70 and 2000 + n or 1900 + n
    elseif sp == 'm' then
      v.m = tonumber(c)
    elseif sp == 'b' or sp == 'h' then
      v.m = index_of(MONTHS, c)
    elseif sp == 'B' then
      v.m = index_of(MONTHS_LONG, c)
    elseif sp == 'd' or sp == '-d' then
      v.d = tonumber(c)
    elseif sp == 'a' then
      wd = index_of(WEEKDAYS, c) - 1
    elseif sp == 'A' then
      wd = index_of(WEEKDAYS_LONG, c) - 1
    elseif sp == 'H' then
      v.H = tonumber(c)
    elseif sp == 'I' or sp == '-I' then
      h12 = tonumber(c)
    elseif sp == 'M' then
      v.M = tonumber(c)
    elseif sp == 'S' then
      v.S = tonumber(c)
    elseif sp == 'P' or sp == 'p' then
      ampm = c:lower()
    end
  end
  if h12 then
    if h12 < 1 or h12 > 12 then return nil end
    if not ampm then return nil end
    local h = h12 % 12 + (ampm == 'pm' and 12 or 0)
    if v.H and v.H ~= h then return nil end
    v.H = h
  end
  if format.has_date then
    if not (v.y and v.m and v.d) then return nil end
    if v.m < 1 or v.m > 12 then return nil end
    if v.d < 1 or v.d > month_days(v.y, v.m) then return nil end
    if wd and weekday(days_from_civil(v.y, v.m, v.d)) ~= wd then return nil end
  end
  if format.has_time then
    if not (v.H and v.M) then return nil end
    if v.H > 23 or v.M > 59 then return nil end
    v.S = v.S or 0
    if v.S > 59 then return nil end
  end
  return v
end

local function fmt_year(y)
  if y >= 0 and y <= 9999 then return string.format('%04d', y) end
  return (y < 0 and '-' or '+') .. string.format('%04d', math.abs(y))
end

local function format_out(format, v)
  local out = {}
  for _, it in ipairs(format.items) do
    local sp = it.spec
    if it.lit then
      out[#out + 1] = it.lit
    elseif sp == 'Y' then
      out[#out + 1] = fmt_year(v.y)
    elseif sp == 'y' then
      out[#out + 1] = string.format('%02d', v.y % 100)
    elseif sp == 'm' then
      out[#out + 1] = string.format('%02d', v.m)
    elseif sp == 'b' or sp == 'h' then
      out[#out + 1] = MONTHS[v.m]
    elseif sp == 'B' then
      out[#out + 1] = MONTHS_LONG[v.m]
    elseif sp == 'd' then
      out[#out + 1] = string.format('%02d', v.d)
    elseif sp == '-d' then
      out[#out + 1] = tostring(v.d)
    elseif sp == 'a' then
      out[#out + 1] = WEEKDAYS[weekday(days_from_civil(v.y, v.m, v.d)) + 1]
    elseif sp == 'A' then
      out[#out + 1] = WEEKDAYS_LONG[weekday(days_from_civil(v.y, v.m, v.d)) + 1]
    elseif sp == 'H' then
      out[#out + 1] = string.format('%02d', v.H)
    elseif sp == 'I' then
      out[#out + 1] = string.format('%02d', (v.H + 11) % 12 + 1)
    elseif sp == '-I' then
      out[#out + 1] = tostring((v.H + 11) % 12 + 1)
    elseif sp == 'M' then
      out[#out + 1] = string.format('%02d', v.M)
    elseif sp == 'S' then
      out[#out + 1] = string.format('%02d', v.S)
    elseif sp == 'P' then
      out[#out + 1] = v.H >= 12 and 'pm' or 'am'
    elseif sp == 'p' then
      out[#out + 1] = v.H >= 12 and 'PM' or 'AM'
    end
  end
  return table.concat(out)
end

local FORMATS = {}
for _, f in ipairs({
  '%Y-%m-%d %H:%M:%S',
  '%Y/%m/%d %H:%M:%S',
  '%Y-%m-%d %H:%M',
  '%Y/%m/%d %H:%M',
  '%Y-%m-%d',
  '%Y/%m/%d',
  '%a %b %d %Y',
  '%d-%b-%Y',
  '%Y %b %d',
  '%b %d, %Y',
  '%-I:%M:%S %P',
  '%-I:%M %P',
  '%-I:%M:%S %p',
  '%-I:%M %p',
  '%H:%M:%S',
  '%H:%M',
}) do
  FORMATS[#FORMATS + 1] = compile(f)
end
M.FORMATS = FORMATS

local MAX_YEAR, MIN_YEAR = 262143, -262144

function M.date_time(selected_text, amount)
  if selected_text == '' then return nil end
  for _, format in ipairs(FORMATS) do
    local caps = regex_match(format, selected_text)
    local v = caps and parse(format, caps)
    if v then
      if format.has_date and format.has_time then
        local days = days_from_civil(v.y, v.m, v.d)
        local mins = days * 1440 + v.H * 60 + v.M + amount
        local nd = floor(mins / 1440)
        local rem = mins - nd * 1440
        local y, m, d = civil_from_days(nd)
        if y > MAX_YEAR or y < MIN_YEAR then return nil end
        return format_out(format, { y = y, m = m, d = d, H = floor(rem / 60), M = rem % 60, S = v.S })
      elseif format.has_date then
        local y, m, d = civil_from_days(days_from_civil(v.y, v.m, v.d) + amount)
        if y > MAX_YEAR or y < MIN_YEAR then return nil end
        return format_out(format, { y = y, m = m, d = d })
      elseif format.has_time then
        local mins = (v.H * 60 + v.M + amount) % 1440
        return format_out(format, { H = floor(mins / 60), M = mins % 60, S = v.S })
      end
    end
  end
  return nil
end

function M.increment(selected_text, amount)
  return M.integer(selected_text, amount) or M.date_time(selected_text, amount)
end

function M.increment_impl(text, selection, amount, increase_by)
  local S = require('hx.selection')
  increase_by = increase_by or 0
  local new_ranges = {}
  local diff = 0
  local changes = {}
  for _, range in ipairs(selection.ranges) do
    local selected = range:fragment(text)
    local new_from = range:from() + diff
    local incremented = M.increment(selected, amount)
    amount = amount + increase_by
    if not incremented then
      new_ranges[#new_ranges + 1] = S.Range.new(new_from, range:to() + diff)
    else
      new_ranges[#new_ranges + 1] = S.Range.new(new_from, new_from + #incremented)
      diff = diff + #incremented - #selected
      changes[#changes + 1] = { range:from(), range:to(), incremented }
    end
  end
  if #changes == 0 then return nil end
  return S.Transaction.change(text, changes):with_selection(S.Selection.new(new_ranges, selection.primary))
end

return M
