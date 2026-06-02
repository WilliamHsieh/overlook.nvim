local M = {}

--- Get options for a cursor peek popup.
---@return OverlookPopupOptions? opts Table suitable for Window:open_popup, or nil on error.
function M.get()
  local buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(buf)
  if file_path == "" then
    vim.notify("Overlook: Cannot peek in unnamed buffer.", vim.log.levels.WARN)
    return nil
  end

  ---@diagnostic disable-next-line: unused-local
  local bufnum, lnum, col, _off = unpack(vim.fn.getpos("."))

  local filepath = vim.api.nvim_buf_get_name(bufnum)
  local display_path = vim.fn.fnamemodify(filepath, ":~:.") -- Title content

  return {
    title = display_path,
    target_bufnr = vim.api.nvim_get_current_buf(),
    file_path = file_path,
    lnum = lnum,
    col = col,
  }
end

return M
