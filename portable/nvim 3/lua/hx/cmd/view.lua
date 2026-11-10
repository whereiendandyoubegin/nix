local api = vim.api
local S = require('hx.state')
local E = require('hx.editor')
local VU = require('hx.cmd.view_util')

return function(C, H)
  local reg = C.register

  reg('align_view_top', function() VU.align_view(H.win(), 'top') end)
  reg('align_view_center', function() VU.align_view(H.win(), 'center') end)
  reg('align_view_bottom', function() VU.align_view(H.win(), 'bottom') end)
  reg('align_view_middle', function()
    if vim.wo[H.win()].wrap then return end
    local win = H.win()
    require('hx.render').sync_cursor(win)
    api.nvim_win_call(win, function()
      vim.cmd('normal! zs')
      local w = api.nvim_win_get_width(win)
      vim.fn.winrestview({ leftcol = math.max(0, vim.fn.winsaveview().leftcol - math.floor(w / 2)) })
    end)
  end)

  reg('scroll_up', function(ctx) H.scroll(ctx, ctx:get_count(), false, false) end)
  reg('scroll_down', function(ctx) H.scroll(ctx, ctx:get_count(), true, false) end)

  local function editor_wins()
    return vim.tbl_filter(function(w)
      return api.nvim_win_get_config(w).relative == ''
    end, api.nvim_tabpage_list_wins(0))
  end

  local function focus(win)
    if win and api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
      require('hx.ui.compositor').set_editor_win(win)
    end
  end

  reg('rotate_view', function()
    local wins = editor_wins()
    local cur = H.win()
    for i, w in ipairs(wins) do
      if w == cur then
        focus(wins[(i % #wins) + 1])
        return
      end
    end
  end)
  reg('rotate_view_reverse', function()
    local wins = editor_wins()
    local cur = H.win()
    for i, w in ipairs(wins) do
      if w == cur then
        focus(wins[((i - 2) % #wins) + 1])
        return
      end
    end
  end)

  local function jump(dir)
    local cur = H.win()
    local target = api.nvim_win_call(cur, function()
      return vim.fn.win_getid(vim.fn.winnr(dir))
    end)
    if target ~= 0 and target ~= cur then focus(target) end
  end
  reg('jump_view_left', function() jump('h') end)
  reg('jump_view_right', function() jump('l') end)
  reg('jump_view_up', function() jump('k') end)
  reg('jump_view_down', function() jump('j') end)

  local function swap(dir)
    local cur = H.win()
    local target = api.nvim_win_call(cur, function()
      return vim.fn.win_getid(vim.fn.winnr(dir))
    end)
    if target == 0 or target == cur then return end
    local b1, b2 = api.nvim_win_get_buf(cur), api.nvim_win_get_buf(target)
    local v1, v2 = S.view(cur), S.view(target)
    api.nvim_win_set_buf(cur, b2)
    api.nvim_win_set_buf(target, b1)
    S.views[cur], S.views[target] = v2, v1
    focus(target)
  end
  reg('swap_view_left', function() swap('h') end)
  reg('swap_view_right', function() swap('l') end)
  reg('swap_view_up', function() swap('k') end)
  reg('swap_view_down', function() swap('j') end)

  reg('transpose_view', function()
    local cur = H.win()
    api.nvim_win_call(cur, function()
      local layout = vim.fn.winlayout()
      local function parent_kind(node, id, kind)
        if node[1] == 'leaf' then return node[2] == id and kind or nil end
        for _, child in ipairs(node[2]) do
          local r = parent_kind(child, id, node[1])
          if r then return r end
        end
      end
      local kind = parent_kind(layout, cur, nil)
      if kind == 'row' then
        vim.cmd('wincmd K')
      elseif kind == 'col' then
        vim.cmd('wincmd H')
      end
      vim.cmd('wincmd =')
    end)
  end)

  reg('hsplit', function() E.split('hsplit') end)
  reg('vsplit', function() E.split('vsplit') end)
  reg('hsplit_new', function() E.split('hsplit', E.new_scratch()) end)
  reg('vsplit_new', function() E.split('vsplit', E.new_scratch()) end)

  reg('wclose', function()
    if #editor_wins() == 1 then
      local ok, err = pcall(require('hx.typed').buffers_remaining)
      if not ok then
        H.error(tostring(err):gsub('^.-:%d+: ', ''))
        return
      end
    end
    E.close_view(H.win(), true)
  end)

  reg('wonly', function()
    local cur = H.win()
    for _, w in ipairs(editor_wins()) do
      if w ~= cur then pcall(api.nvim_win_close, w, false) end
    end
  end)
end
