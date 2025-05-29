local M = {}

local adapters = {
  marks = require("overlook.adapter.marks"),
  definition = require("overlook.adapter.definition"),
  cursor = require("overlook.adapter.cursor"),
}

--- Generic peek function that calls the appropriate adapter's get() method
--- @param adapter_type string The type of adapter ('marks', 'definition', etc.)
--- @param ... any Arguments to pass to the adapter's get() function
local function peek_with_adapters(adapter_type, ...)
  local adapter = adapters[adapter_type]
  if not adapter or type(adapter.get) ~= "function" then
    vim.notify(
      "Overlook Error: Invalid adapter type or adapter missing get() function: " .. adapter_type,
      vim.log.levels.ERROR
    )
    return
  end

  local opts = adapter.get(...)
  if not opts then
    return
  end

  require("overlook.window").create_popup(opts)
end

setmetatable(M, {
  __index = function(_, key)
    return function(...)
      return peek_with_adapters(key, ...)
    end
  end,
})

return M
