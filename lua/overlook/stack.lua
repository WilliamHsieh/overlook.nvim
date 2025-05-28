local api = vim.api

local M = {}

---@class OverlookStackItem
---@field win_id integer Window ID of the popup
---@field buf_id integer Buffer ID of the *target* buffer shown in the popup
---@field z_index integer Z-index of the window
---@field width integer
---@field height integer
---@field row integer     -- Absolute screen row (1-based)
---@field col integer     -- Absolute screen col (1-based)
---@field original_win_id integer? -- Original window ID (if applicable)

---@class OverlookStack
---@field original_win_id integer The root original window ID for this stack.
---@field augroup_id integer The ID of the autocommand group for closing popups.
---@field items OverlookStackItem[] Array of popup items.
local Stack = {}
Stack.__index = Stack

---Creates a new Stack instance.
---@param original_win_id integer
---@return OverlookStack
function M.new(original_win_id)
  return setmetatable({
    original_win_id = original_win_id,
    augroup_id = api.nvim_create_augroup("OverlookPopupClose", { clear = true }),
    items = {},
  }, Stack)
end

---Returns the current size of the stack.
---@return integer
function Stack:size()
  return #self.items
end

---Returns true if the stack is empty, false otherwise.
---@return boolean
function Stack:empty()
  return self:size() == 0
end

---Returns the info for the top popup without removing it.
---@return OverlookStackItem | nil
function Stack:top()
  if self:empty() then
    return nil
  end
  return self.items[self:size()]
end

---Pushes popup info onto the stack and stores original wid if needed.
---@param popup_info OverlookStackItem
function Stack:push(popup_info)
  table.insert(self.items, popup_info)
end

---Remove a popup's info and index in the stack by window ID.
---@param win_id integer
function Stack:remove_by_winid(win_id)
  for i = self:size(), 1, -1 do
    if self.items[i].win_id == win_id then
      table.remove(self.items, i)
      return
    end
  end
end

---Remove invalid windows from the stack until top window is valid.
function Stack:remove_invalid_windows()
  while not self:empty() do
    local top = self:top()
    if top and api.nvim_win_is_valid(top.win_id) then
      return
    end

    -- Remove the invalid top window
    table.remove(self.items, self:size())
  end
end

---Handles cleanup and focus when an overlook popup WINDOW is closed.
--- Triggered by WinClosed autocommand (via ui.lua).
---@param closed_win_id integer
function M.handle_win_close(closed_win_id)
  local stack = M.get_current_stack()
  stack:remove_by_winid(closed_win_id)
  stack:remove_invalid_windows()

  -- Determine the window to focus next
  if not stack:empty() then
    pcall(api.nvim_set_current_win, stack:top().win_id)
  else
    pcall(api.nvim_set_current_win, stack.original_win_id)

    -- Call the on_stack_empty hook if defined
    local config_mod = require("overlook.config")
    if config_mod and config_mod.options and type(config_mod.options.on_stack_empty) == "function" then
      -- Use pcall to prevent user errors in hook from breaking the plugin
      local ok, err = pcall(config_mod.options.on_stack_empty)
      if not ok then
        vim.notify("Overlook Error: on_stack_empty callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  -- Explicitly update the keymap state after handling window close and focus change
  -- Use vim.schedule to ensure this runs after Neovim has processed the focus change
  vim.schedule(function()
    require("overlook.state").update_keymap()
  end)
end

-- clear() - Modified to use eventignore
--- Closes all overlook popups gracefully using eventignore.
---@param force_close? boolean If true, uses force flag when closing windows.
function Stack:clear(force_close)
  -- Ignore WinClosed while we manually close everything
  vim.opt.eventignore:append("WinClosed")

  -- Iterate over the copy, closing windows
  for i = #self.items, 1, -1 do
    local popup_info = self.items[i]
    if popup_info then
      pcall(api.nvim_win_close, popup_info.win_id, force_close or false)
    end
  end

  -- Re-enable WinClosed
  vim.opt.eventignore:remove("WinClosed")

  -- Clear the stack state AFTER closing windows and restoring focus
  self.items = {}

  -- Explicitly restore focus to the original window *after* all popups are closed.
  if self.original_win_id and api.nvim_win_is_valid(self.original_win_id) then
    pcall(api.nvim_set_current_win, self.original_win_id)
  else
    -- Do not fallback if original_win_to_restore was nil initially.
    if self.original_win_id then
      local wins = api.nvim_list_wins()
      if wins and #wins > 0 then
        local target_win = wins[1]
        if api.nvim_win_is_valid(target_win) then
          pcall(api.nvim_set_current_win, target_win)
        end
      end
    end
  end

  -- Clean up the autocommand group to prevent leaks
  pcall(api.nvim_clear_autocmds, { group = self.augroup_id })

  -- Explicitly update the keymap state after closing all windows and restoring focus
  -- Use vim.schedule to ensure this runs after Neovim has processed the focus change
  vim.schedule(function()
    require("overlook.state").update_keymap()
  end)
end

-- Module-level state and functions
-----------------------------------

---@type table<integer, OverlookStack>
M.stack_instances = {} -- Key: original_win_id, Value: Stack object

---Determines the original_win_id for the current context.
---@return integer
function M.get_current_original_win_id()
  if vim.w.is_overlook_popup then
    return vim.w.overlook_popup.original_win_id
  end
  return api.nvim_get_current_win()
end

-- assuming this is original window, not popup
-- TODO: should come up with a name for original window, host window?
function M.win_get_stack(win_id)
  if not M.stack_instances[win_id] then
    M.stack_instances[win_id] = M.new(win_id)
  end
  return M.stack_instances[win_id]
end

function M.get_current_stack()
  local win_id = M.get_current_original_win_id()
  return M.win_get_stack(win_id)
end

---@param popup_info OverlookStackItem
function M.push(popup_info)
  local stack = M.get_current_stack()
  return stack:push(popup_info)
end

function M.top()
  local stack = M.get_current_stack()
  return stack:top()
end

function M.size()
  local stack = M.get_current_stack()
  return stack:size()
end

function M.empty()
  local stack = M.get_current_stack()
  return stack:empty()
end

---@param force_close? boolean If true, uses force flag when closing windows.
function M.clear(force_close)
  local stack = M.get_current_stack()
  return stack:clear(force_close)
end

return M
