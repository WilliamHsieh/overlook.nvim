local M = {}

local function setup_autocmd()
  local state = require("overlook.state")

  -- Setup Autocommands for dynamic keymap
  local augroup = vim.api.nvim_create_augroup("OverlookStateManagement", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local winid = tonumber(args.match)
      if not winid then
        return
      end
      local w = require("overlook.window").find_by_popup_winid(winid)
      if w then
        w:on_popup_closed(winid)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = augroup,
    pattern = "*",
    callback = function()
      vim.schedule(state.update_keymap)
    end,
  })

  -- Add separate BufEnter for title updates
  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = augroup,
    pattern = "*",
    callback = function()
      vim.schedule(state.update_title)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup, -- Use the same group or a new one
    pattern = "*",
    callback = function() -- args contain args.buf
      -- Defer to ensure window/buffer context is fully established
      vim.schedule(function()
        state.handle_style_for_buffer_in_window()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      state.cleanup_touched_buffer(args.buf)
    end,
  })
end

--- Initialize and configure overlook.nvim with user-provided options.
---
--- Should be called from the user's Neovim configuration, typically via
--- `require("overlook").setup(opts)`.
---
---@seealso |overlook-config.defaults|
---
---@param opts? table User configuration options (optional).
---
---@usage >lua
---   require("overlook").setup({ ui = { border = "single", row_offset = 2 } })
--- <
---@tag overlook-setup
function M.setup(opts)
  require("overlook.config").setup(opts)
  setup_autocmd()
end

return M
