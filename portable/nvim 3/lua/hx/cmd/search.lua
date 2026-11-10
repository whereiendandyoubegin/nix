local S = require('hx.state')
local SL = require('hx.selection')
local U = require('hx.util')
local RE = require('hx.regex')
local Regs = require('hx.registers')
local R = SL.R

return function(C, H)
  local reg = C.register

  local function search_impl(regex, extend, forward, wrap_around, show_warnings)
    local text = H.text()
    local sel = H.sel()
    local subject = text:all()
    local start
    if forward then
      start = sel:prim():to()
    else
      start = sel:prim():from()
    end
    local ms, me
    if forward then
      ms, me = regex:find(subject, start, #subject)
    else
      for a, b in regex:find_iter(subject, 0, start) do
        if b <= start then ms, me = a, b end
      end
    end
    if not ms then
      if wrap_around then
        if forward then
          ms, me = regex:find(subject, 0, #subject)
        else
          for a, b in regex:find_iter(subject, start, #subject) do
            ms, me = a, b
          end
        end
      end
      if show_warnings then
        if wrap_around and ms then
          H.status('Wrapped around document')
        else
          H.error('No more matches')
        end
      end
    end
    if ms then
      if me == 0 then return end
      local prim = sel:prim()
      local range = R(ms, me):with_direction(prim:forward())
      local nsel
      if extend then
        nsel = sel:push(range)
      else
        nsel = sel:replace(sel.primary, range)
      end
      H.set_sel(nsel)
      require('hx.cmd.view_util').ensure_cursor_in_view_center(H.win())
    end
  end
  C.search_impl = search_impl

  local function search_completions(regname)
    local items = Regs.read(regname) or {}
    local out, seen = {}, {}
    for i = 1, math.min(200, #items) do
      local it = items[i]
      if not seen[it] then
        seen[it] = true
        out[#out + 1] = it
      end
    end
    table.sort(out)
    return out
  end

  local function searcher(ctx, forward)
    local regname = ctx.register or '/'
    local wrap = S.config.editor.search['wrap-around'] ~= false
    local extend = S.mode == 'select'
    local completions = search_completions(regname)
    require('hx.ui.prompt').regex_prompt({
      prompt = 'search:',
      register = regname,
      completion = function(input)
        local out = {}
        for _, c in ipairs(completions) do
          if c:sub(1, #input) == input then out[#out + 1] = { 0, c } end
        end
        return out
      end,
      callback = function(regex, event)
        if event == 'validate' then
          Regs.last_search_register = regname
        elseif event ~= 'update' then
          return
        end
        search_impl(regex, extend, forward, wrap, false)
      end,
    })
  end
  reg('search', function(ctx) searcher(ctx, true) end)
  reg('rsearch', function(ctx) searcher(ctx, false) end)

  local function search_next_or_prev(ctx, extend, forward)
    local count = ctx:get_count()
    local regname = ctx.register or Regs.last_search_register
    local query = Regs.first(regname)
    if not query then return end
    local smart = S.config.editor.search['smart-case'] ~= false
    local ci = false
    if smart then
      ci = true
      for _, cp in U.chars(query) do
        if U.is_upper(cp) then
          ci = false
          break
        end
      end
    end
    local regex = RE.new(query, { ci = ci })
    if not regex then
      H.error('Invalid regex: ' .. query)
      return
    end
    local wrap = S.config.editor.search['wrap-around'] ~= false
    for _ = 1, count do
      search_impl(regex, extend, forward, wrap, true)
    end
  end
  reg('search_next', function(ctx) search_next_or_prev(ctx, false, true) end)
  reg('search_prev', function(ctx) search_next_or_prev(ctx, false, false) end)
  reg('extend_search_next', function(ctx) search_next_or_prev(ctx, true, true) end)
  reg('extend_search_prev', function(ctx) search_next_or_prev(ctx, true, false) end)

  local function search_selection_impl(ctx, detect)
    local text = H.text()
    local len = text:len()
    local function at_word_start(i)
      if i == len then return false end
      local ch = text:char(i)
      if i == 0 then return U.is_word(ch) end
      local prev = text:char(text:prev_char(i))
      return not U.is_word(prev) and U.is_word(ch)
    end
    local function at_word_end(i)
      if i == 0 or i == len then return false end
      local ch = text:char(i)
      local prev = text:char(text:prev_char(i))
      return U.is_word(prev) and not U.is_word(ch)
    end
    local regname = ctx.register or '/'
    local parts, seen = {}, {}
    for _, r in ipairs(H.sel().ranges) do
      local pre = (detect and at_word_start(r:from())) and '\\b' or ''
      local suf = (detect and at_word_end(r:to())) and '\\b' or ''
      local s = pre .. RE.escape(r:fragment(text)) .. suf
      if not seen[s] then
        seen[s] = true
        parts[#parts + 1] = s
      end
    end
    local regex = table.concat(parts, '|')
    local ok, err = Regs.push(regname, regex)
    if ok then
      Regs.last_search_register = regname
      H.status(("register '%s' set to '%s'"):format(regname, regex))
    else
      H.error(err)
    end
  end
  reg('search_selection', function(ctx) search_selection_impl(ctx, false) end)
  reg('search_selection_detect_word_boundaries', function(ctx) search_selection_impl(ctx, true) end)

  reg('make_search_word_bounded', function(ctx)
    local regname = ctx.register or Regs.last_search_register
    local regex = Regs.first(regname)
    if not regex then return end
    local sa = regex:sub(1, 2) == '\\b'
    local ea = regex:sub(-2) == '\\b'
    if sa and ea then return end
    local n = (sa and '' or '\\b') .. regex .. (ea and '' or '\\b')
    local ok, err = Regs.push(regname, n)
    if ok then
      Regs.last_search_register = regname
      H.status(("register '%s' set to '%s'"):format(regname, n))
    else
      H.error(err)
    end
  end)

  reg('global_search', function(ctx)
    local regname = ctx.register or '/'
    Regs.last_search_register = regname
    require('hx.ui.pickers').global_search(regname)
  end)
end
