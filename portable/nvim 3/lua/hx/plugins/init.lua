local M = {}

local function load(name)
  local ok, mod = pcall(require, name)
  if not ok then
    vim.schedule(function()
      vim.notify('hx: failed to load ' .. name .. ': ' .. tostring(mod), vim.log.levels.ERROR)
    end)
    return
  end
  local ok2, err = pcall(mod.setup)
  if not ok2 then
    vim.schedule(function()
      vim.notify('hx: ' .. name .. '.setup failed: ' .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

function M.setup()
  load('hx.plugins.git_status')
  load('hx.plugins.file_tree')
  load('hx.plugins.smooth_scroll')
end

return M
