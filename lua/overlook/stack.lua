---@class OverlookStack
---@field items OverlookPopup[]   -- bottom -> top
---@field trash OverlookPopup[]   -- closed popups available for restore, oldest -> newest
local Stack = {}
Stack.__index = Stack

---@return OverlookStack
function Stack.new()
  return setmetatable({ items = {}, trash = {} }, Stack)
end

---@return integer
function Stack:size() return #self.items end

---@return boolean
function Stack:empty() return #self.items == 0 end

---@return OverlookPopup?
function Stack:top()
  if self:empty() then return nil end
  return self.items[#self.items]
end

---Append a popup; clears trash (a new popup invalidates the redo history).
---@param popup OverlookPopup
function Stack:push(popup)
  table.insert(self.items, popup)
  self.trash = {}
end

---Remove the top popup, append it to trash, return it.
---@return OverlookPopup?
function Stack:pop()
  if self:empty() then return nil end
  local top = table.remove(self.items)
  table.insert(self.trash, top)
  return top
end

---Remove the popup with this winid from any position; trash it; return it.
---@param winid integer
---@return OverlookPopup?
function Stack:remove_by_winid(winid)
  for i = #self.items, 1, -1 do
    if self.items[i].winid == winid then
      local removed = table.remove(self.items, i)
      table.insert(self.trash, removed)
      return removed
    end
  end
  return nil
end

---Last trash item without removing it.
---@return OverlookPopup?
function Stack:peek_trash()
  return self.trash[#self.trash]
end

---Remove + return the last trash item.
---@return OverlookPopup?
function Stack:pop_trash()
  if #self.trash == 0 then return nil end
  return table.remove(self.trash)
end

---Append to items WITHOUT clearing trash. Used by restore to re-insert a
---reopened popup while leaving the rest of the trash buffer intact.
---@param popup OverlookPopup
function Stack:restore_item(popup)
  table.insert(self.items, popup)
end

return Stack
