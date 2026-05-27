local api = vim.api
local Stack = require("overlook.stack")

---@class OverlookWindow
---@field winid integer         -- root (host) window id
---@field stack OverlookStack
local Window = {}
Window.__index = Window

---@param winid integer
---@return OverlookWindow
function Window.new(winid)
  return setmetatable({ winid = winid, stack = Stack.new(winid) }, Window)
end

-- Module-level registry / facade
local M = {}

---@type table<integer, OverlookWindow>
M.instances = {} -- keyed by root winid; exposed for testing

---Get-or-create the Window for a given root winid.
---@param winid integer
---@return OverlookWindow
function M.get(winid)
  if not M.instances[winid] then
    M.instances[winid] = Window.new(winid)
  end
  return M.instances[winid]
end

---Resolve the Window for the current Neovim context.
---If the current window is one of our popups, use its recorded root_winid;
---otherwise use the current window itself as the root.
---@return OverlookWindow
function M.current()
  local winid
  if vim.w.is_overlook_popup then
    winid = vim.w.overlook_popup.root_winid
  else
    winid = api.nvim_get_current_win()
  end
  return M.get(winid)
end

return M
