local M = {}

---Creates and opens a floating window viewing the target buffer.
---@param opts OverlookPopupOptions
---@return { win_id: integer, buf_id: integer } | nil
function M.create_popup(opts)
  local popup = require("overlook.popup").new(opts)
  if not popup then
    return nil
  end

  local stack = require("overlook.stack").win_get_stack(popup.orginal_win_id)
  stack:push(popup)

  return { win_id = popup.win_id, buf_id = popup.opts.target_bufnr }
end

return M
