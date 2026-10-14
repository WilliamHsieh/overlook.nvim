describe("overlook.peek.definition", function()
  local definition
  local open_popup_calls
  local notify_calls
  local select_calls
  local seen_uris
  local on_multiple
  local original_notify
  local original_lsp_definition
  local original_uri_to_bufnr
  local original_ui_select
  local original_config

  local function lsp_item(overrides)
    return vim.tbl_extend("force", {
      lnum = 1,
      col = 1,
      filename = "target.lua",
      text = "return target",
      user_data = { uri = "file:///tmp/target.lua" },
    }, overrides or {})
  end

  local function two_definitions()
    local cwd = vim.fn.getcwd()
    local first = lsp_item {
      filename = cwd .. "/src/widget.cpp",
      lnum = 10,
      col = 3,
      text = "  void Widget::draw()",
      user_data = { uri = "file:///src/widget.cpp" },
    }
    local second = lsp_item {
      filename = cwd .. "/src/widget.h",
      lnum = 4,
      col = 8,
      text = "void Widget::draw();",
      user_data = { targetUri = "file:///src/widget.h" },
    }
    return first, second
  end

  before_each(function()
    open_popup_calls = {}
    notify_calls = {}
    select_calls = {}
    seen_uris = {}
    on_multiple = "select"

    package.loaded["overlook.window"] = {
      open_popup = function(opts)
        table.insert(open_popup_calls, opts)
      end,
    }

    original_config = package.loaded["overlook.config"]
    package.loaded["overlook.config"] = {
      get = function()
        return { on_multiple = on_multiple }
      end,
    }

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    original_ui_select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      table.insert(select_calls, { items = items, opts = opts, on_choice = on_choice })
    end

    original_lsp_definition = vim.lsp.buf.definition
    original_uri_to_bufnr = vim.uri_to_bufnr
    vim.uri_to_bufnr = function(uri)
      table.insert(seen_uris, uri)
      return 4242 -- sentinel so we can assert the mapped buffer
    end

    package.loaded["overlook.peek.location"] = nil
    package.loaded["overlook.peek.definition"] = nil
    definition = require("overlook.peek.definition")
  end)

  after_each(function()
    vim.notify = original_notify
    vim.ui.select = original_ui_select
    vim.lsp.buf.definition = original_lsp_definition
    vim.uri_to_bufnr = original_uri_to_bufnr
    package.loaded["overlook.config"] = original_config
    package.loaded["overlook.window"] = nil
    package.loaded["overlook.peek.location"] = nil
    package.loaded["overlook.peek.definition"] = nil
  end)

  it("opens a popup directly when there is a single result", function()
    vim.lsp.buf.definition = function(o)
      o.on_list {
        items = {
          { lnum = 12, col = 7, filename = "target.lua", user_data = { uri = "file:///tmp/target.lua" } },
        },
      }
    end

    definition()

    assert.are.equal(0, #select_calls)
    assert.are.equal(1, #open_popup_calls)
    local o = open_popup_calls[1]
    assert.are.equal(4242, o.target_bufnr)
    assert.are.equal(12, o.lnum)
    assert.are.equal(7, o.col)
    assert.are.equal("target.lua", o.title)
    assert.are.equal("file:///tmp/target.lua", seen_uris[1])
    assert.are.equal(0, #notify_calls)
  end)

  it("prompts with vim.ui.select for multiple results and opens the choice", function()
    local first, second = two_definitions()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = { first, second } }
    end

    definition()

    assert.are.equal(1, #select_calls)
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(0, #notify_calls)

    local call = select_calls[1]
    assert.are.equal(first, call.items[1])
    assert.are.equal(second, call.items[2])
    assert.are.equal("Overlook: Select definition", call.opts.prompt)
    assert.are.equal("overlook.definition", call.opts.kind)
    assert.are.equal("src/widget.cpp:10: void Widget::draw()", call.opts.format_item(first))
    assert.are.equal("src/widget.h:4: void Widget::draw();", call.opts.format_item(second))

    call.on_choice(second)

    assert.are.equal(1, #open_popup_calls)
    local o = open_popup_calls[1]
    assert.are.equal(4242, o.target_bufnr)
    assert.are.equal(4, o.lnum)
    assert.are.equal(8, o.col)
    assert.are.equal(second.filename, o.title)
    assert.are.equal("file:///src/widget.h", seen_uris[1])
  end)

  it("opens nothing when vim.ui.select is cancelled", function()
    local first, second = two_definitions()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = { first, second } }
    end

    definition()
    select_calls[1].on_choice(nil)

    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(0, #notify_calls)
  end)

  it("opens the first location when on_multiple is 'first'", function()
    on_multiple = "first"
    local first, second = two_definitions()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = { first, second } }
    end

    definition()

    assert.are.equal(0, #select_calls)
    assert.are.equal(1, #open_popup_calls)
    assert.are.equal(10, open_popup_calls[1].lnum)
    assert.are.equal(3, open_popup_calls[1].col)
    assert.are.equal(first.filename, open_popup_calls[1].title)
    assert.are.equal("file:///src/widget.cpp", seen_uris[1])
    assert.are.equal(0, #notify_calls)
  end)

  it("calls a custom on_multiple function with the items and an opener", function()
    local seen
    on_multiple = function(items, open_fn)
      seen = { items = items, open_fn = open_fn }
      open_fn(items[2])
    end
    local first, second = two_definitions()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = { first, second } }
    end

    definition()

    assert.are.equal(0, #select_calls)
    assert.are.equal(first, seen.items[1])
    assert.are.equal(second, seen.items[2])
    assert.are.equal("function", type(seen.open_fn))
    assert.are.equal(1, #open_popup_calls)
    assert.are.equal(4, open_popup_calls[1].lnum)
    assert.are.equal("file:///src/widget.h", seen_uris[1])
    assert.are.equal(0, #notify_calls)
  end)

  it("opens nothing when a custom handler calls open_fn(nil)", function()
    on_multiple = function(items, open_fn)
      open_fn(nil)
    end
    local first, second = two_definitions()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = { first, second } }
    end

    definition()

    assert.are.equal(0, #select_calls)
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(0, #notify_calls)
  end)

  it("falls back to vim.ui.select when on_multiple is not recognized", function()
    on_multiple = "quickfix"
    local first, second = two_definitions()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = { first, second } }
    end

    definition()

    assert.are.equal(1, #notify_calls)
    assert.matches("on_multiple", notify_calls[1].msg)
    assert.are.equal(vim.log.levels.WARN, notify_calls[1].level)
    assert.are.equal(1, #select_calls)
    assert.are.equal(0, #open_popup_calls)
  end)

  it("forwards location opts and keeps Overlook's on_list handler", function()
    local received
    vim.lsp.buf.definition = function(o)
      received = o
      o.on_list { items = {} }
    end

    definition { reuse_win = true, on_list = function() end }

    assert.is_true(received.reuse_win)
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("No definition found", notify_calls[1].msg)
  end)

  it("notifies INFO and does not open (no crash) on empty results", function()
    vim.lsp.buf.definition = function(o)
      o.on_list { items = {} }
    end

    local ok = pcall(definition)

    assert.is_true(ok)
    assert.are.equal(0, #select_calls)
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
