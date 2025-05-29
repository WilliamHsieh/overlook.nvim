describe("overlook.peek", function()
  local peek_mod
  local mock_marks_adapter
  local mock_ui
  local create_popup_calls
  local marks_get_calls

  -- Mock vim.notify
  local notify_calls = {}
  local original_notify = vim.notify
  local mock_notify = function(msg, level, opts)
    table.insert(notify_calls, { msg = msg, level = level, opts = opts })
  end

  before_each(function()
    notify_calls = {}
    vim.notify = mock_notify

    -- Mock dependencies
    marks_get_calls = {}
    mock_marks_adapter = {
      get = function(...)
        table.insert(marks_get_calls, { ... })
        -- Default mock behavior: return a dummy opts table
        return { target_bufnr = 1, lnum = 1, col = 1, title = "mock" }
      end,
    }

    create_popup_calls = {}
    mock_ui = {
      create_popup = function(opts)
        table.insert(create_popup_calls, opts)
      end,
    }

    -- Inject mocks using package.loaded trick
    package.loaded["overlook.adapter.marks"] = mock_marks_adapter
    package.loaded["overlook.window"] = mock_ui

    -- Reload the peek module to use the mocks
    package.loaded["overlook.peek"] = nil
    peek_mod = require("overlook.peek")
  end)

  after_each(function()
    -- Restore originals
    vim.notify = original_notify
    package.loaded["overlook.adapter.marks"] = nil
    package.loaded["overlook.window"] = nil
    package.loaded["overlook.peek"] = nil
  end)

  it("should call the correct adapter's get method and ui.create_popup", function()
    local mark_char = "m"
    local expected_opts = { target_bufnr = 123, lnum = 45, col = 6, title = "test_mark" }

    -- Override mock get for this specific test
    mock_marks_adapter.get = function(arg)
      table.insert(marks_get_calls, { arg })
      if arg == mark_char then
        return expected_opts
      end
      return nil
    end

    peek_mod.marks(mark_char)

    -- Check adapter was called correctly
    assert.are.equal(1, #marks_get_calls)
    assert.are.same({ mark_char }, marks_get_calls[1])

    -- Check UI was called correctly
    assert.are.equal(1, #create_popup_calls)
    assert.are.same(expected_opts, create_popup_calls[1])

    -- Check no errors notified
    assert.are.equal(0, #notify_calls)
  end)

  it("should notify and return if adapter type is invalid", function()
    peek_mod.peek("invalid_adapter", "a")

    assert.are.equal(1, #notify_calls)
    assert.matches("Invalid adapter type", notify_calls[1].msg)
    assert.are.equal(0, #marks_get_calls)
    assert.are.equal(0, #create_popup_calls)
  end)

  it("should notify and return if adapter is missing get method", function()
    -- Temporarily break the mock adapter
    package.loaded["overlook.adapter.marks"] = { not_get = function() end }
    package.loaded["overlook.peek"] = nil
    peek_mod = require("overlook.peek")

    peek_mod.marks("a")

    assert.are.equal(1, #notify_calls)
    assert.matches("Invalid adapter type or adapter missing get().*marks", notify_calls[1].msg)
    assert.are.equal(0, #create_popup_calls)

    -- Restore for subsequent tests (important!)
    package.loaded["overlook.adapter.marks"] = mock_marks_adapter
  end)

  it("should return without calling popup if adapter's get returns nil", function()
    -- Mock get to return nil
    mock_marks_adapter.get = function(...)
      table.insert(marks_get_calls, { ... })
      return nil -- Simulate adapter handling an error/no data
    end

    peek_mod.marks("z")

    assert.are.equal(1, #marks_get_calls) -- Adapter get should still be called
    assert.are.equal(0, #create_popup_calls) -- UI should NOT be called
    assert.are.equal(0, #notify_calls) -- Peek module itself shouldn't notify
  end)
end)
