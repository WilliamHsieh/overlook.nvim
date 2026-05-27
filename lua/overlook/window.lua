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
  return setmetatable({ winid = winid, stack = Stack.new() }, Window)
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
  local ctx = {
    root_winid = self.winid,
    prev = self.stack:top(),
    depth = self.stack:size(),
  }
  local popup = Popup.new(opts, ctx)
  if not popup then
    return nil
  end
  if not popup:open() then
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

  self:close_all()

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

---Close all popups in this Window's stack atomically.
---Suppresses WinClosed during the bulk close to prevent re-entrant reconciliation,
---then refocuses the root window.
---@param force? boolean
function Window:close_all(force)
  vim.opt.eventignore:append("WinClosed")

  while not self.stack:empty() do
    local top = self.stack:top()
    if top then
      top:close(force)
    end
    self.stack:pop()
  end

  vim.opt.eventignore:remove("WinClosed")
  pcall(api.nvim_set_current_win, self.winid)
end

---Pop popups from the top while the top popup's window is invalid.
---Used as a reconciliation safety net.
function Window:prune_invalid()
  while not self.stack:empty() do
    local top = self.stack:top()
    if top and top:is_valid() then
      return
    end
    self.stack:pop()
  end
end

---WinClosed reconciliation: a popup window is already gone; bring the stack in sync.
---Always refocuses (the closed window was typically the focused one).
---@param winid integer The closed popup's window id.
function Window:on_popup_closed(winid)
  self.stack:remove_by_winid(winid)
  self:prune_invalid()

  local top = self.stack:top()
  if top and top:is_valid() then
    top:focus()
  else
    pcall(api.nvim_set_current_win, self.winid)

    local config = require("overlook.config").get()
    if type(config.on_stack_empty) == "function" then
      local ok, err = pcall(config.on_stack_empty)
      if not ok then
        vim.notify("Overlook Error: on_stack_empty callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  vim.schedule(function()
    require("overlook.state").update_keymap()
  end)
end

---Restore the most recently closed popup.
function Window:restore()
  local Popup = require("overlook.popup")
  local data = self.stack:peek_trash()
  if not data then
    vim.notify("Overlook: No popup to restore", vim.log.levels.WARN)
    return
  end

  local ctx = {
    root_winid = self.winid,
    prev = self.stack:top(),
    depth = self.stack:size(),
  }
  local restored = Popup.new(data.opts, ctx)
  if not restored or not restored:open() then
    vim.notify("Overlook: Failed to restore popup", vim.log.levels.ERROR)
    return -- trash untouched on failure
  end

  self.stack:pop_trash()
  self.stack:restore_item(restored)
end

---Restore all previously closed popups in this Window's stack.
function Window:restore_all()
  while true do
    local before = self.stack:peek_trash()
    if not before then
      return
    end
    self:restore()
    if self.stack:peek_trash() == before then
      break -- restore failed; top of trash unchanged. stop.
    end
  end
end

---Toggle focus between the top popup and the root window.
function Window:switch_focus()
  if vim.w.is_overlook_popup then
    pcall(api.nvim_set_current_win, self.winid)
    return
  end
  local top = self.stack:top()
  if top then
    top:focus()
  else
    vim.notify("Overlook: no popup to focus", vim.log.levels.INFO)
  end
end

---@return OverlookPopup?
function Window:top()
  return self.stack:top()
end

---@return integer
function Window:size()
  return self.stack:size()
end

---@return boolean
function Window:empty()
  return self.stack:empty()
end

---Scan all hosts for a popup with this winid. Used by the WinClosed autocmd.
---Iterates every position in every stack (not just tops) because non-top popups
---can close (see spec §5).
---@param winid integer
---@return OverlookWindow?
function M.find_by_popup_winid(winid)
  for _, w in pairs(M.instances) do
    for _, item in ipairs(w.stack.items) do
      if item.winid == winid then
        return w
      end
    end
  end
  return nil
end

return M
