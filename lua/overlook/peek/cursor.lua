--- Peek at the current cursor position: opens a popup of the current buffer
--- anchored at the cursor. A peek source is just a function that builds
--- OverlookPopupOptions and hands them to the window layer.
---@return nil
return function()
  local file_path = vim.api.nvim_buf_get_name(0)
  if file_path == "" then
    vim.notify("Overlook: Cannot peek in unnamed buffer.", vim.log.levels.WARN)
    return
  end

  ---@diagnostic disable-next-line: unused-local
  local _bufnum, lnum, col, _off = unpack(vim.fn.getpos("."))

  require("overlook.window").open_popup {
    title = vim.fn.fnamemodify(file_path, ":~:."),
    target_bufnr = vim.api.nvim_get_current_buf(),
    lnum = lnum,
    col = col,
  }
end
