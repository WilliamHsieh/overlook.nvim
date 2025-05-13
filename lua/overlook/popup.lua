local api = vim.api
local Config = require("overlook.config").get()
local Stack = require("overlook.stack")
local State = require("overlook.state")

-- Autocommand group for managing WinClosed events for popups
-- Defined once per module load.
local augroup_id = api.nvim_create_augroup("OverlookPopupClose", { clear = true })

---@class OverlookPopup
---@field opts OverlookPopupOptions
---@field win_id? integer Neovim window ID for the popup
---@field pre_open_win_id? integer Neovim window ID of the window that was current before opening the popup
---@field win_config vim.api.keyset.win_config Neovim window configuration table for `nvim_open_win()`
---@field is_first_popup boolean
---@field calculated_width? number
---@field calculated_height? number
---@field calculated_row? number
---@field calculated_col? number
---@field orginal_win_id? integer
---@field final_width? number
---@field final_height? number
---@field final_row? number
---@field final_col_abs? number
---@field geometry_source string "api", "calculated_fallback", "api_failed", or "none"
local Popup = {}
Popup.__index = Popup

--- Constructor for a new Popup instance.
--- Orchestrates the creation, configuration, and registration of a popup window.
---@param opts OverlookPopupOptions
---@return OverlookPopup?
function Popup.new(opts)
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

  if not this:acquire_final_geometry_and_validate() then
    this:cleanup_opened_window(true) -- Force close the created window
    if this.pre_open_win_id and api.nvim_win_is_valid(this.pre_open_win_id) then
      api.nvim_set_current_win(this.pre_open_win_id) -- Restore original window focus
    end
    return nil
  end

  this:register_with_stack_manager()
  this:create_close_autocommand()

  return this
end

--- Initializes instance variables and performs basic validation.
---@param opts table { target_bufnr: integer, lnum: integer, col: integer, title?: string }
---@return boolean
function Popup:initialize_state(opts)
  self.opts = opts

  if not api.nvim_buf_is_valid(opts.target_bufnr) then
    vim.notify("Overlook: Invalid target buffer for popup", vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Calculates the window configuration for the first popup.
---@return vim.api.keyset.win_config? win_config Neovim window configuration table, or nil if an error occurs
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

  -- Store calculated dimensions for potential fallback and stack item
  self.calculated_width = width
  self.calculated_height = height
  self.calculated_row = win_config.row
  self.calculated_col = win_config.col
  self.orginal_win_id = current_win_id

  return win_config
end

--- Calculates the window configuration for subsequent (stacked) popups.
---@param prev OverlookStackItem Previous popup item from the stack
---@return table? win_config Neovim window configuration table, or nil if an error occurs
function Popup:config_for_stacked_popup(prev)
  local win_config = {
    relative = "win",
    style = "minimal",
    focusable = true,
    win = prev.win_id,
    zindex = Config.ui.z_index_base + Stack.size(),

    width = math.max(Config.ui.min_width, prev.width - Config.ui.width_decrement),
    height = math.max(Config.ui.min_height, prev.height - Config.ui.height_decrement),

    row = Config.ui.stack_row_offset - 1,
    col = Config.ui.stack_col_offset,
  }

  -- Store calculated dimensions for potential fallback and stack item
  self.calculated_width = win_config.width
  self.calculated_height = win_config.height
  self.calculated_row = win_config.row
  self.calculated_col = win_config.row
  self.orginal_win_id = nil -- Not applicable for stacked popups

  return win_config
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
      -- vim.notify("Overlook: Cannot create stacked popup, previous popup not found.", vim.log.levels.ERROR)
      return false
    end
    win_cfg = self:config_for_stacked_popup(prev)
  end

  if not win_cfg then
    return false -- Error already notified by sub-methods
  end

  win_cfg.border = Config.ui.border or vim.o.winborder or "rounded"
  win_cfg.title = self.opts.title or "Overlook default title"
  win_cfg.title_pos = "center"

  self.win_config = win_cfg
  return true
end

--- Opens the Neovim window and registers it with the state manager.
---@return boolean success True if window was opened and registered, false otherwise.
function Popup:open_and_register_window()
  self.pre_open_win_id = api.nvim_get_current_win()
  self.win_id = api.nvim_open_win(self.opts.target_bufnr, true, self.win_config)

  if not self.win_id or self.win_id == 0 then
    if api.nvim_win_is_valid(self.pre_open_win_id) then
      api.nvim_set_current_win(self.pre_open_win_id) -- Restore focus
    end
    -- vim.notify("Overlook: Failed to open popup window.", vim.log.levels.ERROR)
    return false
  end

  State.register_overlook_popup(self.win_id, self.opts.target_bufnr)
  return true
end

--- Configures cursor position and view within the newly opened window.
function Popup:configure_opened_window_details()
  api.nvim_win_set_cursor(self.win_id, { self.opts.lnum, math.max(0, self.opts.col - 1) })
  vim.api.nvim_win_call(self.win_id, function()
    vim.cmd("normal! zz")
  end)
end

--- Acquires final geometry from Neovim API and validates it, falling back to calculated values if necessary.
---@return boolean success True if geometry was acquired and is valid, false otherwise.
function Popup:acquire_final_geometry_and_validate()
  local final_geom = api.nvim_win_get_config(self.win_id)

  -- If nvim_win_get_config itself fails and returns nil, treat as critical failure.
  if final_geom == nil then
    -- vim.notify("Overlook: nvim_win_get_config failed for win_id: " .. tostring(self.win_id), vim.log.levels.WARN)
    self.geometry_source = "api_failed"
    return false
  end

  if final_geom.width and final_geom.height and final_geom.row and final_geom.col then
    self.final_width = final_geom.width
    self.final_height = final_geom.height
    self.final_row = math.floor(final_geom.row)
    self.final_col_abs = math.floor(final_geom.col)
    self.geometry_source = "api"
  elseif
    self.calculated_width ~= nil
    and self.calculated_height ~= nil
    and self.calculated_row ~= nil
    and self.calculated_col ~= nil
  then
    self.final_width = self.calculated_width
    self.final_height = self.calculated_height
    self.final_row = self.calculated_row
    self.final_col_abs = self.calculated_col
    self.geometry_source = "calculated_fallback"
  else
    -- vim.notify("Overlook: Failed to obtain valid geometry for popup.", vim.log.levels.ERROR)
    self.geometry_source = "none"
    return false -- Critical failure if no geometry can be determined
  end
  return true
end

--- Cleans up the window if it was opened, e.g., on subsequent error.
---@param force boolean Whether to force close the window (nvim_win_close force option)
function Popup:cleanup_opened_window(force)
  if self.win_id and api.nvim_win_is_valid(self.win_id) then
    api.nvim_win_close(self.win_id, force)
    self.win_id = nil -- Mark as closed
  end
end

--- Registers the newly created popup with the stack manager.
function Popup:register_with_stack_manager()
  local stack_item = {
    win_id = self.win_id,
    buf_id = self.opts.target_bufnr,
    z_index = self.win_config.zindex,
    width = self.final_width,
    height = self.final_height,
    row = self.final_row,
    col = self.final_col_abs,
    original_win_id = self.orginal_win_id, -- Set in config methods
  }
  Stack.push(stack_item)
end

--- Creates the WinClosed autocommand for this popup instance.
function Popup:create_close_autocommand()
  local win_id_for_closure = self.win_id -- Capture for the closure
  api.nvim_create_autocmd("WinClosed", {
    group = augroup_id, -- Use the module-local augroup
    pattern = tostring(self.win_id),
    once = true,
    callback = function(args)
      ---@diagnostic disable-next-line: undefined-field
      if tonumber(args.match) == win_id_for_closure then
        Stack.handle_win_close(win_id_for_closure)
      end
    end,
  })
end

return Popup
