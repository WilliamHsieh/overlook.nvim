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
  -- During the transition, reuse the Stack module's per-host registry so
  -- popup.lua's internal Stack.empty()/size()/top() reads see the same items
  -- this Window operates on. Task 4 collapses the Stack facade and this
  -- becomes `Stack.new()`.
  return setmetatable({ winid = winid, stack = Stack.win_get_stack(winid) }, Window)
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

---Creates and pushes a popup onto this Window's stack. Behavior matches the
---deleted ui.create_popup. The receiver `self` corresponds to the host
---window resolved by the caller (typically `Window.current()`), which is the
---same root window Popup.new derives `popup.root_winid` from.
---@param opts OverlookPopupOptions
---@return OverlookPopup?
function Window:open_popup(opts)
  local Popup = require("overlook.popup")
  local popup = Popup.new(opts)
  if not popup then
    return nil
  end
  self.stack:push(popup)
  return popup
end

---Promote the top popup to a real window via the given command (split/vsplit/tabnew/buffer).
---Behavior matches the deleted ui.promote_popup_to_window.
---@param open_command string Vim command, e.g. "split | buffer" or "buffer".
function Window:promote(open_command)
  local Popup = require("overlook.popup")
  if self.stack:empty() or not vim.w.is_overlook_popup then
    vim.notify("Overlook: No popup to promote.", vim.log.levels.INFO)
    return
  end

  local buf_id = api.nvim_get_current_buf()
  ---@diagnostic disable-next-line: unused-local
  local _bufnum, lnum, col, _off = unpack(vim.fn.getpos("."))

  self.stack:clear()

  if not buf_id or not api.nvim_buf_is_valid(buf_id) then
    vim.notify(
      string.format("Overlook Error: Buffer to promote is invalid (ID: %s).", tostring(buf_id)),
      vim.log.levels.ERROR
    )
    return
  end

  local cmd = string.format("%s %d", open_command, buf_id)
  ---@diagnostic disable-next-line: param-type-mismatch
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify(
      string.format("Overlook Error: Failed to execute command '%s': %s", cmd, tostring(err)),
      vim.log.levels.ERROR
    )
    return
  end

  Popup.set_cursor_position(0, lnum, col)
  vim.bo.buflisted = true
end

return M
