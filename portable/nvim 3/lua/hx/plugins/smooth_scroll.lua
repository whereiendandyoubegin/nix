local api = vim.api

local M = {}
local active_scroll_id = 0

local function E()
  return require('hx.editor')
end

local function run(name)
  require('hx.input').exec_cmd(name, require('hx.input').new_ctx())
end

local function at_end_of_document()
  local text = E().text()
  local cursor = E().sel():prim():cursor(text)
  return cursor >= text:len() - 1
end

local function calculate_delay(size)
  if size >= 50 then return 1 end
  if size >= 40 then return 2 end
  if size >= 30 then return 3 end
  if size >= 20 then return 4 end
  if size >= 10 then return 5 end
  return 10
end

local function calculate_step(size)
  return math.ceil(size / 20)
end

local function move_up_single()
  run('move_visual_line_up')
  run('scroll_up')
end

local function move_down_single()
  local text = E().text()
  if E().sel():prim():cursor_line(text) >= 6 then run('scroll_down') end
  run('move_visual_line_down')
end

local function start_smooth_scroll(direction, size)
  active_scroll_id = (active_scroll_id + 1) % 1000
  local my_id = active_scroll_id
  local scroll_fn = direction == 'up' and move_up_single or move_down_single
  local step = calculate_step(size)
  local delay = calculate_delay(size)
  local function loop(remaining)
    if remaining > 0 and not (direction == 'down' and at_end_of_document()) then
      for _ = 1, step do
        scroll_fn()
      end
      require('hx.input').after_key()
      vim.defer_fn(function()
        if my_id == active_scroll_id then loop(remaining - step) end
      end, delay)
    end
  end
  loop(size)
end

local function view_height()
  return api.nvim_win_get_height(E().win()) + 1 - 2
end

local function half_view_height()
  return math.ceil(view_height() / 2)
end

function M.setup()
  local reg = require('hx.typed').register_plugin
  local SIG0 = 'Signature { positionals: (0, Some(0)), ..Signature::DEFAULT }'
  reg('half-page-up-smooth', function(_, ev)
    if ev == 'validate' then start_smooth_scroll('up', half_view_height()) end
  end, '', SIG0)
  reg('half-page-down-smooth', function(_, ev)
    if ev == 'validate' then start_smooth_scroll('down', half_view_height()) end
  end, '', SIG0)
  reg('page-up-smooth', function(_, ev)
    if ev == 'validate' then start_smooth_scroll('up', view_height()) end
  end, '', SIG0)
  reg('page-down-smooth', function(_, ev)
    if ev == 'validate' then start_smooth_scroll('down', view_height()) end
  end, '', SIG0)
end

return M
