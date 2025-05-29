local api = vim.api

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

---Pushes popup info onto the stack and stores original wid if needed.
function Stack:pop()
  if not self:empty() then
    table.remove(self.items, self:size())
  end
end

function Stack:clear()
  self.items = {}
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
    self:pop()
  end
end

-- Module-level state and functions
-----------------------------------
local M = {}

---@type table<integer, OverlookStack>
M.stack_instances = {} -- Key: original_win_id, Value: Stack object

---Creates a new Stack instance.
---@param original_win_id integer
---@return OverlookStack
function M.new(original_win_id)
  local this = setmetatable({}, Stack)

  this.original_win_id = original_win_id
  this.augroup_id = api.nvim_create_augroup("OverlookPopupClose", { clear = true })
  this.items = {}

  return this
end

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

function M.clear()
  local stack = M.get_current_stack()
  return stack:clear()
end

return M
