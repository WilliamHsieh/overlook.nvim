local M = {}

---Creates and opens a floating window viewing the target buffer.
---@param opts OverlookPopupOptions
---@return { win_id: integer, buf_id: integer } | nil
function M.create_popup(opts)
  local Popup = require("overlook.popup")
  local popup = Popup.new(opts)
  if not popup then
    return nil
  end

  local Stack = require("overlook.stack")
  Stack.push {
    win_id = popup.win_id,
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
