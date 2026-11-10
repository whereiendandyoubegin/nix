local S = require('hx.state')
local E = require('hx.editor')
local D = require('hx.doc')

local C = {}
local impl = {}
C.impl = impl

local H = {}
C.H = H

function H.win()
  return E.win()
end
function H.buf()
  return E.buf()
end
function H.text()
  return E.text()
end
function H.sel()
  return E.sel()
end
function H.set_sel(sel)
  E.set_sel(sel)
end
function H.apply(tx, opts)
  opts = opts or {}
  opts.win = opts.win or E.win()
  return D.apply(tx, opts)
end
function H.mode()
  return S.mode
end
function H.extend()
  return S.mode == 'select'
end
function H.status(msg)
  S.set_status(msg, 'info')
end
function H.error(msg)
  S.set_status(msg, 'error')
end
function H.exit_select_mode()
  if S.mode == 'select' then S.set_mode('normal') end
end
function H.push_jump()
  D.push_jump(E.win(), E.buf())
end
function H.apply_motion(fn)
  fn()
  S.last_motion = fn
end
function H.config()
  return S.config
end
function H.indent_unit(buf)
  buf = buf or E.buf()
  if vim.bo[buf].expandtab then return string.rep(' ', vim.bo[buf].shiftwidth > 0 and vim.bo[buf].shiftwidth or vim.bo[buf].tabstop) end
  return '\t'
end
function H.indent_width(buf)
  buf = buf or E.buf()
  if vim.bo[buf].expandtab then
    return vim.bo[buf].shiftwidth > 0 and vim.bo[buf].shiftwidth or vim.bo[buf].tabstop
  end
  return vim.bo[buf].tabstop
end
function H.tab_width(buf)
  return vim.bo[buf or E.buf()].tabstop
end

function C.register(name, fn)
  impl[name] = fn
end

local loaded = false
local function load()
  if loaded then return end
  loaded = true
  for _, m in ipairs({ 'motion', 'select', 'edit', 'insert', 'search', 'view', 'textobj', 'shell', 'misc',
    'pickers', 'lsp' }) do
    local ok, mod = pcall(require, 'hx.cmd.' .. m)
    if ok then
      mod(C, H)
    else
      vim.schedule(function()
        vim.notify('hx: failed to load hx.cmd.' .. m .. ': ' .. tostring(mod), vim.log.levels.ERROR)
      end)
    end
  end
end
C.load = load

function C.exists(name)
  load()
  return impl[name] ~= nil
end

function C.run(name, ctx)
  load()
  local f = impl[name]
  if not f then
    if name ~= 'no_op' then H.error('No command named \'' .. name .. '\'') end
    return
  end
  f(ctx or require('hx.input').new_ctx())
end

function C.insert_char(ctx, ch)
  load()
  impl._insert_char(ctx, ch)
end

function C.paste_bracketed_value(ctx, s)
  load()
  impl._paste_bracketed_value(ctx, s)
end

return C
