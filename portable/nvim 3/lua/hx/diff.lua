local api = vim.api
local M = {}

local bases = {}
local hunk_cache = {}

local function load_base(buf)
  local name = api.nvim_buf_get_name(buf)
  if name == '' then
    bases[buf] = { text = false }
    return
  end
  bases[buf] = { text = false, loading = true }
  require('hx.git').show_head(vim.fn.fnamemodify(name, ':p'), function(text)
    if not api.nvim_buf_is_valid(buf) then return end
    bases[buf] = { text = text or false }
    hunk_cache[buf] = nil
    pcall(vim.cmd, 'redraw!')
  end)
end

function M.reload(buf)
  bases[buf] = nil
  hunk_cache[buf] = nil
end

function M.hunks(buf)
  local b = bases[buf]
  if not b then
    load_base(buf)
    return nil
  end
  if not b.text then return nil end
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = hunk_cache[buf]
  if c and c.tick == tick then return c.hunks end
  local cur = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  local ok, res = pcall(vim.diff, b.text, cur, { result_type = 'indices', algorithm = 'histogram' })
  local hunks = {}
  if ok then
    for _, h in ipairs(res) do
      local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
      local bs = ca == 0 and sa or sa - 1
      local as = cb == 0 and sb or sb - 1
      hunks[#hunks + 1] = { before_start = bs, before_end = bs + ca, after_start = as, after_end = as + cb }
    end
  end
  hunk_cache[buf] = { tick = tick, hunks = hunks }
  return hunks
end

function M.hunk_at(buf, line)
  local hs = M.hunks(buf)
  if not hs then return nil end
  for _, h in ipairs(hs) do
    if h.after_start <= line and line < math.max(h.after_end, h.after_start + 1) then return h end
  end
  return nil
end

function M.base_text(buf)
  local b = bases[buf]
  return b and b.text or nil
end

return M
