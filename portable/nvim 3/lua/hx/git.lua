local api = vim.api
local M = {}

function M.available()
  return vim.fn.executable('git') == 1
end

function M.run(args, cwd, cb)
  if not M.available() then
    vim.schedule(function()
      cb(127, '', 'git not found')
    end)
    return
  end
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local ok = pcall(vim.system, cmd, { text = true, cwd = cwd }, function(res)
    vim.schedule(function()
      cb(res.code, res.stdout or '', res.stderr or '')
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(127, '', 'failed to run git')
    end)
  end
end

local heads = {}
function M.head(buf)
  if not M.available() then return nil end
  local name = api.nvim_buf_get_name(buf)
  local dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  if not vim.uv.fs_stat(dir) then return nil end
  local e = heads[dir]
  local now = vim.uv.now()
  if e and (now - e.t) < 5000 then return e.v end
  heads[dir] = { v = e and e.v or nil, t = now }
  local function store(v)
    local changed = (heads[dir] and heads[dir].v) ~= v
    heads[dir] = { v = v, t = vim.uv.now() }
    if changed then pcall(vim.cmd.redrawstatus, { bang = true }) end
  end
  M.run({ 'symbolic-ref', '--short', '-q', 'HEAD' }, dir, function(code, out)
    out = vim.trim(out)
    if code == 0 and out ~= '' then return store(out) end
    M.run({ 'rev-parse', '--short=8', 'HEAD' }, dir, function(code2, out2)
      out2 = vim.trim(out2)
      store(code2 == 0 and out2 ~= '' and out2 or nil)
    end)
  end)
  return e and e.v or nil
end

function M.show_head(path, cb)
  local dir = vim.fn.fnamemodify(path, ':h')
  local base = vim.fn.fnamemodify(path, ':t')
  M.run({ 'show', 'HEAD:./' .. base }, dir, function(code, out)
    cb(code == 0 and out or nil)
  end)
end

local function kind_of(x, y)
  if x == '?' and y == '?' then return 'untracked' end
  if x == 'U' or y == 'U' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D') then return 'conflict' end
  if x == 'R' or y == 'R' then return 'renamed' end
  if x == 'D' or y == 'D' then return 'deleted' end
  return 'modified'
end

function M.changed_files(cwd, cb)
  M.run({ 'rev-parse', '--show-toplevel' }, cwd, function(code, top)
    if code ~= 0 then return cb({}) end
    top = vim.trim(top)
    M.run({ 'status', '--porcelain=v1', '-z', '--untracked-files=all' }, top, function(code2, out)
      local items = {}
      if code2 == 0 then
        local parts = vim.split(out, '\0', { plain = true })
        local i = 1
        while i <= #parts do
          local rec = parts[i]
          if #rec >= 4 then
            local x, y, path = rec:sub(1, 1), rec:sub(2, 2), rec:sub(4)
            local kind = kind_of(x, y)
            if x == 'R' or x == 'C' then i = i + 1 end
            items[#items + 1] = { kind = kind, path = top .. '/' .. path }
          end
          i = i + 1
        end
      end
      cb(items)
    end)
  end)
end

return M
