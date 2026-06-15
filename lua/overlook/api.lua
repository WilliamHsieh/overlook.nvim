--- Public API functions for overlook.nvim
---
--- overlook.api provides the public API functions for overlook.nvim, a plugin
--- for creating stackable floating popups to peek at code locations without
--- losing your context in the current buffer.
---
--- These functions are the primary interface for users to interact with the
--- plugin through key mappings and commands.
---
---@tag overlook-api

local Window = require("overlook.window")

local M = {}

---@text Table of contents
---@toc

---@text Peek Functions
---@toc_entry Peek Functions

--- Peek at the LSP definition under the cursor.
---
--- Creates a floating popup window displaying the definition of the symbol
--- under the cursor using LSP information. The popup is added to the current
--- window's popup stack and can be navigated, edited, and stacked with
--- additional popups.
---
--- If no LSP server is attached or no definition is found, displays an
--- appropriate notification to the user.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pd", require("overlook.api").peek_definition)
--- <
---@tag overlook-api.peek_definition
---@toc_entry
M.peek_definition = function()
  require("overlook.peek.definition")()
end

--- Switch focus between the top popup and the root window.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pf", require("overlook.api").switch_focus)
--- <
---@tag overlook-api.switch_focus
---@toc_entry
M.switch_focus = function()
  Window.current():switch_focus()
end

--- Peek at the current cursor position.
---
--- Creates a floating popup window at the current cursor position, displaying
--- the current buffer content. This is useful for maintaining visual context
--- while navigating to other locations.
---
--- For example, if you are editing a file and want to quickly peek at the
--- function signature or variable declaration, you can create a popup
--- and then navigate to the desired location without losing the context.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pp", require("overlook.api").peek_cursor)
--- <
---@tag overlook-api.peek_cursor
---@toc_entry
M.peek_cursor = function()
  require("overlook.peek.cursor")()
end

--- Peek at a specific mark location.
---
--- Prompts the user to enter a single-character mark name, then creates a
--- floating popup window displaying the content at that mark's location.
--- Only accepts single-character mark names (a-z, A-Z, 0-9).
---
--- Shows an error notification if the input is invalid or empty.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pm", require("overlook.api").peek_mark)
--- <
---@tag overlook-api.peek_mark
---@toc_entry
M.peek_mark = function()
  vim.ui.input({ prompt = "Overlook Mark:" }, function(input)
    if input == nil or input == "" then
      return
    end

    if #input == 1 then
      require("overlook.peek.marks")(input)
    else
      vim.notify("Overlook Error: Invalid mark. Please enter a single character.", vim.log.levels.ERROR)
    end
  end)
end

---@toc_entry Stack Management Functions
---@text Stack Management Functions

--- Restore all previously closed popups in the current stack.
---
--- Reopens all popups that were closed in the current window's popup stack,
--- restoring them in their original stacking order. This allows users to
--- quickly recover their exploration context after accidentally closing popups.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pU", require("overlook.api").restore_all_popups)
--- <
---@tag overlook-api.restore_all_popups
---@toc_entry
M.restore_all_popups = function()
  Window.current():restore_all()
end

--- Restore the most recently closed popup.
---
--- Reopens the last popup that was closed in the current window's popup stack.
--- This provides a quick undo mechanism for popup closures.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pu", require("overlook.api").restore_popup)
--- <
---@tag overlook-api.restore_popup
---@toc_entry
M.restore_popup = function()
  Window.current():restore()
end

--- Close all overlook popups in the current window's stack.
---
--- Closes every popup in the host window's stack and refocuses the host
--- window. Other host windows' stacks are not affected.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pc", require("overlook.api").close_all)
--- <
---@tag overlook-api.close_all
---@toc_entry
M.close_all = function()
  Window.current():close_all()
end

---@text Window Promotion Functions
---
--- Open popups in regular windows.
---@toc_entry Window Promotion Functions

--- Promotes the top Overlook popup to a regular window (split, vsplit, or tab).
---@private
---@param open_command 'vsplit' | 'split' | 'tabnew' Vim command to open the window.
local promote_top_to_window = function(open_command)
  local cmd = string.format("%s | buffer", open_command)
  Window.current():promote(cmd)
end

--- Open the top popup to a horizontal split window.
---
--- Converts the topmost popup in the current stack to a regular horizontal
--- split window. The popup is closed and its buffer content is opened in
--- a new split, preserving cursor position and allowing normal window
--- navigation.
---
--- Shows an error if no popup is available to promote.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>ps", require("overlook.api").open_in_split)
--- <
---@tag overlook-api.open_in_split
---@toc_entry
M.open_in_split = function()
  promote_top_to_window("split")
end

--- Open the top popup to a vertical split window.
---
--- Converts the topmost popup in the current stack to a regular vertical
--- split window. The popup is closed and its buffer content is opened in
--- a new vsplit, preserving cursor position and allowing normal window
--- navigation.
---
--- Shows an error if no popup is available to promote.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pv", require("overlook.api").open_in_vsplit)
--- <
---@tag overlook-api.open_in_vsplit
---@toc_entry
M.open_in_vsplit = function()
  promote_top_to_window("vsplit")
end

--- Open the top popup to a new tab.
---
--- Converts the topmost popup in the current stack to a new tab window.
--- The popup is closed and its buffer content is opened in a new tab,
--- preserving cursor position and allowing full tab functionality.
---
--- Shows an error if no popup is available to promote.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>pt", require("overlook.api").open_in_tab)
--- <
---@tag overlook-api.open_in_tab
---@toc_entry
M.open_in_tab = function()
  promote_top_to_window("tabnew")
end

--- Open the top popup to replace the original window content.
---
--- Converts the topmost popup to occupy the original window that spawned it.
--- The popup is closed and its buffer content replaces the original window's
--- content, preserving cursor position. This effectively "commits" the popup
--- content to become the main window's content.
---
--- Shows an error if no popup is available to promote.
---
---@usage >lua
---   vim.keymap.set("n", "<leader>po", require("overlook.api").open_in_original_window)
--- <
---@tag overlook-api.open_in_original_window
---@toc_entry
M.open_in_original_window = function()
  Window.current():promote("buffer")
end

return M
