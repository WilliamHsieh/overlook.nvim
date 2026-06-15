describe("overlook.peek.definition", function()
  local definition
  local open_popup_calls
  local notify_calls
  local original_notify
  local original_lsp_definition
  local original_uri_to_bufnr

  before_each(function()
    open_popup_calls = {}
    notify_calls = {}

    package.loaded["overlook.window"] = {
      open_popup = function(opts)
        table.insert(open_popup_calls, opts)
      end,
    }

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    original_lsp_definition = vim.lsp.buf.definition
    original_uri_to_bufnr = vim.uri_to_bufnr
    vim.uri_to_bufnr = function(_uri)
      return 4242 -- sentinel so we can assert the mapped buffer
    end

    package.loaded["overlook.peek.definition"] = nil
    definition = require("overlook.peek.definition")
  end)

  after_each(function()
    vim.notify = original_notify
    vim.lsp.buf.definition = original_lsp_definition
    vim.uri_to_bufnr = original_uri_to_bufnr
    package.loaded["overlook.window"] = nil
    package.loaded["overlook.peek.definition"] = nil
  end)

  it("opens a popup from the first LSP result", function()
    vim.lsp.buf.definition = function(o)
      o.on_list {
        items = {
          { lnum = 12, col = 7, filename = "target.lua", user_data = { uri = "file:///tmp/target.lua" } },
        },
      }
    end

    definition()

    assert.are.equal(1, #open_popup_calls)
    local o = open_popup_calls[1]
    assert.are.equal(4242, o.target_bufnr)
    assert.are.equal(12, o.lnum)
    assert.are.equal(7, o.col)
    assert.are.equal("target.lua", o.title)
    assert.are.equal(0, #notify_calls)
  end)

  it("notifies INFO and does not open (no crash) on empty results", function()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = {} }
    end

    local ok = pcall(definition)

    assert.is_true(ok)
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("No definition found", notify_calls[1].msg)
    assert.are.equal(vim.log.levels.INFO, notify_calls[1].level)
  end)

  it("notifies WARN and does not open when the item has no URI", function()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = { { lnum = 1, col = 1, filename = "x", user_data = {} } } }
    end

    local ok = pcall(definition)

    assert.is_true(ok)
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("No URI", notify_calls[1].msg)
    assert.are.equal(vim.log.levels.WARN, notify_calls[1].level)
  end)
end)
