local Peek = require("overlook.peek")
local Stack = require("overlook.stack")

local M = {}

M.peek = {}

M.peek.definition = function()
  Peek.definition()
end

M.peek.cursor = function()
  Peek.cursor()
end

M.peek.mark = function()
  Peek.marks()
  vim.ui.input({ prompt = "Overlook Mark:" }, function(input)
    if input == nil or input == "" then
      return
    end

    if #input == 1 then
      Peek.marks(input)
    else
      vim.notify("Overlook Error: Invalid mark. Please enter a single character.", vim.log.levels.ERROR)
    end
  end)
end

M.close_all = function()
  require("overlook.window").close_all()
end

--- Promotes the top Overlook popup to a regular window (split, vsplit, or tab).
--- @param open_command string Command to run when promoting the popup to a window.
local function promote_popup_to_window(open_command)
  if Stack.empty() or not vim.w.is_overlook_popup then
    vim.notify("Overlook: No popup to promote.", vim.log.levels.INFO)
    return
  end

  local buf_id_to_open = vim.api.nvim_get_current_buf()

  -- Close all overlook popups. This also clears the stack.
  Stack.clear()

  -- Ensure the buffer is still valid and positive before trying to open it
  if not buf_id_to_open or not vim.api.nvim_buf_is_valid(buf_id_to_open) then
    vim.notify(
      string.format("Overlook Error: Buffer to promote is invalid (ID: %s).", tostring(buf_id_to_open)),
      vim.log.levels.ERROR
    )
    return
  end

  -- Open the buffer in the specified way
  local cmd = string.format("%s %d", open_command, buf_id_to_open)
  ---@diagnostic disable-next-line: param-type-mismatch
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify(
      string.format("Overlook Error: Failed to execute command '%s': %s", cmd, tostring(err)),
      vim.log.levels.ERROR
    )
    return -- Ensure we don't proceed if window creation failed
  end
end

--- Promotes the top Overlook popup to a regular window (split, vsplit, or tab).
--- @param open_command string Vim command to open the window (e.g., "vsplit", "split", "tabnew").
M.promote_top_to_window = function(open_command)
  local cmd = string.format("%s | buffer", open_command)
  promote_popup_to_window(cmd)
end

--- Promotes the top Overlook popup to the original window.
M.promote_top_to_original_window = function()
  promote_popup_to_window("buffer")
end

return M
