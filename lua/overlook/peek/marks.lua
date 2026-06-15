local api = vim.api

--- Peek at a mark's location. Validates the mark, then opens a popup of its
--- buffer at the mark position. Notifies and returns early on any invalid /
--- unset / unloaded case (it never opens a popup in those cases).
---@param mark_char string Single-character mark name.
---@return nil
return function(mark_char)
  if not mark_char or #mark_char ~= 1 then
    vim.notify("Overlook Error: Invalid mark character provided.", vim.log.levels.ERROR)
    return
  end

  local pos = vim.fn.getpos("'" .. mark_char)
  local bufnum = pos[1]
  local lnum = pos[2]
  local col = pos[3]

  if bufnum == 0 or lnum == 0 then
    vim.notify("Overlook: Mark '" .. mark_char .. "' is not set.", vim.log.levels.INFO)
    return
  end

  if not api.nvim_buf_is_loaded(bufnum) then
    vim.notify("Overlook Info: Buffer for mark '" .. mark_char .. "' is not loaded.", vim.log.levels.INFO)
    return
  end
  if not api.nvim_buf_is_valid(bufnum) then
    vim.notify(
      "Overlook Error: Buffer for mark '" .. mark_char .. "' (" .. bufnum .. ") is invalid.",
      vim.log.levels.ERROR
    )
    return
  end

  require("overlook.window").open_popup {
    target_bufnr = bufnum,
    lnum = lnum,
    col = col,
    title = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnum), ":~:."),
  }
end
