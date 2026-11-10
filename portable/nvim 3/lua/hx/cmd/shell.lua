return function(C, H)
  local reg = C.register

  local function shell_prompt(prompt, fn)
    require('hx.ui.prompt').open({
      prompt = prompt,
      register = '|',
      completion = function(line)
        return require('hx.ui.completers').shell(line)
      end,
      callback = function(input, event)
        if event ~= 'validate' or input == '' then return end
        local T = require('hx.typed')
        local ok, args = pcall(T.parse_args, input, { signature = 'positionals: (1, Some(2)), raw_after: Some(1)' }, true)
        if not ok then
          H.error(tostring(args):gsub('^.-:%d+: ', ''))
          return
        end
        fn(table.concat(args, ' '))
      end,
    })
  end

  local function behavior(prompt, b)
    return function()
      shell_prompt(prompt, function(cmd)
        require('hx.shell').shell(cmd, b)
      end)
    end
  end
  reg('shell_pipe', behavior('pipe:', 'replace'))
  reg('shell_pipe_to', behavior('pipe-to:', 'ignore'))
  reg('shell_insert_output', behavior('insert-output:', 'insert'))
  reg('shell_append_output', behavior('append-output:', 'append'))
  reg('shell_keep_pipe', function()
    shell_prompt('keep-pipe:', function(cmd)
      require('hx.shell').keep_pipe(cmd)
    end)
  end)
  reg('suspend', function()
    vim.cmd('suspend')
  end)
end
