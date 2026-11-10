local M = {}

local function guard(f, ...)
  local ok, err = pcall(f, ...)
  if not ok then
    vim.schedule(function()
      vim.notify('hx: ' .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

function M.post_insert_char(ch, ctx)
  guard(function()
    require('hx.lsp.completion').on_insert_char(ch, ctx)
  end)
  guard(function()
    require('hx.lsp.signature').on_insert_char(ch, ctx)
  end)
end

function M.post_command(name, ctx)
  guard(function()
    require('hx.lsp.completion').post_command(name, ctx)
  end)
end

function M.mode_switch(old, new, ctx)
  guard(function()
    require('hx.lsp.completion').mode_switch(old, new, ctx)
  end)
  guard(function()
    require('hx.lsp.signature').mode_switch(old, new, ctx)
  end)
end

local last_state = {}
local function check_doc_selection()
  local E = require('hx.editor')
  local win, buf = E.win(), E.buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local sel = require('hx.state').get_sel(win, buf)
  local key = vim.inspect(sel.ranges) .. sel.primary
  if last_state.buf == buf and (last_state.tick ~= tick or last_state.sel ~= key) then
    if not require('hx.lsp.completion').ghost_seen then
      require('hx.lsp.signature').retrigger()
    end
  end
  last_state = { buf = buf, tick = tick, sel = key }
end

function M.post_key()
  local E = require('hx.editor')
  pcall(check_doc_selection)
  pcall(require('hx.ui.gutter').update_phantom, E.win())
  pcall(function()
    require('hx.lsp.diagnostics').on_cursor_moved()
  end)
  pcall(function()
    require('hx.lsp.inlay').on_key()
  end)
end

function M.doc_opened(buf)
  pcall(function()
    require('hx.lsp').doc_opened(buf)
  end)
end

return M
