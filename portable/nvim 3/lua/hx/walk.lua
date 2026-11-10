local uv = vim.uv

local M = {}

local VCS_DIRS = { ['.git'] = true, ['.pijul'] = true, ['.jj'] = true, ['.hg'] = true, ['.svn'] = true }
local COMPRESSED = {
  zip = true, gz = true, bz2 = true, zst = true, lzo = true, sz = true, tgz = true, tbz2 = true, lz = true,
  lz4 = true, lzma = true, z = true, Z = true, xz = true, ['7z'] = true, rar = true, cab = true,
}

function M.opts_from(cfg)
  cfg = cfg or {}
  return {
    hidden = cfg.hidden ~= false,
    git_ignore = cfg['git-ignore'] ~= false,
    ignore = cfg.ignore ~= false,
    parents = cfg.parents ~= false,
    git_global = cfg['git-global'] ~= false,
    git_exclude = cfg['git-exclude'] ~= false,
  }
end

local function join(d, name)
  if d:sub(-1) == '/' then return d .. name end
  return d .. '/' .. name
end

local function dirname(p)
  local d = p:match('^(.*)/[^/]*$')
  if d == nil then return '.' end
  if d == '' then return '/' end
  return d
end

local function abspath(p)
  return (vim.fn.fnamemodify(p, ':p'):gsub('(.)/$', '%1'))
end

local function read_lines(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  local out = {}
  for l in (s .. '\n'):gmatch('(.-)\r?\n') do
    out[#out + 1] = l
  end
  return out
end

local function vim_escape(ch)
  if ch:match('[%w_]') or ch:byte() >= 128 then return ch end
  return '\\' .. ch
end

local function class_to_vim(pat, i)
  local j = i + 1
  local out = { '[' }
  if pat:sub(j, j) == '!' or pat:sub(j, j) == '^' then
    out[#out + 1] = '^'
    j = j + 1
  end
  local first = true
  while j <= #pat do
    local c = pat:sub(j, j)
    if c == ']' and not first then
      out[#out + 1] = ']'
      return table.concat(out), j
    end
    if c == '\\' and j < #pat then
      j = j + 1
      c = pat:sub(j, j)
    end
    if c == ']' or c == '\\' or c == '^' then
      out[#out + 1] = '\\' .. c
    else
      out[#out + 1] = c
    end
    first = false
    j = j + 1
  end
  return nil, i
end

local function glob_to_vim(pat)
  local out = {}
  local i = 1
  local n = #pat
  while i <= n do
    local c = pat:sub(i, i)
    if c == '*' then
      if pat:sub(i, i + 1) == '**' then
        local before = i == 1 or pat:sub(i - 1, i - 1) == '/'
        local after = pat:sub(i + 2, i + 2)
        if before and after == '/' then
          out[#out + 1] = '%(.*/)?'
          i = i + 3
        elseif before and i + 2 > n then
          out[#out + 1] = '.*'
          i = i + 2
        else
          out[#out + 1] = '[^/]*'
          i = i + 2
        end
      else
        out[#out + 1] = '[^/]*'
        i = i + 1
      end
    elseif c == '?' then
      out[#out + 1] = '[^/]'
      i = i + 1
    elseif c == '[' then
      local cls, j = class_to_vim(pat, i)
      if cls then
        out[#out + 1] = cls
        i = j + 1
      else
        out[#out + 1] = '\\['
        i = i + 1
      end
    elseif c == '\\' and i < n then
      out[#out + 1] = vim_escape(pat:sub(i + 1, i + 1))
      i = i + 2
    else
      out[#out + 1] = vim_escape(c)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function compile_rule(line)
  if line == '' or line:sub(1, 1) == '#' then return nil end
  line = line:gsub('([^\\])%s+$', '%1')
  if line:match('^%s+$') then return nil end
  local neg = false
  if line:sub(1, 1) == '!' then
    neg = true
    line = line:sub(2)
  elseif line:sub(1, 2) == '\\!' or line:sub(1, 2) == '\\#' then
    line = line:sub(2)
  end
  local dir_only = false
  if line:sub(-1) == '/' then
    dir_only = true
    line = line:sub(1, -2)
  end
  if line == '' then return nil end
  local anchored = line:find('/', 1, true) ~= nil
  if line:sub(1, 1) == '/' then line = line:sub(2) end
  local body = glob_to_vim(line)
  if not anchored then body = '%(.*/)?' .. body end
  local ok, re = pcall(vim.regex, '\\v^' .. body .. '$')
  if not ok then return nil end
  return { re = re, neg = neg, dir_only = dir_only }
end

local Matcher = {}
Matcher.__index = Matcher

local function new_matcher(base, lines)
  local rules = {}
  for _, l in ipairs(lines) do
    local r = compile_rule(l)
    if r then rules[#rules + 1] = r end
  end
  if #rules == 0 then return nil end
  return setmetatable({ base = base, rules = rules }, Matcher)
end

function Matcher:match(path, is_dir)
  local base = self.base
  local rel
  if path:sub(1, #base + 1) == base .. '/' then
    rel = path:sub(#base + 2)
  elseif base == '/' and path:sub(1, 1) == '/' then
    rel = path:sub(2)
  else
    return nil
  end
  local res
  for i = #self.rules, 1, -1 do
    local r = self.rules[i]
    if (not r.dir_only or is_dir) and r.re:match_str(rel) then
      res = not r.neg
      break
    end
  end
  return res
end

local function matcher_from_file(base, file)
  local lines = read_lines(file)
  if not lines then return nil end
  return new_matcher(base, lines)
end

local function is_file(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == 'file'
end

local function repo_root(path)
  local p = path
  while true do
    if uv.fs_stat(join(p, '.git')) then return p end
    local parent = dirname(p)
    if parent == p then return nil end
    p = parent
  end
end

local function config_home()
  return vim.env.XDG_CONFIG_HOME or (vim.fn.expand('~') .. '/.config')
end

local function dir_matchers(d, opts, in_repo, git_only, ignore_only)
  local ms = {}
  local names = {}
  if not ignore_only and opts.git_ignore and in_repo then names[#names + 1] = '.gitignore' end
  if not git_only and opts.ignore then
    names[#names + 1] = '.ignore'
    names[#names + 1] = '.helix/ignore'
  end
  for _, n in ipairs(names) do
    local f = join(d, n)
    if is_file(f) then
      local m = matcher_from_file(d, f)
      if m then ms[#ms + 1] = m end
    end
  end
  return ms
end

local function initial_matchers(root, opts)
  local ms = {}
  local rr = repo_root(root)
  if opts.git_global and rr then
    local m = matcher_from_file(rr, config_home() .. '/git/ignore')
    if m then ms[#ms + 1] = m end
  end
  if opts.git_exclude and rr then
    local m = matcher_from_file(rr, rr .. '/.git/info/exclude')
    if m then ms[#ms + 1] = m end
  end
  local ci = matcher_from_file(root, config_home() .. '/helix/ignore')
  if ci then ms[#ms + 1] = ci end
  if opts.parents then
    local parents = {}
    local p = dirname(root)
    while true do
      table.insert(parents, 1, p)
      local np = dirname(p)
      if np == p then break end
      p = np
    end
    for _, d in ipairs(parents) do
      if opts.git_ignore and rr and (d == rr or d:sub(1, #rr + 1) == rr .. '/') then
        vim.list_extend(ms, dir_matchers(d, opts, true, true, false))
      end
      if opts.ignore then vim.list_extend(ms, dir_matchers(d, opts, false, false, true)) end
    end
  end
  return ms, rr ~= nil
end

local function ignored(path, is_dir, matchers)
  local res
  for _, m in ipairs(matchers) do
    local r = m:match(path, is_dir)
    if r ~= nil then res = r end
  end
  return res == true
end

local function list_sorted(d)
  local fs = uv.fs_scandir(d)
  if not fs then return {} end
  local out = {}
  while true do
    local name, typ = uv.fs_scandir_next(fs)
    if not name then break end
    out[#out + 1] = { name, typ }
  end
  table.sort(out, function(a, b)
    return a[1] < b[1]
  end)
  return out
end

local function walker(root, opts, max_depth, files_only)
  root = abspath(root)
  return coroutine.wrap(function()
    local seen = {}
    local root_real = uv.fs_realpath(root) or root
    seen[root_real] = true
    local base, in_repo = initial_matchers(root, opts)
    local function rec(d, matchers, depth, repo)
      if not repo and uv.fs_stat(join(d, '.git')) then repo = true end
      local local_ms = { unpack(matchers) }
      vim.list_extend(local_ms, dir_matchers(d, opts, repo))
      for _, e in ipairs(list_sorted(d)) do
        local name, typ = e[1], e[2]
        local p = join(d, name)
        if not (opts.hidden and name:sub(1, 1) == '.') then
          local is_dir = typ == 'directory'
          local is_link = typ == 'link'
          if is_link then
            local st = uv.fs_stat(p)
            is_dir = st ~= nil and st.type == 'directory'
          end
          if not (is_dir and VCS_DIRS[name]) and not ignored(p, is_dir, local_ms) then
            if is_dir then
              local rp = uv.fs_realpath(p) or p
              local loops = is_link and (root_real .. '/'):sub(1, #rp + 1) == rp .. '/'
              if not seen[rp] and not loops then
                seen[rp] = true
                if not files_only then coroutine.yield(p, true) end
                if not max_depth or depth + 1 < max_depth then rec(p, local_ms, depth + 1, repo) end
              end
            else
              local ext = name:match('%.([^.]+)$')
              if not (ext and COMPRESSED[ext]) then coroutine.yield(p, false) end
            end
          end
        end
      end
    end
    rec(root, base, 0, in_repo)
  end)
end

function M.dir(root, opts)
  local items = {}
  for p, is_dir in walker(root, opts, 1, false) do
    items[#items + 1] = { p, is_dir }
  end
  table.sort(items, function(a, b)
    if a[2] ~= b[2] then return a[2] end
    return a[1] < b[1]
  end)
  return items
end

local function drive(step, done)
  local handle = { cancelled = false }
  function handle.cancel()
    handle.cancelled = true
  end
  local timer = uv.new_timer()
  local function tick()
    if handle.cancelled then
      timer:close()
      return
    end
    local deadline = uv.hrtime() + 8e6
    local finished = false
    while uv.hrtime() < deadline do
      local ok, more = pcall(step)
      if not ok then
        finished = true
        timer:close()
        done(tostring(more))
        return
      end
      if not more then
        finished = true
        break
      end
    end
    if finished then
      timer:close()
      done(nil)
    else
      timer:start(0, 0, vim.schedule_wrap(tick))
    end
  end
  timer:start(0, 0, vim.schedule_wrap(tick))
  return handle
end

function M.files(root, opts, on_batch, done)
  local it = walker(root, opts, nil, true)
  local batch = {}
  return drive(function()
    for _ = 1, 64 do
      local p = it()
      if not p then
        if #batch > 0 then on_batch(batch) end
        batch = {}
        return false
      end
      batch[#batch + 1] = p
    end
    if #batch >= 256 then
      on_batch(batch)
      batch = {}
    end
    return true
  end, function(err)
    if #batch > 0 then on_batch(batch) end
    done(err)
  end)
end

function M.grep(root, regex, opts, skip, on_batch, done)
  local it = walker(root, opts, nil, true)
  local batch = {}
  local multiline = regex.multiline
  local function search(path)
    if skip[path] then return end
    local f = io.open(path, 'rb')
    if not f then return end
    local data = f:read('*a')
    f:close()
    if not data or data:find('\0', 1, true) then return end
    if multiline then
      local line_starts = { 0 }
      for pos in data:gmatch('()\n') do
        line_starts[#line_starts + 1] = pos
      end
      local function line_of(off)
        local lo, hi = 1, #line_starts
        while lo < hi do
          local mid = math.floor((lo + hi + 1) / 2)
          if line_starts[mid] <= off then lo = mid else hi = mid - 1 end
        end
        return lo - 1
      end
      for s, e in regex.re:find_iter(data, 0, #data) do
        local ls = line_of(s)
        batch[#batch + 1] = { path = path, line_start = ls, line_end = line_of(math.max(s, e - 1)) }
      end
    else
      local i = 0
      for line in (data .. '\n'):gmatch('(.-)\n') do
        if regex.re:find(line, 0, #line) then
          batch[#batch + 1] = { path = path, line_start = i, line_end = i }
        end
        i = i + 1
      end
    end
  end
  return drive(function()
    local p = it()
    if not p then return false end
    search(p)
    if #batch >= 64 then
      on_batch(batch)
      batch = {}
    end
    return true
  end, function(err)
    if #batch > 0 then on_batch(batch) end
    done(err)
  end)
end

M._compile_rule = compile_rule
M._new_matcher = new_matcher

return M
