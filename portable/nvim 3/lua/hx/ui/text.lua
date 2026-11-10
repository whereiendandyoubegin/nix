local U = require('hx.util')
local M = {}

local strw = vim.api.nvim_strwidth

function M.word_wrap(lines, max_w, trim)
  local out = {}
  if max_w <= 0 then return out end
  local syms = {}
  for li, line in ipairs(lines) do
    for _, sp in ipairs(line) do
      for _, cp in U.chars(sp[1]) do
        syms[#syms + 1] = { U.encode(cp), sp[2], cp }
      end
    end
    syms[#syms + 1] = { "\n", nil, 10 }
  end
  local i = 1
  local current, nextl = {}, {}
  local function is_ws(s)
    return s[3] ~= 0xA0 and s[3] ~= 0x202F and U.rust_whitespace(s[3])
  end
  local function next_line()
    current, nextl = nextl, {}
    local cw = 0
    for _, s in ipairs(current) do
      cw = cw + strw(s[1])
    end
    local to_last_word_end, width_to_last = 0, 0
    local prev_ws = false
    local exhausted = true
    while i <= #syms do
      local s = syms[i]
      i = i + 1
      exhausted = false
      local sw = s[3] == 10 and 0 or strw(s[1])
      local ws = is_ws(s)
      if not (sw > max_w or (trim and ws and s[3] ~= 10 and cw == 0)) then
        if s[3] == 10 then
          if prev_ws then
            cw = width_to_last
            for k = #current, to_last_word_end + 1, -1 do
              current[k] = nil
            end
          end
          break
        end
        if ws and not prev_ws then
          to_last_word_end = #current
          width_to_last = cw
        end
        current[#current + 1] = s
        cw = cw + sw
        if cw > max_w then
          local cut, cutw
          if to_last_word_end ~= 0 then
            cut, cutw = to_last_word_end, width_to_last
          else
            cut, cutw = #current - 1, max_w
          end
          local first_nonws
          for k = cut + 1, #current do
            if not is_ws(current[k]) then
              first_nonws = k
              break
            end
          end
          if first_nonws then
            for k = first_nonws, #current do
              nextl[#nextl + 1] = current[k]
            end
          end
          for k = #current, cut + 1, -1 do
            current[k] = nil
          end
          cw = cutw
          break
        end
        prev_ws = ws
      end
    end
    if exhausted and #current == 0 then return nil end
    return current
  end
  while true do
    local l = next_line()
    if not l then break end
    out[#out + 1] = l
  end
  return out
end

function M.render(canvas, x, y, w, h, lines, scroll, base_group)
  local T = require('hx.theme')
  local wrapped = M.word_wrap(lines, w, false)
  scroll = scroll or 0
  for row = 1, h do
    local wl = wrapped[row + scroll]
    if not wl then break end
    local cx = x
    for _, s in ipairs(wl) do
      local g = s[2] and T.group_for(s[2]) or base_group
      cx = canvas:put(cx, y + row - 1, s[1], g)
    end
  end
  return #wrapped
end

local function line_width(line)
  local w = 0
  for _, sp in ipairs(line) do
    w = w + strw(sp[1])
  end
  return w
end
M.line_width = line_width

function M.required_size(lines, max_w)
  local tw, h = 0, 0
  for _, l in ipairs(lines) do
    h = h + 1
    local cw = line_width(l)
    if cw > max_w then
      tw = max_w
      h = h + (max_w > 0 and math.floor(cw / max_w) or 0)
    elseif cw > tw then
      tw = cw
    end
  end
  return tw, h
end

function M.wrap(s, width)
  local wrapped = M.word_wrap({ { { s, nil } } }, width, false)
  local out = {}
  for _, l in ipairs(wrapped) do
    local parts = {}
    for _, sym in ipairs(l) do
      parts[#parts + 1] = sym[1]
    end
    out[#out + 1] = table.concat(parts)
  end
  if #out == 0 then out[1] = '' end
  return out
end

function M.from_string(s, style)
  local out = {}
  for _, l in ipairs(U.split_lines(s)) do
    out[#out + 1] = { { l, style } }
  end
  return out
end

function M.reflow_hard_wrap(text, width)
  local out = {}
  local trailing_nl = text:sub(-1) == '\n'
  local paragraphs = {}
  local cur = {}
  for _, l in ipairs(U.split_lines(trailing_nl and text:sub(1, -2) or text)) do
    if U.trim(l) == '' then
      if #cur > 0 then paragraphs[#paragraphs + 1] = cur end
      paragraphs[#paragraphs + 1] = false
      cur = {}
    else
      cur[#cur + 1] = l
    end
  end
  if #cur > 0 then paragraphs[#paragraphs + 1] = cur end
  for _, p in ipairs(paragraphs) do
    if p == false then
      out[#out + 1] = ''
    else
      local indent = p[1]:match('^%s*')
      local prefix = p[1]:match('^%s*[#/%-%*;]+%s') or indent
      local words = {}
      for _, l in ipairs(p) do
        local body = l
        if prefix ~= indent and body:sub(1, #prefix) == prefix then
          body = body:sub(#prefix + 1)
        else
          body = U.trim(body)
        end
        for wd in body:gmatch('%S+') do
          words[#words + 1] = wd
        end
      end
      local line = prefix
      local has = false
      for _, wd in ipairs(words) do
        if has and strw(line) + 1 + strw(wd) > width then
          out[#out + 1] = line
          line = prefix .. wd
        else
          line = has and (line .. ' ' .. wd) or (line .. wd)
        end
        has = true
      end
      out[#out + 1] = line
    end
  end
  return table.concat(out, '\n') .. (trailing_nl and '\n' or '')
end

return M
