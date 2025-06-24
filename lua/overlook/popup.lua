local api = vim.api
local Config = require("overlook.config").get()
local Stack = require("overlook.stack")
local State = require("overlook.state")

---@class OverlookPopup
---@field opts OverlookPopupOptions
---@field win_id integer Neovim window ID for the popup
---@field win_config vim.api.keyset.win_config window configuration table for `nvim_open_win()`
---@field width integer Width of the popup window
---@field height integer Height of the popup window
---@field is_first_popup boolean
---@field orginal_win_id integer
local Popup = {}
Popup.__index = Popup

local M = {}

--- Constructor for a new Popup instance.
--- Orchestrates the creation, configuration, and registration of a popup window.
---@param opts OverlookPopupOptions
---@return OverlookPopup?
function M.new(opts)
  ---@type OverlookPopup
  local this = setmetatable({}, Popup)

  if not this:initialize_state(opts) then
    return nil
  end

  if not this:determine_window_configuration() then
    return nil
  end

  if not this:open_and_register_window() then
    return nil
  end

  this:configure_opened_window_details()

  return this
end

--- Initializes instance variables and performs basic validation.
---@param opts table { target_bufnr: integer, lnum: integer, col: integer, title?: string }
---@return boolean
function Popup:initialize_state(opts)
  if not opts then
    vim.notify("Overlook: Invalid opts provided to Popup", vim.log.levels.ERROR)
    return false
  end
  if not opts.target_bufnr then
    vim.notify("Overlook: target_bufnr missing in opts for Popup", vim.log.levels.ERROR)
    return false
  end

  self.opts = opts

  if not api.nvim_buf_is_valid(opts.target_bufnr) then
    vim.notify("Overlook: Invalid target buffer for popup", vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Calculates the window configuration for the first popup.
---@return vim.api.keyset.win_config win_config Neovim window configuration table, or nil if an error occurs
function Popup:config_for_first_popup()
  local current_win_id = api.nvim_get_current_win()
  local cursor_buf_pos = api.nvim_win_get_cursor(current_win_id)
  local cursor_abs_screen_pos = vim.fn.screenpos(current_win_id, cursor_buf_pos[1], cursor_buf_pos[2] + 1)
  local win_pos = api.nvim_win_get_position(current_win_id)

  -- distance from the top of the window to the cursor (including winbar)
  local winbar_enabled = vim.o.winbar ~= ""
  local max_window_height = api.nvim_win_get_height(current_win_id) - (winbar_enabled and 1 or 0)
  local max_window_width = api.nvim_win_get_width(current_win_id)

  local screen_space_above = cursor_abs_screen_pos.row - win_pos[1] - 1 - (winbar_enabled and 1 or 0)
  local screen_space_below = max_window_height - screen_space_above - 1
  local screen_space_left = cursor_abs_screen_pos.col - win_pos[2] - 1

  local place_above = screen_space_above > max_window_height / 2

  local border_overhead = Config.ui.border ~= "none" and 2 or 0
  local max_fittable_content_height = (place_above and screen_space_above or screen_space_below) - border_overhead

  local target_height = math.min(math.floor(max_window_height * Config.ui.size_ratio), max_fittable_content_height)
  local target_width = math.floor(max_window_width * Config.ui.size_ratio)

  local height = math.max(Config.ui.min_height, target_height)
  local width = math.max(Config.ui.min_width, target_width)

  local win_config = {
    relative = "win",
    style = "minimal",
    focusable = true,

    -- borders does not count towards the dimensions of the window
    width = width,
    height = height,

    win = current_win_id,
    zindex = Config.ui.z_index_base,
    col = screen_space_left + Config.ui.col_offset,
  }

  if place_above then
    win_config.row = math.max(0, screen_space_above - height - border_overhead - Config.ui.row_offset)
  else
    win_config.row = screen_space_above + 1 + Config.ui.row_offset
  end

  self.orginal_win_id = current_win_id

  return win_config
end

--- Calculates the window configuration for subsequent (stacked) popups.
---@param prev OverlookPopup Previous popup item from the stack
---@return table win_config Neovim window configuration table, or nil if an error occurs
function Popup:config_for_stacked_popup(prev)
  self.orginal_win_id = prev.orginal_win_id
  return {
    relative = "win",
    style = "minimal",
    focusable = true,
    win = prev.win_id,
    zindex = Config.ui.z_index_base + Stack.size(),

    width = math.max(Config.ui.min_width, prev.width - Config.ui.width_decrement),
    height = math.max(Config.ui.min_height, prev.height - Config.ui.height_decrement),

    row = Config.ui.stack_row_offset - (vim.o.winbar ~= "" and 1 or 0),
    col = Config.ui.stack_col_offset,
  }
end

--- Determines and sets the complete window configuration (size, position, border, title).
---@return boolean success True if configuration was successful, false otherwise.
function Popup:determine_window_configuration()
  local win_cfg

  if Stack.empty() then
    self.is_first_popup = true
    win_cfg = self:config_for_first_popup()
  else
    self.is_first_popup = false
    local prev = Stack.top()
    if not prev then
      vim.notify("Overlook: Failed to get previous popup from stack for stacked configuration.", vim.log.levels.ERROR)
      return false
    end
    win_cfg = self:config_for_stacked_popup(prev)
  end

  local border
  if Config.ui.border and Config.ui.border ~= "" then
    border = Config.ui.border
  elseif vim.o.winborder and vim.o.winborder ~= "" then
    border = vim.o.winborder
  else
    border = "rounded"
  end

  ---@diagnostic disable-next-line: assign-type-mismatch
  win_cfg.border = border
  win_cfg.title = self.opts.title or "Overlook default title"
  win_cfg.title_pos = "center"

  self.win_config = win_cfg
  return true
end

--- Opens the Neovim window and registers it with the state manager.
---@return boolean success True if window was opened and registered, false otherwise.
function Popup:open_and_register_window()
  self.win_id = api.nvim_open_win(self.opts.target_bufnr, true, self.win_config)

  if self.win_id == 0 then
    vim.notify("Overlook: Failed to open popup window.", vim.log.levels.ERROR)
    return false
  end

  vim.w.is_overlook_popup = true
  vim.w.overlook_popup = {
    original_win_id = self.orginal_win_id,
  }

  State.register_overlook_popup(self.win_id, self.opts.target_bufnr)

  local actual_win_config = vim.api.nvim_win_get_config(self.win_id)
  self.width = actual_win_config.width
  self.height = actual_win_config.height

  return true
end

--- Configures cursor position and view within the newly opened window.
function Popup:configure_opened_window_details()
  api.nvim_win_set_cursor(self.win_id, { self.opts.lnum, math.max(0, self.opts.col - 1) })
  vim.api.nvim_win_call(self.win_id, function()
    vim.cmd("normal! zz")
  end)
end

return M
