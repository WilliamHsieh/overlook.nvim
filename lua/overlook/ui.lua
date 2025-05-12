local M = {}

---Creates and opens a floating window viewing the target buffer.
---@param opts OverlookPopupOptions
---@return { win_id: integer, buf_id: integer } | nil
function M.create_popup(opts)
  local Popup = require("overlook.popup")
  local popup = Popup.new(opts)
  return popup and { win_id = popup.win_id, buf_id = popup.opts.target_bufnr }
end

return M
