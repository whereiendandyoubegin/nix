local S = require('hx.state')
local T = require('hx.theme')
local U = require('hx.util')
local C = require('hx.ui.compositor')

local M = {}
local ID = 'signature-help'
local TIMEOUT = 120

local Sig = {}
Sig.__index = Sig

local function new_contents(language, active_signature, lsp_signature, signatures)
  return setmetatable({
    language = language,
    active_signature = active_signature,
    lsp_signature = lsp_signature,
    signatures = signatures,
  }, Sig)
end

function Sig:signature_index()
  return ('(%d/%d)'):format(self.active_signature + 1, #self.signatures)
end

function Sig:current()
  return self.signatures[self.active_signature + 1] or self.signatures[1]
end

function Sig:handle_key(key)
  if #self.signatures <= 1 then return 'ignored' end
  if key == 'A-p' then
    self.active_signature = self.active_signature > 0 and self.active_signature - 1 or #self.signatures - 1
    return 'consumed'
  elseif key == 'A-n' then
    self.active_signature = (self.active_signature + 1) % #self.signatures
    return 'consumed'
  end
  return 'ignored'
end

local function styled_multiline(text, style)
  local out = {}
  for _, l in ipairs(U.split_lines(text)) do
    out[#out + 1] = { { l, style } }
  end
  if #out == 0 then out[1] = { { '', style } } end
  return out
end

local function highlighted_code_block(text, language, themed, overlay)
  local text_style = themed and T.get('ui.text') or {}
  local code_style = themed and T.get('markup.raw.inline') or {}
  if not themed then return styled_multiline(text, code_style) end
  local lines = require('hx.ui.markdown').highlight_code(text, language, text_style)
  if not lines then return styled_multiline(text, code_style) end
  if not overlay then return lines end
  local os_, oe, ostyle = overlay[1], overlay[2], overlay[3]
  local pos = 0
  local out = {}
  for _, line in ipairs(lines) do
    local nl = {}
    for _, sp in ipairs(line) do
      local s = sp[1]
      local a, b = pos, pos + #s
      if b <= os_ or a >= oe then
        nl[#nl + 1] = sp
      else
        local cut1 = math.max(os_, a) - a
        local cut2 = math.min(oe, b) - a
        if cut1 > 0 then nl[#nl + 1] = { s:sub(1, cut1), sp[2] } end
        nl[#nl + 1] = { s:sub(cut1 + 1, cut2), T.patch(sp[2] or {}, ostyle) }
        if cut2 < #s then nl[#nl + 1] = { s:sub(cut2 + 1), sp[2] } end
      end
      pos = b
    end
    pos = pos + 1
    out[#out + 1] = nl
  end
  return out
end

local function paragraph_size(lines, max_w)
  local Tx = require('hx.ui.text')
  local wrapped = Tx.word_wrap(lines, max_w, false)
  local w = 0
  for _, l in ipairs(wrapped) do
    w = math.max(w, Tx.line_width(l))
  end
  return w, #wrapped, wrapped
end

function Sig:required_size(vw, _)
  local PADDING, SEPARATOR_HEIGHT = 2, 1
  local sig = self:current()
  local max_text_width = math.min(math.max(vw - PADDING, 10), 120)
  local sig_text = highlighted_code_block(sig.signature, self.language, false, nil)
  local sig_w, sig_h = paragraph_size(sig_text, max_text_width)
  local width, height
  if sig.signature_doc then
    local Md = require('hx.ui.markdown')
    local doc_text = Md.parse(sig.signature_doc, false)
    local doc_w, doc_h = require('hx.ui.text').required_size(doc_text, max_text_width)
    width, height = math.max(sig_w, doc_w), sig_h + SEPARATOR_HEIGHT + doc_h
  else
    width, height = sig_w, sig_h
  end
  local idx_w = #self.signatures > 1 and (#self:signature_index() + 1) or 0
  return width + PADDING + idx_w, height + PADDING
end

function Sig:render(c, x, y, w, h, scroll)
  x, y, w, h = x + 1, y + 1, math.max(0, w - 2), math.max(0, h - 2)
  if w <= 0 or h <= 0 then return end
  local sig = self:current()
  local overlay
  if sig.active_param_range then
    local hl = T.get_exact('ui.selection')
    if hl then overlay = { sig.active_param_range[1], sig.active_param_range[2], hl } end
  end
  local sig_text = highlighted_code_block(sig.signature, self.language, true, overlay)
  local base_g = T.group_for(T.get('ui.popup'))
  if #self.signatures > 1 then
    local idx = self:signature_index()
    local aw = math.max(0, w - 1)
    local iw = vim.api.nvim_strwidth(idx)
    c:put(x + math.max(0, aw - iw), y, idx, nil, aw)
  end
  local Tx = require('hx.ui.text')
  local _, sig_h, wrapped = paragraph_size(sig_text, w)
  local sh = math.min(sig_h, h)
  scroll = scroll or 0
  for row = 1, sh do
    local wl = wrapped[row + scroll]
    if not wl then break end
    local cx = x
    for _, s in ipairs(wl) do
      cx = c:put(cx, y + row - 1, s[1], s[2] and T.group_for(s[2]) or base_g)
    end
  end
  if not sig.signature_doc then return end
  if y + sh < c.h then
    for xx = x, x + w - 1 do
      c:put(xx, y + sh, '─', T.group_for({}))
    end
  end
  local Md = require('hx.ui.markdown')
  local doc = Md.parse(sig.signature_doc, true)
  local border = S.config.editor['popup-border']
  local bottom = (border == 'all' or border == 'popup') and 1 or 0
  local dy = y + sh + 2
  local dh = math.max(0, h - (sh + 2) - bottom)
  if dh > 0 then Tx.render(c, x, dy, w, dh, doc, scroll, base_g) end
end

local H = { trigger = nil, state = 'closed', gen = 0, running = false, timer = nil, req = nil }

local function cancel_task()
  H.gen = H.gen + 1
  H.running = false
  if H.req then
    pcall(function()
      H.req.client:cancel_request(H.req.id)
    end)
    H.req = nil
  end
end

local request_signature_help

local function finish_debounce()
  local invocation = H.trigger
  H.trigger = nil
  if not invocation then return end
  H.state = 'pending'
  cancel_task()
  H.running = true
  local gen = H.gen
  vim.schedule(function()
    request_signature_help(invocation, gen)
  end)
end

local function set_timer(ms)
  if not H.timer then H.timer = vim.uv.new_timer() end
  H.timer:stop()
  H.timer:start(ms, 0, vim.schedule_wrap(finish_debounce))
end

local function stop_timer()
  if H.timer then H.timer:stop() end
end

function M.event(ev)
  if ev == 'invoked' then
    H.trigger = 'manual'
    H.state = 'closed'
    stop_timer()
    finish_debounce()
    return
  elseif ev == 'trigger' then
  elseif ev == 'retrigger' then
    if H.state == 'closed' then return end
  elseif ev == 'cancel' then
    H.state = 'closed'
    stop_timer()
    return
  elseif type(ev) == 'table' and ev.request_complete ~= nil then
    if H.state == 'pending' and H.running then return end
    H.state = ev.request_complete and 'open' or 'closed'
    cancel_task()
    return
  end
  if not H.trigger then H.trigger = 'automatic' end
  set_timer(TIMEOUT)
end

local function active_param_range(sig, response_active)
  local idx = sig.activeParameter
  if idx == nil or idx == vim.NIL then idx = response_active end
  if idx == nil or idx == vim.NIL then idx = 0 end
  local params = sig.parameters
  if type(params) ~= 'table' then return nil end
  local p = params[idx + 1]
  if not p then return nil end
  local label = p.label
  if type(label) == 'string' then
    local s = sig.label:find(label, 1, true)
    if not s then return nil end
    return { s - 1, s - 1 + #label }
  elseif type(label) == 'table' then
    local function c2b(ci)
      local ok, b = pcall(vim.str_byteindex, sig.label, 'utf-32', ci, false)
      return ok and b or #sig.label
    end
    return { c2b(label[1]), c2b(label[2]) }
  end
end

local function popup()
  return C.find(ID)
end

local function show_signature_help(invoked, response)
  local cfg = S.config.editor
  if not (cfg.lsp['auto-signature-help'] or popup() or invoked == 'manual') then return end
  if invoked == 'automatic' and S.mode ~= 'insert' then return end
  if not response or type(response.signatures) ~= 'table' or #response.signatures == 0 then
    M.event({ request_complete = false })
    C.remove(ID)
    return
  end
  M.event({ request_complete = true })
  local E = require('hx.editor')
  local language = E.language(E.buf()) or ''
  local signatures = {}
  for _, s in ipairs(response.signatures) do
    local doc
    if cfg.lsp['display-signature-help-docs'] and s.documentation and s.documentation ~= vim.NIL then
      doc = type(s.documentation) == 'string' and s.documentation or s.documentation.value
    end
    signatures[#signatures + 1] = {
      signature = s.label,
      signature_doc = doc,
      active_param_range = active_param_range(s, response.activeParameter),
    }
  end
  local old = popup()
  local lsp_signature = response.activeSignature
  if lsp_signature == vim.NIL then lsp_signature = nil end
  local active
  if old then
    local old_lsp = old.contents.lsp_signature
    local old_sig = math.min(old.contents.active_signature, #signatures - 1)
    if old_lsp ~= lsp_signature then
      active = lsp_signature or old_sig
    else
      active = old_sig
    end
  else
    active = lsp_signature or 0
  end
  local contents = new_contents(language, active, lsp_signature, signatures)
  local Popup = require('hx.ui.popup').Popup
  local p = Popup.new(ID, contents, {
    position = old and old.position or nil,
    bias = 'above',
    ignore_escape_key = true,
  })
  local comp = require('hx.lsp.completion').completion
  if comp then
    local ca = comp:area()
    local pa = p:render_info()
    if require('hx.lsp.completion').intersects(ca, pa) then return end
  end
  C.push(p)
  pcall(vim.cmd, 'redraw')
end

request_signature_help = function(invoked, gen)
  local E = require('hx.editor')
  local Lsp = require('hx.lsp')
  local buf = E.buf()
  local clients = Lsp.with_feature(buf, 'signature_help')
  local client = clients[1]
  if not client then
    H.running = false
    if invoked == 'manual' then
      S.set_status('No configured language server supports signature-help', 'error')
      require('hx.ui.cmdline').render()
    end
    return
  end
  local text = require('hx.text').get(buf)
  local cursor = E.sel():prim():cursor(text)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = require('hx.lsp.util').pos_to_lsp_pos(text, cursor, client.offset_encoding or 'utf-16'),
  }
  local ok, id = client:request('textDocument/signatureHelp', params, function(err, result)
    if gen ~= H.gen then return end
    H.req = nil
    H.running = false
    if err then return end
    show_signature_help(invoked, result)
  end, buf)
  if ok then
    H.req = { client = client, id = id }
  else
    H.running = false
  end
end

function M.trigger(invoked)
  if invoked == 'manual' then
    M.event('invoked')
  elseif S.config.editor.lsp['auto-signature-help'] then
    M.event('trigger')
  end
end

function M.trigger_manual()
  M.event('invoked')
end

function M.mode_switch(old, new, ctx)
  if old == 'insert' then
    M.event('cancel')
    local fn = function()
      C.remove(ID)
    end
    if ctx then ctx:push_callback(fn) else fn() end
  elseif new == 'insert' and S.config.editor.lsp['auto-signature-help'] then
    M.event('trigger')
  end
end

function M.on_insert_char(_, _)
  if not S.config.editor.lsp['auto-signature-help'] then return end
  local E = require('hx.editor')
  local buf = E.buf()
  local client = require('hx.lsp').with_feature(buf, 'signature_help')[1]
  if not client then return end
  local sp = client.server_capabilities.signatureHelpProvider
  local triggers = type(sp) == 'table' and sp.triggerCharacters or nil
  if type(triggers) ~= 'table' then return end
  local text = require('hx.text').get(buf)
  local cursor = E.sel():prim():cursor(text)
  local before = text:slice(math.max(0, cursor - 32), cursor)
  for _, t in ipairs(triggers) do
    if t ~= '' and before:sub(-#t) == t then
      M.event('trigger')
      return
    end
  end
end

function M.retrigger()
  if S.config.editor.lsp['auto-signature-help'] then M.event('retrigger') end
end

function M.area()
  local p = popup()
  if not p then return nil end
  return p:render_info()
end

function M.close_popup()
  C.remove(ID)
end

function M.close()
  C.remove(ID)
end

function M.active()
  return popup() ~= nil
end

return M
