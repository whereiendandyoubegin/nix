local M = {}

M.inner = {}
M.last_search_register = '/'

local provider

local function exe(name)
  return vim.fn.executable(name) == 1
end

local function detect()
  if provider then return provider end
  local sys = vim.uv.os_uname().sysname
  if sys == 'Darwin' and exe('pbcopy') and exe('pbpaste') then
    provider = {
      name = 'pasteboard',
      copy = { clipboard = { 'pbcopy' }, selection = { 'pbcopy' } },
      paste = { clipboard = { 'pbpaste' }, selection = { 'pbpaste' } },
    }
  elseif vim.env.WAYLAND_DISPLAY and exe('wl-copy') and exe('wl-paste') then
    provider = {
      name = 'wayland',
      copy = { clipboard = { 'wl-copy', '--type', 'text/plain' },
        selection = { 'wl-copy', '-p', '--type', 'text/plain' } },
      paste = { clipboard = { 'wl-paste', '--no-newline' }, selection = { 'wl-paste', '-p', '--no-newline' } },
    }
  elseif vim.env.DISPLAY and exe('xclip') then
    provider = {
      name = 'x-clip',
      copy = { clipboard = { 'xclip', '-i', '-selection', 'clipboard' },
        selection = { 'xclip', '-i', '-selection', 'primary' } },
      paste = { clipboard = { 'xclip', '-o', '-selection', 'clipboard' },
        selection = { 'xclip', '-o', '-selection', 'primary' } },
    }
  elseif vim.env.DISPLAY and exe('xsel') then
    provider = {
      name = 'xsel',
      copy = { clipboard = { 'xsel', '-i', '-b' }, selection = { 'xsel', '-i' } },
      paste = { clipboard = { 'xsel', '-o', '-b' }, selection = { 'xsel', '-o' } },
    }
  else
    provider = { name = 'termcode', osc52 = true }
  end
  return provider
end

function M.provider_name()
  return detect().name
end

local NOT_SUPPORTED = {}

local function clip_get(kind)
  local p = detect()
  if p.osc52 then return nil, NOT_SUPPORTED end
  local cmd = p.paste[kind]
  local res = vim.system(cmd, { text = true }):wait(2000)
  if res.code ~= 0 then return nil, res.stderr end
  return res.stdout or ''
end

local function clip_set(kind, s)
  local p = detect()
  if p.osc52 then
    local ok, osc = pcall(require, 'vim.ui.clipboard.osc52')
    if ok then
      osc.copy(kind == 'clipboard' and '+' or '*')(vim.split(s, '\n', { plain = true }))
    end
    return true
  end
  local cmd = p.copy[kind]
  local ok = pcall(function()
    vim.system(cmd, { stdin = s, detach = false })
  end)
  return ok
end

local function contents_are_saved(saved, contents)
  local n = #saved
  if n == 0 then return contents == '' end
  local first = saved[n]
  if contents:sub(1, #first) ~= first then return false end
  contents = contents:sub(#first + 1)
  for i = n - 1, 1, -1 do
    local v = saved[i]
    if contents:sub(1, 1) == '\n' and contents:sub(2, 1 + #v) == v then
      contents = contents:sub(2 + #v)
    else
      return false
    end
  end
  return true
end

local function reversed(t)
  local out = {}
  for i = #t, 1, -1 do
    out[#out + 1] = t[i]
  end
  return out
end

function M.read(name)
  local E = require('hx.editor')
  if name == '_' then return {} end
  if name == '#' then
    local n = #E.sel().ranges
    local out = {}
    for i = 1, n do
      out[i] = tostring(i)
    end
    return out
  end
  if name == '.' then return E.sel():fragments(E.text()) end
  if name == '%' then return { E.display_name(E.buf()) } end
  if name == '*' or name == '+' then
    local kind = name == '+' and 'clipboard' or 'selection'
    local saved = M.inner[name]
    local contents, err = clip_get(kind)
    if contents then
      if not saved then return { contents } end
      if contents_are_saved(saved, contents) then return reversed(saved) end
      return { contents }
    elseif err == NOT_SUPPORTED then
      if saved then return reversed(saved) end
      return {}
    end
    return {}
  end
  local v = M.inner[name]
  if not v then return nil end
  return reversed(v)
end

function M.write(name, values)
  if name == '_' then return true end
  if name == '#' or name == '.' or name == '%' then
    return false, ('Register %s does not support writing'):format(name)
  end
  if name == '*' or name == '+' then
    clip_set(name == '+' and 'clipboard' or 'selection', table.concat(values, '\n'))
  end
  M.inner[name] = reversed(values)
  return true
end

function M.push(name, value)
  if name == '_' then return true end
  if name == '#' or name == '.' or name == '%' then
    return false, ('Register %s does not support pushing'):format(name)
  end
  if name == '*' or name == '+' then
    local kind = name == '+' and 'clipboard' or 'selection'
    local contents = clip_get(kind) or ''
    local saved = M.inner[name] or {}
    M.inner[name] = saved
    table.insert(saved, value)
    local v = value
    if contents ~= '' then v = v .. '\n' end
    clip_set(kind, v .. contents)
    return true
  end
  M.inner[name] = M.inner[name] or {}
  table.insert(M.inner[name], value)
  return true
end

function M.first(name)
  local v = M.read(name)
  if v and #v > 0 then return v[1] end
  return nil
end

function M.last(name)
  local v = M.read(name)
  if v and #v > 0 then return v[#v] end
  return nil
end

function M.preview()
  local out = {}
  local names = {}
  for k in pairs(M.inner) do
    if k ~= '*' and k ~= '+' then names[#names + 1] = k end
  end
  table.sort(names)
  for _, k in ipairs(names) do
    local vals = M.inner[k]
    local last = vals[#vals]
    local preview = last and (last:match('^[^\n]*')) or '<empty>'
    out[#out + 1] = { k, preview }
  end
  for _, e in ipairs({ { '_', '<empty>' }, { '#', '<selection indices>' }, { '.', '<selection contents>' },
    { '%', '<document path>' }, { '+', '<system clipboard>' }, { '*', '<primary clipboard>' } }) do
    out[#out + 1] = e
  end
  return out
end

function M.clear()
  M.inner = {}
end

function M.remove(name)
  if name == '_' or name == '#' or name == '.' or name == '%' then return false end
  local had = M.inner[name] ~= nil
  M.inner[name] = nil
  if name == '+' or name == '*' then
    clip_set(name == '+' and 'clipboard' or 'selection', '')
    return true
  end
  return had
end

return M
