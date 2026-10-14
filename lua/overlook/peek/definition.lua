local location = require("overlook.peek.location")

--- Peek at the LSP definition under the cursor. Asynchronous: the popup opens
--- from the LSP on_list callback once the server responds. A single result
--- opens directly. Several results follow `on_multiple` (see |overlook-config|).
--- Guards the common "no definition" / malformed-result cases and does not
--- open a popup in those cases.
---
--- `location_opts` is forwarded to `vim.lsp.buf.definition`. A caller-supplied
--- `on_list` is ignored and replaced with Overlook's handler.
---@param location_opts? vim.lsp.LocationOpts Forwarded to `vim.lsp.buf.definition`. `on_list` is ignored and overridden.
---@return nil
return function(location_opts)
  vim.lsp.buf.definition(vim.tbl_extend("force", location_opts or {}, {
    on_list = function(tt)
      location.open(tt and tt.items, {
        empty_message = "Overlook: No definition found.",
        no_uri_message = "Overlook: No URI found in LSP definition item.",
        prompt = "Overlook: Select definition",
        kind = "overlook.definition",
      })
    end,
  }))
end
