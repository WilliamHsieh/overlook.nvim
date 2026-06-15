local api = vim.api
local Stack = require("overlook.stack")

---@class OverlookWindow
---@field winid integer         -- root (host) window id
---@field stack OverlookStack
local Window = {}
Window.__index = Window

---@param winid integer
---@return OverlookWindow
function Window.new(winid)
  return setmetatable({ winid = winid, stack = Stack.new() }, Window)
end

-- Module-level registry / facade
local M = {}

---@type table<integer, OverlookWindow>
M.instances = {} -- keyed by root winid; exposed for testing

---Get-or-create the Window for a given root winid.
---@param winid integer
---@return OverlookWindow
function M.get(winid)
  if not M.instances[winid] then
    M.instances[winid] = Window.new(winid)
  end
  return M.instances[winid]
end

---Resolve the Window for the current Neovim context.
---If the current window is one of our popups, use its recorded root_winid;
---otherwise use the current window itself as the root.
---@return OverlookWindow
function M.current()
  local winid
  if vim.w.is_overlook_popup then
    winid = vim.w.overlook_popup.root_winid
  else
    winid = api.nvim_get_current_win()
  end
  return M.get(winid)
end

---Open a popup in the current context's window stack. The single entry point
---peek sources use: they build OverlookPopupOptions and hand them here, so a
---source never has to know about the Window/Stack/Popup layering.
---@param opts OverlookPopupOptions
---@return OverlookPopup?
function M.open_popup(opts)
  return M.current():open_popup(opts)
end

---Construct + open a popup using this Window's current context (host, top
---of stack as prev, current depth). Returns the popup on success, nil on
---failure. Shared between open_popup (push semantics) and restore_one
---(trash/restore_item semantics); the only difference between the two paths
---is the stack action, not the construction.
---@param opts OverlookPopupOptions
---@param enter? boolean  passed through to Popup:open
---@return OverlookPopup?
function Window:_spawn_popup(opts, enter)
  local Popup = require("overlook.popup")
  local ctx = {
    root_winid = self.winid,
    prev = self.stack:top(),
    depth = self.stack:size(),
  }
  local popup = Popup.new(opts, ctx)
  if not popup then
    return nil
  end
  if not popup:open(enter) then
    return nil
  end
  -- Force the float-layout pass to settle before returning. Without this, a
  -- subsequent popup that anchors to this one (whether the next iteration of
  -- restore_all's loop or the user's next peek_cursor keystroke deep in the
  -- chain) can read this popup's position as still-provisional and collapse
  -- near the editor origin. Restore_all is the same bug at scale; interactive
  -- peek hits it at depth 5+ in busy configs. Cheap; nvim was going to redraw
  -- on idle anyway.
  vim.cmd.redraw()
  return popup
end

---Creates and pushes a popup onto this Window's stack. Behavior matches the
---deleted ui.create_popup. The receiver `self` corresponds to the host
---window resolved by the caller (typically `Window.current()`), which is the
---same root window Popup.new derives `popup.root_winid` from.
---@param opts OverlookPopupOptions
---@return OverlookPopup?
function Window:open_popup(opts)
  local popup = self:_spawn_popup(opts, true)
  if popup then
    self.stack:push(popup)
  end
  return popup
end

---Promote the top popup to a real window via the given command (split/vsplit/tabnew/buffer).
---Behavior matches the deleted ui.promote_popup_to_window.
---@param open_command string Vim command, e.g. "split | buffer" or "buffer".
function Window:promote(open_command)
  local Popup = require("overlook.popup")
  if self.stack:empty() or not vim.w.is_overlook_popup then
    vim.notify("Overlook: No popup to promote.", vim.log.levels.INFO)
    return
  end

  local buf_id = api.nvim_get_current_buf()
  ---@diagnostic disable-next-line: unused-local
  local _bufnum, lnum, col, _off = unpack(vim.fn.getpos("."))

  self:close_all()

  if not buf_id or not api.nvim_buf_is_valid(buf_id) then
    vim.notify(
      string.format("Overlook Error: Buffer to promote is invalid (ID: %s).", tostring(buf_id)),
      vim.log.levels.ERROR
    )
    return
  end

  local cmd = string.format("%s %d", open_command, buf_id)
  ---@diagnostic disable-next-line: param-type-mismatch
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify(
      string.format("Overlook Error: Failed to execute command '%s': %s", cmd, tostring(err)),
      vim.log.levels.ERROR
    )
    return
  end

  Popup.set_cursor_position(0, lnum, col)
  vim.bo.buflisted = true
end

---Events suppressed for the duration of a bulk operation: the transient focus
---walk across popups/splits must not wake focus-reactive plugins (focus.nvim
---resizing the host, etc.). WinClosed is deliberately NOT in this list --
---other plugins legitimately track window closes, so those events keep firing;
---our own re-entrant reconciliation is prevented by the _reconcile_suspended
---flag instead (see Window:on_popup_closed).
local BULK_IGNORED_EVENTS = { "WinEnter", "WinLeave", "BufEnter", "BufWinEnter" }

---Run fn with focus events suppressed and WinClosed reconciliation suspended.
---Snapshots the caller's eventignore and restores it verbatim even if fn
---throws -- the naive `:remove(list)` would strip entries the user or another
---plugin had set before our call. We only own the global option;
---vim.b.eventignore / vim.wo.eventignorewin are out of scope. The caller
---decides whether to swallow or re-raise the error.
---@param fn fun()
---@return boolean ok, any err
function Window:_with_bulk_guard(fn)
  local saved = vim.opt.eventignore:get()
  vim.opt.eventignore:append(BULK_IGNORED_EVENTS)
  self._reconcile_suspended = true

  local ok, err = pcall(fn)

  self._reconcile_suspended = false
  vim.opt.eventignore = saved
  return ok, err
end

---Close all popups in this Window's stack atomically. Focus events are
---suppressed during the bulk close so the transient focus Neovim assigns
---while closing (often a neighbouring split) doesn't wake a focus-reactive
---plugin (e.g. focus.nvim resizing the host); WinClosed fires normally for
---other plugins while our own reconciliation is suspended via the bulk guard.
---On a loop error the guard still restores eventignore, then the error is
---re-raised so callers (Window:promote) abort as before. Focus is then set
---deliberately to the host, and the dynamic close-keymap refresh is scheduled
---explicitly -- the final set_current_win is a no-op (firing no WinEnter)
---when focus is already on the host.
function Window:close_all()
  local ok, err = self:_with_bulk_guard(function()
    while not self.stack:empty() do
      local top = self.stack:top()
      if top then
        top:close()
      end
      self.stack:pop()
    end
  end)

  if not ok then
    error(err, 0)
  end

  pcall(api.nvim_set_current_win, self.winid)
  vim.schedule(function()
    require("overlook.state").update_keymap()
  end)
end

---Pop popups from the top while the top popup's window is invalid.
---Used as a reconciliation safety net.
function Window:prune_invalid()
  while not self.stack:empty() do
    local top = self.stack:top()
    if top and top:is_valid() then
      return
    end
    self.stack:pop()
  end
end

---WinClosed reconciliation: a popup window is already gone; bring the stack in sync.
---Always refocuses (the closed window was typically the focused one).
---@param winid integer The closed popup's window id.
function Window:on_popup_closed(winid)
  if self._reconcile_suspended then
    return -- a bulk op owns the stack right now; it does its own bookkeeping
  end
  self.stack:remove_by_winid(winid)
  self:prune_invalid()

  local top = self.stack:top()
  if top and top:is_valid() then
    top:focus()
  else
    pcall(api.nvim_set_current_win, self.winid)

    local config = require("overlook.config").get()
    if type(config.on_stack_empty) == "function" then
      local ok, err = pcall(config.on_stack_empty)
      if not ok then
        vim.notify("Overlook Error: on_stack_empty callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  vim.schedule(function()
    require("overlook.state").update_keymap()
  end)
end

---Restore the most-recently-trashed popup. Internal helper shared by restore()
---and restore_all(). Reopens at the host's CURRENT cursor (recomputed via
---config_for_first_popup), same as a fresh peek -- consistent placement
---semantics with open_popup. `enter` controls whether the reopened popup
---grabs focus.
---@param enter boolean
---@return OverlookPopup? restored, boolean had_trash
function Window:restore_one(enter)
  local data = self.stack:peek_trash()
  if not data then
    return nil, false
  end

  local restored = self:_spawn_popup(data.opts, enter)
  if not restored then
    return nil, true -- had trash, but the reopen failed
  end

  self.stack:pop_trash()
  self.stack:restore_item(restored)
  return restored, true
end

---Restore the most recently closed popup and focus it.
function Window:restore()
  local restored, had_trash = self:restore_one(true)
  if not had_trash then
    vim.notify("Overlook: No popup to restore", vim.log.levels.WARN)
  elseif not restored then
    vim.notify("Overlook: Failed to restore popup", vim.log.levels.ERROR)
  end
end

---Restore all previously closed popups. Each is reopened with enter=true so
---nvim runs the layout pass that anchors a relative="win" float against the
---host's CURRENT position -- with enter=false, the layout pass is skipped and
---the float gets stuck at whatever transient anchor position existed at the
---instant of nvim_open_win. The bulk guard keeps focus-reactive plugins
---(focus.nvim, etc.) from observing the transient focus walk across the
---restored popups and suspends WinClosed reconciliation, so a stray close
---fired during the redraw between iterations can't prune the just-restored
---prev out from under the next iteration's anchor (prune_invalid catches the
---stale entry later). Focus ends on the top popup (the last enter=true).
function Window:restore_all()
  local restored_any = false
  local ok, err = self:_with_bulk_guard(function()
    while true do
      local before = self.stack:peek_trash()
      if not before then
        return -- trash empty; done
      end
      self:restore_one(true)
      if self.stack:peek_trash() == before then
        return -- reopen failed; top of trash unchanged. stop.
      end
      restored_any = true
      -- Layout-settle redraw happens inside Window:_spawn_popup (called by
      -- restore_one) so each restored popup's position is resolved before the
      -- next iteration anchors to it.
    end
  end)

  if not ok then
    vim.notify("Overlook: restore_all error: " .. tostring(err), vim.log.levels.ERROR)
  end

  if restored_any then
    local top = self.stack:top()
    if top then
      top:focus()
    end
    vim.schedule(function()
      require("overlook.state").update_keymap()
    end)
  end
end

---Toggle focus between the top popup and the root window.
function Window:switch_focus()
  if vim.w.is_overlook_popup then
    pcall(api.nvim_set_current_win, self.winid)
    return
  end
  local top = self.stack:top()
  if top then
    top:focus()
  else
    vim.notify("Overlook: no popup to focus", vim.log.levels.INFO)
  end
end

---@return OverlookPopup?
function Window:top()
  return self.stack:top()
end

---@return integer
function Window:size()
  return self.stack:size()
end

---@return boolean
function Window:empty()
  return self.stack:empty()
end

---Scan all hosts for a popup with this winid. Used by the WinClosed autocmd.
---Iterates every position in every stack (not just tops) because non-top popups
---can close (see spec §5). Reaps stale Window entries (host winid invalid AND
---both stack and trash empty) as a side effect so M.instances stays bounded
---over long sessions instead of growing one entry per host the user ever
---peeked into.
---@param winid integer
---@return OverlookWindow?
function M.find_by_popup_winid(winid)
  for host_winid, w in pairs(M.instances) do
    if not api.nvim_win_is_valid(host_winid) and #w.stack.items == 0 and #w.stack.trash == 0 then
      M.instances[host_winid] = nil
    else
      for _, item in ipairs(w.stack.items) do
        if item.winid == winid then
          return w
        end
      end
    end
  end
  return nil
end

return M
