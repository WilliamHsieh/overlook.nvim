local M = {}

---@alias OverlookBorderStyle
---| "none"
---| "single"
---| "bold"
---| "double"
---| "rounded"
---| "solid"
---| "shadow"
---| string[]

---@class OverlookUiOptions
---@field border OverlookBorderStyle Border style for popups.
---@field z_index_base integer Base z-index for the first popup.
---@field row_offset integer Initial row offset relative to the cursor for the *first* popup.
---@field col_offset integer Initial column offset relative to the cursor for the *first* popup.
---@field stack_row_offset integer Vertical offset for subsequent stacked popups.
---@field stack_col_offset integer Column offset for subsequent stacked popups.
---@field width_decrement integer Amount by which the width decreases for each subsequent popup.
---@field height_decrement integer Amount by which the height decreases for each subsequent popup.
---@field min_width integer Minimum allowed width for any popup window.
---@field min_height integer Minimum allowed height for any popup window.
---@field size_ratio number Default size ratio (0.0 to 1.0) used to calculate initial size.
---@field keys? table<string, string> Keymaps specific to the popup UI.

---@class OverlookAdapterOptions
---@field marks? table Configuration for the 'marks' adapter.
-- ---@field lsp? table Placeholder for future LSP adapter config

---@class OverlookOptions
---@field ui OverlookUiOptions UI settings for the popup windows.
---@field adapters OverlookAdapterOptions Adapter-specific configurations.
---@field on_stack_empty? fun() Optional function called when the last Overlook popup closes.

---Default configuration options for overlook.nvim
---@type OverlookOptions
M.options = {
  -- UI settings for the popup windows
  ui = {
    -- Border style for popups. Accepts same values as nvim_open_win's 'border' option
    border = "rounded",

    -- Base z-index for the first popup. Subsequent popups increment from here.
    -- Higher values appear visually on top. Should be high enough to be above normal floats.
    z_index_base = 100,

    -- Initial row offset relative to the cursor for the *first* popup.
    row_offset = 0,
    -- Initial column offset relative to the cursor for the *first* popup.
    col_offset = 0,

    -- Vertical offset for subsequent stacked popups relative to the previous popup's top border.
    stack_row_offset = 0,
    -- Column offset for subsequent stacked popups relative to the previous popup's top-left corner.
    stack_col_offset = 0,

    -- Amount by which the width decreases for each subsequent popup in the stack.
    width_decrement = 2,
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

  -- Adapter-specific configurations
  adapters = {
    -- Configuration for the 'marks' adapter
    marks = {},
    -- lsp = {}, -- Placeholder for future LSP adapter config
  },

  -- Optional hook called when the last Overlook popup closes
  on_stack_empty = nil,
}

-- Merges user-provided options with the defaults.
-- Called from require('overlook').setup(opts) in user's config.
---@param user_opts? table User configuration options passed from their setup call.
function M.setup(user_opts)
  if user_opts then
    -- Use deep_extend to merge nested tables like 'ui' and 'adapters'.
    -- 'force' mode replaces arrays entirely if present, usually desired for config.
    M.options = vim.tbl_deep_extend("force", M.options, user_opts or {})
  end
  -- You could add validation for option values here later if needed.
  -- For example, ensure min_width is less than default_width.
end

-- Returns the currently active configuration table.
-- Primarily for internal use by other plugin modules via require('overlook.config').get()
-- or directly via require('overlook.config').options if setup timing is guaranteed.
---@return OverlookOptions
function M.get()
  return M.options
end

return M
