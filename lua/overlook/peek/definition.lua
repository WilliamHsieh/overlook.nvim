--- Peek at the LSP definition under the cursor. Asynchronous: the popup opens
--- from the LSP on_list callback once the server responds. Guards the common
--- "no definition" / malformed-result cases and simply does not open a popup
--- in those cases.
---@param location_opts? vim.lsp.LocationOpts
---@return nil
return function(location_opts)
  location_opts = location_opts or {}

  vim.lsp.buf.definition {
    on_list = function(tt)
      local item = tt and tt.items and tt.items[1]
      if not item then
        vim.notify("Overlook: No definition found.", vim.log.levels.INFO)
        return
      end

      local uri = item.user_data and (item.user_data.targetUri or item.user_data.uri)
      if not uri then
        vim.notify("Overlook: No URI found in LSP definition item.", vim.log.levels.WARN)
        return
      end

      require("overlook.window").open_popup {
        target_bufnr = vim.uri_to_bufnr(uri),
        lnum = item.lnum,
        col = item.col,
        title = item.filename,
      }
    end,
  }
end
