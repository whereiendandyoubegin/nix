local S = require('hx.state')
local E = require('hx.editor')
local D = require('hx.doc')
local SL = require('hx.selection')
local U = require('hx.util')
local R = SL.R

local M = {}

function M.enter_insert_mode()
  if S.mode ~= 'insert' then
    local buf = E.buf()
    D.begin_session(buf, E.sel():copy())
    S.set_mode('insert')
  end
end

local function try_restore_indent(session)
  if not session or #session.changes ~= 1 then return end
  local cs = session.changes[1]
  local ops = cs.ops
  if #ops ~= 3 or ops[1][1] ~= 'r' or ops[2][1] ~= 'i' or ops[3][1] ~= 'r' then return end
  local move_pos, ins = ops[1][2], ops[2][2]
  local text = E.text()
  local r = E.sel():prim()
  local pos = r:cursor(text)
  local line = r:cursor_line(text)
  local line_end_pos = text:line_end(line)
  if move_pos + #ins ~= pos then return end
  if ins:sub(1, 1) ~= '\n' then return end
  for i = 2, #ins do
    local c = ins:byte(i)
    if not U.is_whitespace(c) then return end
  end
  if pos ~= line_end_pos then return end
  local ls = text:line_start(line)
  D.apply(SL.Transaction.change(text, { { ls, pos, nil } }), { win = E.win() })
end

function M.enter_normal_mode()
  if S.mode == 'normal' then return end
  local was_insert = S.mode == 'insert'
  S.set_mode('normal')
  local buf = E.buf()
  local session
  if was_insert then
    session = D.end_session(buf)
    pcall(function()
      require('hx.lsp.completion').close()
      require('hx.lsp.signature').close()
    end)
  end
  try_restore_indent(session)
  local d = S.doc(buf)
  if d.restore_cursor then
    local text = E.text()
    E.set_sel(E.sel():transform(function(r)
      local head = r:to()
      if r.head > r.anchor then head = text:prev_grapheme(head) end
      return R(r:from(), head)
    end))
    d.restore_cursor = false
  end
end

return M
