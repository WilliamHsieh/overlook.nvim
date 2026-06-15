local api = vim.api

describe("overlook.peek.marks", function()
  local marks
  local open_popup_calls
  local notify_calls
  local original_notify
  local original_buf_is_loaded
  local original_buf_is_valid
  local original_buf_get_name
  local original_getpos

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

    original_buf_is_loaded = api.nvim_buf_is_loaded
    original_buf_is_valid = api.nvim_buf_is_valid
    original_buf_get_name = api.nvim_buf_get_name
    original_getpos = vim.fn.getpos

    package.loaded["overlook.peek.marks"] = nil
    marks = require("overlook.peek.marks")
  end)

  after_each(function()
    vim.notify = original_notify
    api.nvim_buf_is_loaded = original_buf_is_loaded
    api.nvim_buf_is_valid = original_buf_is_valid
    api.nvim_buf_get_name = original_buf_get_name
    vim.fn.getpos = original_getpos
    package.loaded["overlook.window"] = nil
    package.loaded["overlook.peek.marks"] = nil
  end)

  it("notifies and does not open for invalid mark characters", function()
    for _, bad in ipairs { "", "ab" } do
      notify_calls = {}
      marks(bad)
      assert.are.equal(0, #open_popup_calls)
      assert.are.equal(1, #notify_calls)
      assert.matches("Invalid mark character", notify_calls[1].msg)
    end

    notify_calls = {}
    marks(nil)
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("Invalid mark character", notify_calls[1].msg)
  end)

  it("notifies and does not open if the mark is not set", function()
    vim.fn.getpos = function(mark)
      if mark == "'x" then
        return { 0, 0, 0, 0 }
      end
      return original_getpos(mark)
    end

    marks("x")
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("Mark 'x' is not set", notify_calls[1].msg)
  end)

  it("notifies and does not open if the buffer is not loaded", function()
    local mock_bufnr = 999
    vim.fn.getpos = function(mark)
      if mark == "'l" then
        return { mock_bufnr, 10, 5, 0 }
      end
      return original_getpos(mark)
    end
    api.nvim_buf_is_loaded = function(bufnr)
      if bufnr == mock_bufnr then
        return false
      end
      return original_buf_is_loaded(bufnr)
    end

    marks("l")
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("Buffer for mark 'l' is not loaded", notify_calls[1].msg)
  end)

  it("notifies and does not open if the buffer is not valid", function()
    local mock_bufnr = 998
    vim.fn.getpos = function(mark)
      if mark == "'v" then
        return { mock_bufnr, 20, 1, 0 }
      end
      return original_getpos(mark)
    end
    api.nvim_buf_is_loaded = function(bufnr)
      if bufnr == mock_bufnr then
        return true
      end
      return original_buf_is_loaded(bufnr)
    end
    api.nvim_buf_is_valid = function(bufnr)
      if bufnr == mock_bufnr then
        return false
      end
      return original_buf_is_valid(bufnr)
    end

    marks("v")
    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("Buffer for mark 'v' .* is invalid", notify_calls[1].msg)
  end)

  it("opens a popup for a valid mark", function()
    local current_bufnr = api.nvim_get_current_buf()
    local current_buf_name = api.nvim_buf_get_name(current_bufnr)

    vim.fn.getpos = function(mark)
      if mark == "'a" then
        return { current_bufnr, 5, 3, 0 }
      end
      return original_getpos(mark)
    end
    api.nvim_buf_is_loaded = function(bufnr)
      return bufnr == current_bufnr or original_buf_is_loaded(bufnr)
    end
    api.nvim_buf_is_valid = function(bufnr)
      return bufnr == current_bufnr or original_buf_is_valid(bufnr)
    end
    api.nvim_buf_get_name = function(bufnr)
      if bufnr == current_bufnr then
        return current_buf_name
      end
      return original_buf_get_name(bufnr)
    end

    marks("a")

    assert.are.equal(1, #open_popup_calls)
    local o = open_popup_calls[1]
    assert.are.equal(current_bufnr, o.target_bufnr)
    assert.are.equal(5, o.lnum)
    assert.are.equal(3, o.col)
    assert.is_string(o.title)
    assert.are.equal(0, #notify_calls)
  end)
end)
