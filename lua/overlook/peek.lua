local Config = require("overlook.config")

local M = {}

local default_adapters = {
  marks = require("overlook.adapter.marks"),
  definition = require("overlook.adapter.definition"),
  cursor = require("overlook.adapter.cursor"),
}

local get_adapter_if_valid = function(adapter)
  if adapter == nil then
    return nil
  end

  if adapter.async then
    if not adapter.async_create_popup then
      return nil
    end
  else
    -- TODO: rename get to sync_get_popup_options
    if not (type(adapter.get) == "function") then
      return nil
    end
  end

  return adapter
end

--- Generic peek function that calls the appropriate adapter's get() method
--- @param adapter_type string The type of adapter ('marks', 'definition', etc.)
--- @param ... any Arguments to pass to the adapter's get() function
local function peek_with_adapters(adapter_type, ...)
  local adapter = get_adapter_if_valid(Config.get().adapters[adapter_type])
    or get_adapter_if_valid(default_adapters[adapter_type])

  if not adapter then
    vim.notify(
      "Overlook Error: Invalid adapter type or adapter missing get() function: " .. adapter_type,
      vim.log.levels.ERROR
    )
    return
  end

  -- async adapters
  if adapter.async then
    adapter.async_create_popup(function(opts)
      require("overlook.window").current():open_popup(opts)
    end, ...)
    return
  end

  -- synchronous adapters
  ---@type OverlookPopupOptions?
  local opts = adapter.get(...)
  if not opts then
    vim.notify("Overlook Error: Adapter '" .. adapter_type .. "' returned nil options.", vim.log.levels.ERROR)
    return
  end

  require("overlook.window").current():open_popup(opts)
end

setmetatable(M, {
  __index = function(_, key)
    return function(...)
      return peek_with_adapters(key, ...)
    end
  end,
})

return M
