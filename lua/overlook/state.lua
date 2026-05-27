local api = vim.api
local Config = require("overlook.config")

local M = {}

M.touched_by_overlook = {} -- bufnr -> true

-- State for dynamic keymap
local currently_mapped_info = {
  bufnr = nil,
  original_map_details = nil,
}

--- @param bufnr any
--- @param opts vim.api.keyset.get_keymap
local function set_keymap(bufnr, opts)
  if not opts then
    return
  end
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    vim.notify("Overlook: Invalid bufnr for restoring keymap", vim.log.levels.WARN)
    return
  end

  local ok_set, err_set = pcall(vim.keymap.set, opts.mode, opts.lhs, opts.callback or opts.rhs, {
    buffer = bufnr,
    script = opts.script == 1,
    noremap = opts.noremap == 1,
    silent = opts.silent == 1,
    expr = opts.expr == 1,
    nowait = opts.nowait == 1,
  })
  if not ok_set then
    vim.notify(
      "Overlook: Error restoring original keymap for buffer " .. tostring(bufnr) .. ": " .. tostring(err_set),
      vim.log.levels.WARN
    )
  end
end

--- @return vim.api.keyset.get_keymap?
local function find_original_map(lhs)
  local buf_maps = vim.api.nvim_buf_get_keymap(0, "n")
  for _, map in ipairs(buf_maps) do
    if map.lhs == lhs then
      return map
    end
  end

  local maps = vim.api.nvim_get_keymap("n")
  for _, map in ipairs(maps) do
    if map.lhs == lhs then
      return map
    end
  end
  return nil
end

---Handles updating the dynamic 'close' keymap based on focus and stack state.
function M.update_keymap()
  local current_win = api.nvim_get_current_win()
  -- Add check for valid buffer before proceeding
  local current_buf = api.nvim_win_get_buf(current_win)
  if not api.nvim_buf_is_valid(current_buf) then
    return -- Avoid errors if buffer somehow invalid
  end

  local top_item = require("overlook.window").current():top()
  local top_win_id = top_item and top_item.winid or nil
  local close_key = Config.get().ui.keys.close

  -- Target buffer for the keymap is the buffer in the current window ONLY if it's the top popup
  local target_bufnr_for_keymap = (top_win_id and current_win == top_win_id) and current_buf or nil

  -- State is already correct for keymap
  if currently_mapped_info.bufnr == target_bufnr_for_keymap then
    return
  end

  -- State needs changing: Clear old map first (if any)
  if currently_mapped_info.bufnr and vim.api.nvim_buf_is_loaded(currently_mapped_info.bufnr) then
    -- Clear keymap
    vim.keymap.del("n", close_key, { buffer = currently_mapped_info.bufnr })

    -- Restore original keymap if it existed
    set_keymap(currently_mapped_info.bufnr, currently_mapped_info.original_map_details)

    -- Reset state
    currently_mapped_info = { bufnr = nil, original_map_details = nil }
  end

  -- Set new map if needed
  if target_bufnr_for_keymap then
    -- Find and store original map BEFORE setting the new one
    currently_mapped_info = {
      bufnr = target_bufnr_for_keymap,
      original_map_details = find_original_map(close_key),
    }

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

  local top_item = require("overlook.window").current():top()
  local top_win_id = top_item and top_item.winid or nil

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

  if vim.w.is_overlook_popup then
    -- switching buffer within an Overlook popup, e.g. go to definition
    M.register_overlook_popup(current_winid, current_bufnr)
    return -- Don't restore options on Overlook's own popups
  end

  -- Check if this buffer was touched by Overlook
  if not M.touched_by_overlook[current_bufnr] then
    return
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
