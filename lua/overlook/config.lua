--- Configuration for overlook.nvim
---
--- Configuration module for overlook.nvim, providing default settings and user
--- customization capabilities for popup behavior, styling, and adapter configurations.
---
--- This module handles the setup and merging of user-provided options with
--- sensible defaults, ensuring the plugin works out of the box while allowing
--- extensive customization.
---
--- # Features ~
---
--- - Type-safe configuration with comprehensive field definitions
--- - Deep merging of user options with sensible defaults
--- - Flexible UI customization (borders, positioning, sizing)
--- - Adapter-specific configuration support
--- - Runtime configuration access for other modules
---
--- # Setup ~
---
--- This module is typically used indirectly through the main overlook setup:
--- >lua
---   require('overlook').setup({
---     ui = {
---       border = "single",
---       row_offset = 2,
---       size_ratio = 0.8
---     }
---   })
--- <
---
--- Direct access to configuration:
--- >lua
---   local opts = require('overlook.config').get()
--- <
---@tag overlook-config

local M = {}

---@text Type Definitions

--- *OverlookBorderStyle*
---
---@alias OverlookBorderStyle
---| "none"       No border
---| "single"     Single line border using box-drawing characters
---| "bold"       Bold border using heavy box-drawing characters
---| "double"     Double line border using double box-drawing characters
---| "rounded"    Rounded corners border (default)
---| "solid"      Solid border using block characters
---| "shadow"     Border with shadow effect
---| string[]     Custom border array as defined by nvim_open_win

--- *OverlookOptions.UI*
---
---@class OverlookOptions.UI
---
---@field border OverlookBorderStyle Border style for popups.
---@field z_index_base integer Base z-index for the first popup.
---@field row_offset integer Initial row offset relative to the cursor for the first popup.
---@field col_offset integer Initial column offset relative to the cursor for the first popup.
---@field stack_row_offset integer Vertical offset for subsequent stacked popups.
---@field stack_col_offset integer Column offset for subsequent stacked popups.
---@field width_decrement integer Amount by which the width decreases for each subsequent popup.
---@field height_decrement integer Amount by which the height decreases for each subsequent popup.
---@field min_width integer Minimum allowed width for any popup window.
---@field min_height integer Minimum allowed height for any popup window.
---@field size_ratio number Default size ratio (0.0 to 1.0) used to calculate initial size.
---@field keys? table<string, string> Keymaps specific to the popup UI.

--- *OverlookOptions*
---
---@class OverlookOptions
---
---@field ui OverlookOptions.UI UI settings for the popup windows.
---@field on_stack_empty? fun() Optional function called when the last Overlook popup closes.

--- Default configuration options for overlook.nvim.
---
--- These options control the appearance, behavior, and positioning of floating
--- popups, as well as adapter-specific settings. Users can override any of these
--- values by passing a configuration table to |require("overlook").setup()|.
---
---@seealso |overlook-config.setup()|
---
---@type OverlookOptions
---@eval return require("mini.doc").afterlines_to_code(MiniDoc.current.eval_section)
---@tag overlook-config.defaults
local defaults = {
  -- UI settings for the popup windows
  ui = {
    -- Border style for popups. Accepts same values as nvim_open_win's 'border' option
    border = "rounded",

    -- Base z-index for the first popup. Subsequent popups increment from here.
    -- Higher values appear visually on top.
    z_index_base = 30,

    -- Initial row offset relative to the cursor for the first popup.
    row_offset = 0,
    -- Initial column offset relative to the cursor for the first popup.
    col_offset = 0,

    -- Vertical offset for subsequent stacked popups relative to the previous popup's top border.
    stack_row_offset = 0,
    -- Column offset for subsequent stacked popups relative to the previous popup's top-left corner.
    stack_col_offset = 0,

    -- Amount by which the width decreases for each subsequent popup in the stack.
    width_decrement = 1,
    -- Amount by which the height decreases for each subsequent popup in the stack.
    height_decrement = 1,

    -- Minimum allowed width for any popup window, prevents shrinking to zero.
    min_width = 10,
    -- Minimum allowed height for any popup window (must be >= 3 for border+title+content).
    min_height = 3,

    -- Default size ratio (0.0 to 1.0) used to calculate initial size.
    size_ratio = 0.65,

    -- Keymaps specific to the popup UI
    keys = {
      close = "q", -- Key to close the topmost popup
    },
  },

  -- Optional hook called when the last Overlook popup closes
  on_stack_empty = nil,
}
--minidoc_afterlines_end

--- user-provided options, merged with defaults
---@private
local options = vim.deepcopy(defaults)

---@private
---@param user_opts? table User configuration options. Can contain any subset of OverlookOptions fields.
function M.setup(user_opts)
  if user_opts then
    -- Use deep_extend to merge nested tables like 'ui'.
    -- 'force' mode replaces arrays entirely if present, usually desired for config.
    options = vim.tbl_deep_extend("force", options, user_opts or {})
  end
  -- You could add validation for option values here later if needed.
  -- For example, ensure min_width is less than default_width.
end

--- Get the current active configuration.
---
--- Returns the currently active configuration table after any user modifications
--- have been applied through M.setup(). This is primarily used internally by
--- other overlook modules to access configuration values.
---
--- External modules can also access configuration directly via
--- `require('overlook.config').options` if they ensure proper setup timing.
---
---@return OverlookOptions The active configuration table
---
---@tag overlook-config.get
---@usage >lua
---   local opts = require("overlook.config").get()
--- <
function M.get()
  return options
end

return M
