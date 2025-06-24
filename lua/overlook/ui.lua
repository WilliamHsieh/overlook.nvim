local M = {}

---Creates and opens a floating window viewing the target buffer.
---@param opts OverlookPopupOptions
---@return OverlookPopup?
function M.create_popup(opts)
  local popup = require("overlook.popup").new(opts)
  if not popup then
    return nil
  end

  local stack = require("overlook.stack").win_get_stack(popup.orginal_win_id)
  stack:push(popup)

  return popup
end

return M
