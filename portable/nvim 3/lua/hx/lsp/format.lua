local api = vim.api
local S = require('hx.state')
local Text = require('hx.text')
local LU = require('hx.lsp.util')

local M = {}

local function formatting_options(buf)
  return {
    tabSize = vim.bo[buf].tabstop,
    insertSpaces = vim.bo[buf].expandtab,
  }
end

local function err(msg)
  S.set_status(msg, 'error')
  pcall(function()
    require('hx.ui.cmdline').render()
  end)
end

function M.format_buffer(buf, cb)
  local client = require('hx.lsp').with_feature(buf, 'format')[1]
  if not client then
    if cb then
      cb()
    else
      err("A formatter isn't available, and no language server provides formatting capabilities")
    end
    return
  end
  local version = api.nvim_buf_get_changedtick(buf)
  local text = Text.get(buf)
  local enc = client.offset_encoding or 'utf-16'
  local E = require('hx.editor')
  local win = E.win()
  local ok = client:request('textDocument/formatting', {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    options = formatting_options(buf),
  }, function(e, result)
    if not api.nvim_buf_is_valid(buf) then return end
    local edits = (not e and type(result) == 'table') and result or {}
    if api.nvim_buf_get_changedtick(buf) == version then
      local tx = LU.transaction_from_edits(text, edits, enc)
      local w = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf and win or nil
      if not w then
        for _, ww in ipairs(api.nvim_list_wins()) do
          if api.nvim_win_get_buf(ww) == buf then w = ww end
        end
      end
      if w then
        require('hx.doc').apply(tx, { win = w, buf = buf })
        require('hx.doc').checkpoint(buf)
      end
    end
    if cb then cb() end
    pcall(function()
      require('hx.input').after_key()
    end)
  end, buf)
  if not ok and cb then cb() end
end

function M.format_selections()
  local E = require('hx.editor')
  local buf = E.buf()
  local sel = E.sel()
  if #sel.ranges ~= 1 then
    err('format_selections only supports a single selection for now')
    return
  end
  local client
  for _, c in ipairs(require('hx.lsp').with_feature(buf, 'format')) do
    local p = c.server_capabilities.documentRangeFormattingProvider
    if p == true or type(p) == 'table' then
      client = c
      break
    end
  end
  if not client then
    err('No configured language server supports range formatting')
    return
  end
  local enc = client.offset_encoding or 'utf-16'
  local text = Text.get(buf)
  local res = client:request_sync('textDocument/rangeFormatting', {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    range = LU.range_to_lsp_range(text, sel:prim(), enc),
    options = formatting_options(buf),
  }, 5000, buf)
  local edits = (res and not res.err and type(res.result) == 'table') and res.result or {}
  require('hx.doc').apply(LU.transaction_from_edits(text, edits, enc), { win = E.win(), buf = buf })
end

return M
