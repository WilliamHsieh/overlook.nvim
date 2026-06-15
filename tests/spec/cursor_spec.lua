describe("overlook.peek.cursor", function()
  local cursor
  local open_popup_calls
  local notify_calls
  local original_notify
  local original_get_current_buf
  local original_getpos
  local original_buf_get_name

  before_each(function()
    open_popup_calls = {}
    notify_calls = {}

    -- The source hands options to require("overlook.window").open_popup.
    package.loaded["overlook.window"] = {
      open_popup = function(opts)
        table.insert(open_popup_calls, opts)
      end,
    }

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    original_get_current_buf = vim.api.nvim_get_current_buf
    original_getpos = vim.fn.getpos
    original_buf_get_name = vim.api.nvim_buf_get_name

    package.loaded["overlook.peek.cursor"] = nil
    cursor = require("overlook.peek.cursor")
  end)

  after_each(function()
    vim.notify = original_notify
    vim.api.nvim_get_current_buf = original_get_current_buf
    vim.fn.getpos = original_getpos
    vim.api.nvim_buf_get_name = original_buf_get_name
    package.loaded["overlook.window"] = nil
    package.loaded["overlook.peek.cursor"] = nil
    pcall(vim.cmd, "bw! test_buffer.txt")
    pcall(vim.cmd, "bw!")
  end)

  it("opens a popup with cursor context for a named buffer", function()
    vim.cmd("edit! test_buffer.txt")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1", "line 2", "line 3", "line 4", "line 5" })

    vim.api.nvim_get_current_buf = function()
      return bufnr
    end
    vim.fn.getpos = function(target)
      if target == "." then
        return { bufnr, 3, 5, 0 }
      end
      return { 0, 0, 0, 0 }
    end
    vim.api.nvim_buf_get_name = function(b)
      if b == 0 or b == bufnr then
        return "/tmp/test_buffer.txt"
      end
      return original_buf_get_name(b)
    end

    cursor()

    assert.are.equal(1, #open_popup_calls)
    local o = open_popup_calls[1]
    assert.are.equal(bufnr, o.target_bufnr)
    assert.are.equal(3, o.lnum)
    assert.are.equal(5, o.col)
    assert.matches("test_buffer.txt", o.title)
    assert.is_nil(o.file_path) -- file_path was removed from the options shape
    assert.are.equal(0, #notify_calls)
  end)

  it("notifies and does not open for an unnamed buffer", function()
    vim.cmd("enew")
    vim.api.nvim_buf_get_name = function(b)
      if b == 0 then
        return ""
      end
      return original_buf_get_name(b)
    end

    cursor()

    assert.are.equal(0, #open_popup_calls)
    assert.are.equal(1, #notify_calls)
    assert.matches("Cannot peek in unnamed buffer", notify_calls[1].msg)
    assert.are.equal(vim.log.levels.WARN, notify_calls[1].level)
  end)
end)
