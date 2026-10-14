--- Resolve an LSP location list into an Overlook popup.
---
--- Definition uses this helper. A references or implementation source can call
--- `open` from its own `on_list` callback with a different empty message and
--- prompt; see |overlook-peek|.
---
--- One item opens immediately. Several items follow |OverlookOnMultiple|
--- (`on_multiple` in |overlook-config|):
--- - `"select"` (default) calls `vim.ui.select`. Entries are
---   `relative/path:line: text` (path relative to the working directory, line
---   text trimmed).
--- - `"first"` opens the first item.
--- - a function is called as `on_multiple(items, open_fn)`. `open_fn(item)`
---   opens that item through |overlook.window.open_popup|.
local M = {}

---@class OverlookLocationOpenOpts
---@field empty_message? string Notification (INFO) when `items` is empty.
---@field no_uri_message? string Notification (WARN) when the chosen item has no URI.
---@field prompt? string Prompt passed to `vim.ui.select`.
---@field kind? string Kind hint passed to `vim.ui.select`.

--- Format one quickfix-style LSP item for `vim.ui.select`.
---
--- Shape: `relative/path:line: text`. The path is relative to the working
--- directory when the file is under it. Line text is trimmed.
---@param item table
---@return string
function M.format_item(item)
  if type(item) ~= "table" then
    return ""
  end

  local filename = item.filename or ""
  local relative = filename == "" and "" or vim.fn.fnamemodify(filename, ":.")
  local lnum = tonumber(item.lnum) or 0
  local text = type(item.text) == "string" and vim.trim(item.text) or ""
  return string.format("%s:%d: %s", relative, lnum, text)
end

--- Open one LSP location item in a popup.
---
--- The URI is read from `user_data.targetUri` (LocationLink) or
--- `user_data.uri` (Location), which is where Neovim stores the original LSP
--- location on a quickfix item.
---@param item table
---@param no_uri_message? string
---@return boolean opened
function M.open_item(item, no_uri_message)
  if type(item) ~= "table" then
    return false
  end

  local user_data = item.user_data
  local uri = type(user_data) == "table" and (user_data.targetUri or user_data.uri) or nil
  if not uri then
    vim.notify(no_uri_message or "Overlook: No URI found in LSP location item.", vim.log.levels.WARN)
    return false
  end

  require("overlook.window").open_popup {
    target_bufnr = vim.uri_to_bufnr(uri),
    lnum = item.lnum,
    col = item.col,
    title = item.filename,
  }
  return true
end

--- Resolve `on_multiple`, warning when the configured value is not recognized.
--- `nil` is treated as the default `"select"` so a partial config still prompts.
---@param value any
---@return "select"|"first"|fun(items: table[], open_fn: fun(item: table))
local function resolve_on_multiple(value)
  if value == nil or value == "select" then
    return "select"
  end
  if value == "first" or type(value) == "function" then
    return value
  end

  vim.notify("Overlook: unknown on_multiple (" .. tostring(value) .. "); using vim.ui.select.", vim.log.levels.WARN)
  return "select"
end

--- Open a popup for an LSP location list.
---
--- - Zero items: notify `empty_message` and return.
--- - One item: open it directly, with no prompt.
--- - Several items: follow |OverlookOnMultiple|.
---
--- Cancelling `vim.ui.select` (or calling `open_fn` with `nil`) opens nothing.
---@param items? table[] Quickfix-style items from an LSP `on_list` callback.
---@param opts? OverlookLocationOpenOpts
---@return nil
function M.open(items, opts)
  opts = opts or {}
  if type(items) ~= "table" or #items == 0 then
    vim.notify(opts.empty_message or "Overlook: No location found.", vim.log.levels.INFO)
    return
  end

  if #items == 1 then
    M.open_item(items[1], opts.no_uri_message)
    return
  end

  local on_multiple = resolve_on_multiple(require("overlook.config").get().on_multiple)

  local function open_chosen(item)
    if item == nil then
      return
    end
    M.open_item(item, opts.no_uri_message)
  end

  if on_multiple == "first" then
    open_chosen(items[1])
    return
  end

  if type(on_multiple) == "function" then
    on_multiple(items, open_chosen)
    return
  end

  vim.ui.select(items, {
    prompt = opts.prompt or "Overlook: Select location",
    format_item = M.format_item,
    kind = opts.kind or "overlook.location",
  }, function(choice)
    open_chosen(choice)
  end)
end

return M
