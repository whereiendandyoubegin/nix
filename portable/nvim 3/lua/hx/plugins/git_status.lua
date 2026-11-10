local LB = require('hx.plugins.labelled')

local M = {}
M.GS_PICKER = 'github.com/mattwparas/helix-config/git-status-picker'

local function E()
  return require('hx.editor')
end

local function run_static(name)
  require('hx.input').exec_cmd(name, require('hx.input').new_ctx())
end

local function insert_git_status()
  run_static('select_all')
  run_static('delete_selection')
  require('hx.typed').execute_line('insert-output git status')
end

function M.create_gs_picker()
  local doc = LB.maybe_fetch_doc_id(M.GS_PICKER)
  if not doc then LB.make_new(M.GS_PICKER, 'left') end
  if not LB.doc_exists(LB.fetch_doc_id(M.GS_PICKER)) then LB.make_new(M.GS_PICKER, 'left') end
  LB.temporarily_switch_focus(function()
    LB.open(M.GS_PICKER)
    insert_git_status()
  end)
end

local function refresh_gs_picker()
  LB.temporarily_switch_focus(function()
    LB.open(M.GS_PICKER)
    insert_git_status()
  end)
  require('hx.input').after_key()
end

function M.add_modified_file()
  if not LB.currently_in(M.GS_PICKER) then return end
  run_static('extend_line_below')
  local text = E().text()
  local r = E().sel():prim()
  local line = text:slice(r:from(), r:to()):gsub('^%s+', '')
  if line:sub(1, #'modified:   ') == 'modified:   ' then
    local trimmed = line:sub(#'modified:   ' + 1):gsub('%s+$', '')
    require('hx.typed').execute_line("run-shell-command git add '" .. trimmed .. "'")
    vim.defer_fn(refresh_gs_picker, 10)
  end
end

function M.setup()
  local reg = require('hx.typed').register_plugin
  local SIG0 = 'Signature { positionals: (0, Some(0)), ..Signature::DEFAULT }'
  reg('create-gs-picker', function(_, ev)
    if ev == 'validate' then M.create_gs_picker() end
  end, 'Opens the git status picker in a fresh (or reused) buffer', SIG0)
  reg('add-modified-file', function(_, ev)
    if ev == 'validate' then M.add_modified_file() end
  end, 'If the file is "modified" - add that file to git', SIG0)
end

return M
