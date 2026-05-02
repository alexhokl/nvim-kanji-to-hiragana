vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(vim.fn.getcwd() .. "/.deps/plenary.nvim")
vim.cmd("runtime plugin/plenary.vim")
