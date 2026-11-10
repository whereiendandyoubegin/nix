local api = vim.api
local S = require('hx.state')
local E = require('hx.editor')
local D = require('hx.doc')
local SL = require('hx.selection')
local U = require('hx.util')

local M = {}

local function argv_for(cmd)
  local argv = { unpack(S.config.editor.shell) }
  argv[#argv + 1] = cmd
  return argv
end
M.argv_for = argv_for

function M.shell_impl(cmd, input)
  local ok, res = pcall(function()
    return vim.system(argv_for(cmd), { text = true, stdin = input, cwd = vim.fn.getcwd() }):wait()
  end)
  if not ok then return nil, tostring(res) end
  local stdout, stderr = res.stdout or '', res.stderr or ''
  if res.code ~= 0 then
    if stderr == '' then return nil, ('Shell command failed: status %d'):format(res.code) end
    return stderr
  end
  if stderr ~= '' then return stderr end
  return stdout
end

function M.shell(cmd, behavior)
  local pipe = behavior == 'replace' or behavior == 'ignore'
  local text = E.text()
  local sel = E.sel()
  local changes, ranges = {}, {}
  local shell_output
  local offset = 0
  for i, r in ipairs(sel.ranges) do
    local output
    if shell_output then
      output = shell_output
    else
      local input = r:fragment(text)
      local out, err = M.shell_impl(cmd, pipe and input or nil)
      if not out then
        S.set_status(err, 'error')
        return
      end
      if input:sub(-1) ~= '\n' and out:sub(-1) == '\n' then
        out = out:sub(1, -2)
        if out:sub(-1) == '\r' then out = out:sub(1, -2) end
      end
      if not pipe then shell_output = out end
      output = out
    end
    local from, to, deleted
    if behavior == 'replace' then
      from, to, deleted = r:from(), r:to(), r:len()
    elseif behavior == 'insert' then
      from, to, deleted = r:from(), r:from(), 0
    elseif behavior == 'append' then
      from, to, deleted = r:to(), r:to(), 0
    else
      from, to, deleted = r:from(), r:from(), 0
    end
    local anchor = to + offset - deleted
    ranges[i] = SL.R(anchor, anchor + #output):with_direction(r:forward())
    offset = offset + #output - deleted
    changes[i] = { from, to, output }
  end
  if behavior ~= 'ignore' then
    local tx = SL.Transaction.change(text, changes):with_selection(SL.Selection.new(ranges, sel.primary))
    D.apply(tx, { win = E.win() })
  end
end

function M.keep_pipe(cmd)
  local text = E.text()
  local sel = E.sel()
  local ranges = {}
  local old = sel.primary
  local index
  for i, r in ipairs(sel.ranges) do
    local res = vim.system(argv_for(cmd), { text = true, stdin = r:fragment(text) }):wait()
    if res.code == 0 then
      ranges[#ranges + 1] = r
      if i >= old and not index then index = #ranges end
    end
  end
  if #ranges == 0 then
    S.set_status('No selections remaining', 'error')
    return
  end
  E.set_sel(SL.Selection.new(ranges, index or #ranges))
end

function M.run_shell_command(cmd)
  local argv = argv_for(cmd)
  local ok = pcall(vim.system, argv, { text = true, cwd = vim.fn.getcwd() }, function(res)
    vim.schedule(function()
      local out
      if res.code ~= 0 then
        if (res.stderr or '') == '' then
          S.set_status(('Shell command failed: status %d'):format(res.code), 'error')
          require('hx.input').after_key()
          return
        end
        out = res.stderr
      elseif (res.stderr or '') ~= '' then
        out = res.stderr
      else
        out = res.stdout or ''
      end
      if U.trim(out) ~= '' then
        local Popup = require('hx.ui.popup')
        local row = require('hx.ui.popup').cursor_screen_row()
        Popup.markdown('shell', '```sh\n' .. out:gsub('%s+$', '') .. '\n```', { row = row, col = 2 })
      end
      S.set_status('Command run')
      require('hx.input').after_key()
    end)
  end)
  if not ok then S.set_status('Failed to start shell', 'error') end
end

return M
