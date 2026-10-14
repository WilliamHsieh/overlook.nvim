vim.opt.runtimepath:prepend(".deps/plenary.nvim")
vim.opt.runtimepath:prepend(".")

vim.opt.compatible = false
vim.opt.termguicolors = true

-- Plenary runs spec files as parallel headless Nvim processes. The first edit
-- of a named buffer creates stdpath("state") .. "/swap". On Neovim nightly
-- those mkdirs race: the loser raises E303 ("file already exists") and aborts
-- the Lua call. Tests do not use swap files.
vim.opt.swapfile = false

vim.cmd.runtime { "plugin/plenary.vim", bang = true }

require("overlook").setup()
