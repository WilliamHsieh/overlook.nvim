local M = {}

---Closes all overlook popups gracefully using eventignore.
---@param force_close? boolean If true, uses force flag when closing windows.
function M.close_all(force_close)
  local stack = require("overlook.stack").get_current_stack()
  -- Ignore WinClosed while we manually close everything
  -- this is required to avoid window focus jumping during the process
  vim.opt.eventignore:append("WinClosed")

  -- Iterate over the copy, closing windows
  while not stack:empty() do
    local top = stack:top()
    if top and vim.api.nvim_win_is_valid(top.win_id) then
      vim.api.nvim_win_close(top.win_id, force_close or false)
    end
    stack:pop()
  end

  -- Re-enable WinClosed
  vim.opt.eventignore:remove("WinClosed")

  -- Restore focus to the original window
  pcall(vim.api.nvim_set_current_win, stack.original_win_id)

  -- Clean up the autocommand group to prevent leaks
  pcall(vim.api.nvim_clear_autocmds, { group = stack.augroup_id })
end

---Creates and opens a floating window viewing the target buffer.
---@param opts OverlookPopupOptions
---@return { win_id: integer, buf_id: integer } | nil
function M.create_popup(opts)
  local popup = require("overlook.popup").new(opts)
  if not popup then
    return nil
  end

  local stack = require("overlook.stack").win_get_stack(popup.orginal_win_id)
  stack:push {
    win_id = popup.win_id, -- required
    buf_id = popup.opts.target_bufnr,
    z_index = popup.actual_win_config.zindex,
    width = popup.actual_win_config.width,
    height = popup.actual_win_config.height,
    row = popup.actual_win_config.row,
    col = popup.actual_win_config.col,
    original_win_id = popup.orginal_win_id,
  }

  return { win_id = popup.win_id, buf_id = popup.opts.target_bufnr }
end

return M
