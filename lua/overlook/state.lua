local api = vim.api
local Config = require("overlook.config")
local Stack = require("overlook.stack")

local M = {}

M.touched_by_overlook = {} -- bufnr -> true

-- State for dynamic keymap
local currently_mapped_info = {
  bufnr = nil,
  original_map_details = nil,
}

-- Helper to find and reconstruct original map details
local function find_original_map(bufnr, mode, lhs)
  -- Use pcall for safety, vim.keymap.get can error on invalid buffer
  local ok, maps = pcall(vim.keymap.get, mode, { buffer = bufnr })
  if not ok or not maps then
    return nil
  end

  for _, map in ipairs(maps) do
    if map.lhs == lhs then
      -- Reconstruct opts, ensuring buffer is present and removing mutually exclusive fields
      local opts = vim.deepcopy(map)
      opts.buffer = bufnr -- Ensure buffer is in opts
      opts.mode = nil
      opts.lhs = nil
      opts.sid = nil -- Remove fields not used by set
      opts.reg = nil
      opts.script = opts.script == 1 -- Convert 1/0 to boolean
      opts.noremap = opts.noremap == 1
      opts.silent = opts.silent == 1
      opts.expr = opts.expr == 1
      opts.nowait = opts.nowait == 1
      opts.unique = opts.unique == 1

      local rhs_or_callback = opts.callback -- Prefer callback if it exists
      if rhs_or_callback then
        opts.callback = nil
        opts.rhs = nil
      else
        rhs_or_callback = opts.rhs
        opts.rhs = nil
        opts.callback = nil
      end

      return { mode = map.mode, lhs = map.lhs, rhs_or_callback = rhs_or_callback, opts = opts }
    end
  end
  return nil
end

---Handles updating the dynamic 'close' keymap based on focus and stack state.
function M.update_keymap()
  -- Safeguard for tests where vim.api might not be ready immediately
  if not vim.api then
    return
  end
  local current_win = api.nvim_get_current_win()
  -- Add check for valid buffer before proceeding
  local current_buf = api.nvim_win_get_buf(current_win)
  if not api.nvim_buf_is_valid(current_buf) then
    return -- Avoid errors if buffer somehow invalid
  end

  local top_item = Stack.top() -- Use local require
  local top_win_id = top_item and top_item.win_id or nil
  local cfg = Config.options -- Use local require
  local close_key = (cfg and cfg.ui and cfg.ui.keys and cfg.ui.keys.close) or "q"

  -- Target buffer for the keymap is the buffer in the current window ONLY if it's the top popup
  local target_bufnr_for_keymap = (top_win_id and current_win == top_win_id) and current_buf or nil

  if currently_mapped_info.bufnr == target_bufnr_for_keymap then
    return -- State is already correct for keymap
  end

  -- State needs changing: Clear old map first (if any)
  if currently_mapped_info.bufnr then
    local previous_bufnr = currently_mapped_info.bufnr

    -- Clear keymap
    local ok_del, err_del = pcall(vim.keymap.del, "n", close_key, { buffer = previous_bufnr })
    if not ok_del then
      vim.notify("Overlook: Error deleting old keymap: " .. tostring(err_del), vim.log.levels.WARN)
    end

    -- Restore original keymap if it existed
    if currently_mapped_info.original_map_details then
      local map = currently_mapped_info.original_map_details
      local ok_set, err_set = pcall(vim.keymap.set, map.mode, map.lhs, map.rhs_or_callback, map.opts)
      if not ok_set then
        vim.notify(
          "Overlook: Error restoring original keymap for buffer "
            .. tostring(previous_bufnr)
            .. ": "
            .. tostring(err_set),
          vim.log.levels.WARN
        )
      end
    end

    currently_mapped_info = { bufnr = nil, original_map_details = nil } -- Reset state
  end

  -- Set new map if needed
  if target_bufnr_for_keymap then
    -- Find and store original map BEFORE setting the new one
    local original_details = find_original_map(target_bufnr_for_keymap, "n", close_key)
    if original_details then
      currently_mapped_info.original_map_details = original_details
    end

    -- Set the custom map
    local close_cmd = "<Cmd>close<CR>"
    local ok_set_new, err_set_new = pcall(vim.keymap.set, "n", close_key, close_cmd, {
      buffer = target_bufnr_for_keymap,
      noremap = true,
      silent = true,
      nowait = true,
      desc = "Overlook: Close popup",
    })

    if not ok_set_new then
      vim.notify("Overlook: Error setting close keymap: " .. tostring(err_set_new), vim.log.levels.ERROR)
      currently_mapped_info = { bufnr = nil, original_map_details = nil } -- Reset state on error
    else
      currently_mapped_info.bufnr = target_bufnr_for_keymap -- Update state only on success
    end
  end
end

---Sets the window title based on the buffer if the current window is the top popup.
function M.update_title()
  if not vim.api then
    return
  end
  local current_win = api.nvim_get_current_win()
  local current_buf = api.nvim_win_get_buf(current_win)
  if not api.nvim_buf_is_valid(current_buf) then
    return
  end

  local top_item = Stack.top() -- Use local require
  local top_win_id = top_item and top_item.win_id or nil

  -- Only act if the current window IS the top overlook popup
  if top_win_id and current_win == top_win_id then
    local buf_name = api.nvim_buf_get_name(current_buf)
    local display_title
    if buf_name and buf_name ~= "" then
      display_title = vim.fn.fnamemodify(buf_name, ":~:.")
    else
      display_title = "(No Name)" -- Fallback title
    end

    -- Get current config and set the title
    local ok_cfg, current_cfg = pcall(api.nvim_win_get_config, current_win)
    if ok_cfg and current_cfg then
      current_cfg.title = display_title
      -- Use pcall for safety, but maybe notify on error?
      local ok_set, err_set = pcall(api.nvim_win_set_config, current_win, current_cfg)
      if not ok_set then
        vim.notify("Overlook: Failed to set window title: " .. tostring(err_set), vim.log.levels.WARN)
      end
    else
      vim.notify("Overlook: Failed to get window config for title", vim.log.levels.WARN)
    end
  end
end

--- Registers an Overlook popup window and marks its buffer as touched.
---@param winid integer The window ID of the Overlook popup.
---@param bufnr integer The buffer number displayed in the popup.
function M.register_overlook_popup(winid, bufnr)
  if not api.nvim_win_is_valid(winid) or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  M.touched_by_overlook[bufnr] = true
end

--- Cleans up tracking for a buffer when it's deleted.
---@param bufnr integer
function M.cleanup_touched_buffer(bufnr)
  if M.touched_by_overlook[bufnr] then
    M.touched_by_overlook[bufnr] = nil
  end
end

local function restore_options()
  -- This list can be shared or made more configurable if needed
  vim.wo.number = vim.go.number
  vim.wo.relativenumber = vim.go.relativenumber
  vim.wo.cursorline = vim.go.cursorline
  vim.wo.cursorcolumn = vim.go.cursorcolumn
  vim.wo.spell = vim.go.spell
  vim.wo.list = vim.go.list
  vim.wo.statuscolumn = vim.go.statuscolumn
  vim.wo.colorcolumn = vim.go.colorcolumn
  vim.wo.signcolumn = vim.go.signcolumn
  vim.wo.foldcolumn = vim.go.foldcolumn
  vim.wo.winhl = "" -- Clears window-specific highlights
end

--- Checks if a buffer displayed in a window needs its style restored,
--- and applies the restoration if necessary.
--- Intended to be called from a BufWinEnter autocommand.
function M.handle_style_for_buffer_in_window()
  local current_winid = api.nvim_get_current_win()
  local current_bufnr = api.nvim_get_current_buf()

  if not api.nvim_buf_is_valid(current_bufnr) or not api.nvim_win_is_valid(current_winid) then
    return
  end

  -- Check if this buffer was touched by Overlook
  if not M.touched_by_overlook[current_bufnr] then
    return
  end

  if vim.w.is_overlook_popup then
    return -- Don't restore options on Overlook's own popups
  end

  -- If we're here, a "touched" buffer is in a non-Overlook window. Restore its style.

  local ignored_filetypes = {
    help = true,
    qf = true,
    NvimTree = true, -- Common file explorer
    fugitive = true, -- Git interface
    fzf = true, -- fzf itself
    TelescopePrompt = true,
    TelescopeResults = true,
    packer = true,
    lazy = true,
    man = true,
    -- gitcommit = true, -- Typically edited with standard options
    -- gitrebase = true, -- Typically edited with standard options
    -- Add any other filetypes that have their own distinct UI here
  }

  local ignored_buftypes = {
    nofile = true,
    nowrite = true,
    terminal = true,
    prompt = true,
    acwrite = true,
    -- popup = true, -- though our is_overlook_popup check should catch Overlook's own
  }

  if ignored_filetypes[vim.bo.filetype] or ignored_buftypes[vim.bo.buftype] then
    return -- Don't restore styles for these types
  end

  restore_options()

  -- Optional: Unmark the buffer after first restoration if you only want to do it once
  -- M.touched_by_overlook[current_bufnr] = nil
  -- For now, let's keep it marked so it's always restored if opened in a non-overlook window.
end

return M
