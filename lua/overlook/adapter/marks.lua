local api = vim.api
local M = {}

---Gets the options required for the peek popup for a specific mark.
---Returns nil if the mark is invalid or an error occurs.
---@param mark_char string
---@return OverlookPopupOptions? opts Table suitable for Window:open_popup, or nil on error.
function M.get(mark_char)
  -- Input validation
  if not mark_char or #mark_char ~= 1 then
    vim.notify("Overlook Error: Invalid mark character provided.", vim.log.levels.ERROR)
    return nil -- Return nil on invalid input
  end

  local pos = vim.fn.getpos("'" .. mark_char)

  local bufnum = pos[1]
  local lnum = pos[2]
  local col = pos[3]

  if bufnum == 0 or lnum == 0 then
    vim.notify("Overlook: Mark '" .. mark_char .. "' is not set.", vim.log.levels.INFO)
    return nil -- Return nil if mark not set
  end

  -- Basic validation checks
  if not api.nvim_buf_is_loaded(bufnum) then
    -- Consider adding an option to load the buffer if desired.
    vim.notify("Overlook Info: Buffer for mark '" .. mark_char .. "' is not loaded.", vim.log.levels.INFO)
    return nil
  end
  if not api.nvim_buf_is_valid(bufnum) then
    vim.notify(
      "Overlook Error: Buffer for mark '" .. mark_char .. "' (" .. bufnum .. ") is invalid.",
      vim.log.levels.ERROR
    )
    return nil -- Return nil if buffer invalid
  end

  local filepath = api.nvim_buf_get_name(bufnum)
  local display_path = vim.fn.fnamemodify(filepath, ":~:.") -- Title content

  -- Return the options table for the popup
  return {
    target_bufnr = bufnum,
    lnum = lnum,
    col = col,
    title = display_path,
    -- Add any other mark-specific options here if needed in the future
  }
end

return M
