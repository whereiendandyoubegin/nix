return function(C, H)
  local L = function() return require('hx.lsp.commands') end
  for _, name in ipairs({ 'goto_definition', 'goto_declaration', 'goto_type_definition', 'goto_implementation',
    'goto_reference', 'hover', 'rename_symbol', 'code_action', 'select_references_to_symbol_under_cursor',
    'signature_help' }) do
    C.register(name, function(ctx)
      local ok, m = pcall(L)
      if ok and m[name] then m[name](ctx) else H.error('No configured language server supports ' .. name) end
    end)
  end
end
