local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
vim.opt.runtimepath:prepend(root)
vim.loader.enable()
require('hx').setup()
