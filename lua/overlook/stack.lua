local api = vim.api

---@class OverlookStack
---@field root_winid integer The root window ID for this stack.
---@field augroup_id integer The ID of the autocommand group for closing popups.
---@field items OverlookPopup[] Array of popup items.
---@field trash OverlookPopup[] Array of popped items.
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
---@return OverlookPopup | nil
function Stack:top()
  if self:empty() then
    return nil
  end
  return self.items[self:size()]
end

---Pushes popup info onto the stack and stores original wid if needed.
---@param popup_info OverlookPopup
function Stack:push(popup_info)
  table.insert(self.items, popup_info)
  self.trash = {}
end

---Pushes popup info onto the stack and stores original wid if needed.
function Stack:pop()
  if not self:empty() then
    local top = table.remove(self.items, self:size())
    table.insert(self.trash, top)
    return top
  end
end


---Remove a popup's info and index in the stack by window ID.
---@param winid integer
function Stack:remove_by_winid(winid)
  for i = self:size(), 1, -1 do
    if self.items[i].winid == winid then
      table.remove(self.items, i)
      return
    end
  end
end


-- Module-level state and functions
-----------------------------------
local M = {}

---@type table<integer, OverlookStack>
M.instances = {} -- Key: root_winid, Value: Stack object

---Creates a new Stack instance.
---@param root_winid integer
---@return OverlookStack
function M.new(root_winid)
  local this = setmetatable({}, Stack)

  this.root_winid = root_winid
  -- TODO: this group is no longer needed
  this.augroup_id = api.nvim_create_augroup("OverlookPopupClose", { clear = true })
  this.items = {}
  this.trash = {}

  return this
end

---Determines the root_winid for the current context.
---@return integer
function M.get_current_root_winid()
  if vim.w.is_overlook_popup then
    return vim.w.overlook_popup.root_winid
  end
  return api.nvim_get_current_win()
end

-- assuming this is root window, not popup
function M.win_get_stack(winid)
  if not M.instances[winid] then
    M.instances[winid] = M.new(winid)
  end
  return M.instances[winid]
end

function M.get_current_stack()
  local winid = M.get_current_root_winid()
  return M.win_get_stack(winid)
end

---@param popup_info OverlookPopup
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

return M
