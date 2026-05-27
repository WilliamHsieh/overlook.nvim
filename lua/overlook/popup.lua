local api = vim.api
local Config = require("overlook.config").get()
local State = require("overlook.state")

---@class OverlookPopupContext
---@field root_winid integer
---@field prev OverlookPopup?   -- previous (top) popup, nil for first
---@field depth integer         -- stack size before this popup is added

---@class OverlookPopup
---@field opts OverlookPopupOptions
---@field winid integer?
---@field win_config vim.api.keyset.win_config
---@field width integer
---@field height integer
---@field is_first_popup boolean
---@field root_winid integer
local Popup = {}
Popup.__index = Popup

local M = {}

---Constructs a Popup and computes its window config. Does NOT open the window.
---@param opts OverlookPopupOptions
---@param ctx OverlookPopupContext?
---@return OverlookPopup?
function M.new(opts, ctx)
  local this = setmetatable({}, Popup)
  ctx = ctx or { root_winid = api.nvim_get_current_win(), prev = nil, depth = 0 }

  if not this:initialize_state(opts) then
    return nil
  end

  if not this:determine_window_configuration(ctx) then
    return nil
  end

  return this
end

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

function Popup:config_for_first_popup()
  local current_winid = api.nvim_get_current_win()
  local cursor_buf_pos = api.nvim_win_get_cursor(current_winid)
  local cursor_abs_screen_pos = vim.fn.screenpos(current_winid, cursor_buf_pos[1], cursor_buf_pos[2] + 1)
  local win_pos = api.nvim_win_get_position(current_winid)

  local winbar_enabled = vim.o.winbar ~= ""
  local max_window_height = api.nvim_win_get_height(current_winid) - (winbar_enabled and 1 or 0)
  local max_window_width = api.nvim_win_get_width(current_winid)

  local screen_space_above = cursor_abs_screen_pos.row - win_pos[1] - 1 - (winbar_enabled and 1 or 0)
  local screen_space_below = max_window_height - screen_space_above - 1
  local screen_space_left = cursor_abs_screen_pos.col - win_pos[2] - 1

  local place_above = screen_space_above > max_window_height / 2

  local border_overhead = Config.ui.border ~= "none" and 2 or 0
  local max_fittable = (place_above and screen_space_above or screen_space_below) - border_overhead

  local target_height = math.min(math.floor(max_window_height * Config.ui.size_ratio), max_fittable)
  local target_width = math.floor(max_window_width * Config.ui.size_ratio)
  local height = math.max(Config.ui.min_height, target_height)
  local width = math.max(Config.ui.min_width, target_width)

  local win_config = {
    relative = "win", style = "minimal", focusable = true,
    width = width, height = height,
    win = current_winid,
    zindex = Config.ui.z_index_base,
    col = screen_space_left + Config.ui.col_offset,
  }
  if place_above then
    win_config.row = math.max(0, screen_space_above - height - border_overhead - Config.ui.row_offset)
  else
    win_config.row = screen_space_above + 1 + Config.ui.row_offset
  end
  return win_config, current_winid
end

---@param prev OverlookPopup
---@param depth integer
function Popup:config_for_stacked_popup(prev, depth)
  return {
    relative = "win", style = "minimal", focusable = true,
    win = prev.winid,
    zindex = Config.ui.z_index_base + depth,
    width = math.max(Config.ui.min_width, prev.width - Config.ui.width_decrement),
    height = math.max(Config.ui.min_height, prev.height - Config.ui.height_decrement),
    row = Config.ui.stack_row_offset - (vim.o.winbar ~= "" and 1 or 0),
    col = Config.ui.stack_col_offset,
  }
end

---@param ctx OverlookPopupContext
function Popup:determine_window_configuration(ctx)
  local win_cfg
  if ctx.prev == nil then
    self.is_first_popup = true
    local cfg, current_winid = self:config_for_first_popup()
    win_cfg = cfg
    self.root_winid = current_winid
  else
    self.is_first_popup = false
    win_cfg = self:config_for_stacked_popup(ctx.prev, ctx.depth)
    self.root_winid = ctx.root_winid
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

---Open the float. Internal rollback: if post-open setup throws, close the
---half-created window and return false. Caller (Window) checks the return.
---@return boolean ok
function Popup:open()
  self.winid = api.nvim_open_win(self.opts.target_bufnr, true, self.win_config)
  if self.winid == 0 then
    self.winid = nil
    vim.notify("Overlook: Failed to open popup window.", vim.log.levels.ERROR)
    return false
  end

  local ok, err = pcall(function()
    vim.w.is_overlook_popup = true
    vim.w.overlook_popup = { root_winid = self.root_winid }
    State.register_overlook_popup(self.winid, self.opts.target_bufnr)
    local actual = api.nvim_win_get_config(self.winid)
    self.width = actual.width
    self.height = actual.height
    M.set_cursor_position(self.winid, self.opts.lnum, self.opts.col)
  end)

  if not ok then
    pcall(api.nvim_win_close, self.winid, true)
    State.cleanup_touched_buffer(self.opts.target_bufnr)
    self.winid = nil
    vim.notify("Overlook: post-open setup failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

---@param force? boolean
function Popup:close(force)
  if self:is_valid() then
    pcall(api.nvim_win_close, self.winid, force or false)
  end
end

---@return boolean
function Popup:is_valid()
  return self.winid ~= nil and api.nvim_win_is_valid(self.winid)
end

function Popup:focus()
  if self:is_valid() then
    pcall(api.nvim_set_current_win, self.winid)
  end
end

---@param winid integer
---@param lnum integer
---@param col integer
function M.set_cursor_position(winid, lnum, col)
  api.nvim_win_set_cursor(winid, { lnum, math.max(0, col - 1) })
  api.nvim_win_call(winid, function()
    vim.cmd("normal! zz")
  end)
end

return M
