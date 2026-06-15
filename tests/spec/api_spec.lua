describe("overlook.api peek_mark", function()
  local api_mod
  local marks_calls
  local notify_calls
  local original_notify
  local original_ui_input
  local ui_input_cb

  before_each(function()
    marks_calls = {}
    notify_calls = {}

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    -- peek_mark lazily requires the marks source; stub it so we observe calls.
    package.loaded["overlook.peek.marks"] = function(...)
      table.insert(marks_calls, { ... })
    end
    package.loaded["overlook.window"] = {
      current = function()
        return {}
      end,
    }

    -- Capture the vim.ui.input callback instead of actually prompting.
    original_ui_input = vim.ui.input
    ui_input_cb = nil
    vim.ui.input = function(_opts, cb)
      ui_input_cb = cb
    end

    package.loaded["overlook.api"] = nil
    api_mod = require("overlook.api")
  end)

  after_each(function()
    vim.notify = original_notify
    vim.ui.input = original_ui_input
    package.loaded["overlook.peek.marks"] = nil
    package.loaded["overlook.window"] = nil
    package.loaded["overlook.api"] = nil
  end)

  -- Regression: peek_mark used to call Peek.marks() with no argument BEFORE
  -- prompting, which fired marks.get(nil) -> "Invalid mark character" plus a
  -- second "returned nil options" ERROR on every invocation.
  it("does not invoke the marks adapter (or notify) before a char is entered", function()
    api_mod.peek_mark()
    assert.are.equal(0, #marks_calls)
    assert.are.equal(0, #notify_calls)
  end)

  it("invokes marks exactly once with the entered char", function()
    api_mod.peek_mark()
    ui_input_cb("a")
    assert.are.equal(1, #marks_calls)
    assert.are.same({ "a" }, marks_calls[1])
    assert.are.equal(0, #notify_calls)
  end)

  it("notifies and does not peek on multi-character input", function()
    api_mod.peek_mark()
    ui_input_cb("ab")
    assert.are.equal(0, #marks_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("Invalid mark", notify_calls[1].msg)
  end)

  it("does nothing on cancelled / empty input", function()
    api_mod.peek_mark()
    ui_input_cb(nil)
    api_mod.peek_mark()
    ui_input_cb("")
    assert.are.equal(0, #marks_calls)
    assert.are.equal(0, #notify_calls)
  end)
end)
