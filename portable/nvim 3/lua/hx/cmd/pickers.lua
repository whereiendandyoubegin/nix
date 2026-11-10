return function(C, H)
  local P = function() return require('hx.ui.pickers') end
  local list = {
    file_picker = 'file_picker_root', file_picker_in_current_directory = 'file_picker_cwd',
    file_picker_in_current_buffer_directory = 'file_picker_buffer_dir', file_explorer = 'file_explorer_root',
    file_explorer_in_current_buffer_directory = 'file_explorer_buffer_dir',
    file_explorer_in_current_directory = 'file_explorer_cwd', buffer_picker = 'buffer_picker',
    jumplist_picker = 'jumplist_picker', diagnostics_picker = 'diagnostics_picker',
    workspace_diagnostics_picker = 'workspace_diagnostics_picker', changed_file_picker = 'changed_file_picker',
    last_picker = 'last_picker', symbol_picker = 'symbol_picker', workspace_symbol_picker = 'workspace_symbol_picker',
    syntax_symbol_picker = 'syntax_symbol_picker', syntax_workspace_symbol_picker = 'syntax_workspace_symbol_picker',
    lsp_or_syntax_symbol_picker = 'lsp_or_syntax_symbol_picker',
    lsp_or_syntax_workspace_symbol_picker = 'lsp_or_syntax_workspace_symbol_picker',
  }
  for cmd, fn in pairs(list) do
    C.register(cmd, function(ctx) P()[fn](ctx) end)
  end
end
