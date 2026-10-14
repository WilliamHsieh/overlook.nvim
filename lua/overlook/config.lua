--- Configuration for overlook.nvim
---
--- Configuration module for overlook.nvim, providing default settings and user
--- customization capabilities for popup behavior and styling.
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

--- *OverlookOnMultiple*
---
--- What to do when an LSP peek returns more than one location. A single
--- location always opens a popup directly and never prompts.
---
---@alias OverlookOnMultiple
---| "first"  Open the first location without prompting. This is the default.
---| "select" Prompt with vim.ui.select. Entries are "relative/path:line: text".
---           The path is relative to the working directory. Line text is trimmed.
---           Any vim.ui.select UI works, including telescope-ui-select and
---           `require("fzf-lua").register_ui_select()`.
---| fun(items: table[], open_fn: fun(item: table))
---           Custom handler. `items` are quickfix-style LSP entries. Call
---           `open_fn(item)` to open that location, or pass nil to open nothing.
---
--- Any other value warns at |overlook-setup|() and when a peek runs, then
--- falls back to "first".

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
---@field title_pos "left"|"center"|"right" Position of the popup title.
---@field keys? table<string, string> Keymaps specific to the popup UI.

--- *OverlookOptions*
---
---@class OverlookOptions
---
---@field ui OverlookOptions.UI UI settings for the popup windows.
---@field on_multiple OverlookOnMultiple Strategy when several LSP locations match: "first" (default), "select", or a function(items, open_fn). Unknown values warn and fall back to "first".
---@field on_stack_empty? fun() Optional function called when the last Overlook popup closes.

--- Default configuration options for overlook.nvim.
---
--- These options control the appearance, behavior, and positioning of floating
--- popups. Users can override any of these values by passing a configuration
--- table to |require("overlook").setup()|.
---
---@seealso |overlook-setup|
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

    -- Position of the popup title. Accepts "left", "center", or "right".
    title_pos = "center",

    -- Keymaps specific to the popup UI
    keys = {
      close = "q", -- Key to close the topmost popup
    },
  },

  -- How to handle an LSP peek that returns more than one location.
  -- A single location always opens directly and never prompts.
  -- "first" (default) opens the first location, matching the previous behavior.
  -- "select" calls vim.ui.select. Entries are formatted as
  -- "relative/path:line: text". telescope-ui-select and
  -- require("fzf-lua").register_ui_select() work by replacing vim.ui.select.
  -- A function(items, open_fn) handles the list itself. Call open_fn(item)
  -- to open that location in a popup, or open_fn(nil) to open nothing.
  -- require("overlook.peek.location").format_item formats an entry the same way.
  -- Any other value warns and falls back to "first".
  on_multiple = "first",

  -- Optional hook called when the last Overlook popup closes
  on_stack_empty = nil,
}
--minidoc_afterlines_end

--- user-provided options, merged with defaults
---@private
local options = vim.deepcopy(defaults)

-- True for the accepted on_multiple values: "first", "select", or a function.
local function on_multiple_is_valid(value)
  return value == "first" or value == "select" or type(value) == "function"
end

---@private
---@param user_opts? table User configuration options. Can contain any subset of OverlookOptions fields.
function M.setup(user_opts)
  if user_opts then
    -- Use deep_extend to merge nested tables like 'ui'.
    -- 'force' mode replaces arrays entirely if present, usually desired for config.
    options = vim.tbl_deep_extend("force", options, user_opts or {})
  end

  -- vim.validate errors on a bad value. A typo should warn and keep the
  -- previous peek behavior ("first") instead of aborting setup.
  local value = options.on_multiple
  local ok = pcall(vim.validate, "on_multiple", value, on_multiple_is_valid, false, '"first", "select", or a function')
  if not ok then
    vim.notify("Overlook: unknown on_multiple (" .. tostring(value) .. '); using "first".', vim.log.levels.WARN)
    options.on_multiple = "first"
  end
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
