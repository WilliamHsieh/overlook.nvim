describe("Cursor Adapter", function()
  local peek_mod = require("overlook.peek")
  local ui_mod = require("overlook.window")

  local original_create_popup
  local original_notify
  local mock_calls
  local original_get_current_buf -- Store original vim.api.nvim_get_current_buf
  local original_getpos -- Store original vim.fn.getpos

  before_each(function()
    -- Reset mock calls table
    mock_calls = {
      create_popup = {},
      notify = {},
    }

    -- Store and mock ui.create_popup
    original_create_popup = ui_mod.create_popup
    ui_mod.create_popup = function(opts)
      table.insert(mock_calls.create_popup, opts)
    end

    -- Store and mock vim.notify
    original_notify = vim.notify
    vim.notify = function(msg, level, opts)
      table.insert(mock_calls.notify, { msg = msg, level = level, opts = opts })
    end

    -- Store and mock vim.api.nvim_get_current_buf
    original_get_current_buf = vim.api.nvim_get_current_buf
    vim.api.nvim_get_current_buf = function()
      -- This will be overridden in the specific test that creates a buffer
      return 0 -- Default mock for tests that don't care or handle unnamed
    end

    -- Store and mock vim.fn.getpos
    original_getpos = vim.fn.getpos
    vim.fn.getpos = function(target)
      if target == "." then
        -- This will be overridden in the specific test that sets cursor
        return { 0, 1, 1, 0 } -- Default mock
      end
      return original_getpos(target) -- Call original for other targets
    end
  end)

  after_each(function()
    -- Restore original functions
    if original_create_popup then
      ui_mod.create_popup = original_create_popup
    end
    if original_notify then
      vim.notify = original_notify
    end
    original_create_popup = nil
    original_notify = nil

    if original_get_current_buf then
      vim.api.nvim_get_current_buf = original_get_current_buf
    end
    original_get_current_buf = nil

    if original_getpos then
      vim.fn.getpos = original_getpos
    end
    original_getpos = nil

    -- Clean up any test buffers if needed
    pcall(vim.cmd, "bw! test_buffer.txt")
    pcall(vim.cmd, "bw!") -- For unnamed buffer test
  end)

  it("should call create_popup with cursor context when peek('cursor') is called", function()
    -- Setup: Create a dummy buffer and set content
    vim.cmd("edit! test_buffer.txt")
    local expected_bufnr = vim.api.nvim_get_current_buf() -- Get the buffer number
    -- Override mocks for this specific test case
    vim.api.nvim_get_current_buf = function()
      return expected_bufnr
    end
    vim.fn.getpos = function(target)
      if target == "." then
        return { expected_bufnr, 3, 5, 0 }
      end
      return { 0, 0, 0, 0 } -- Should not happen in this test flow for '.'
    end

    vim.api.nvim_buf_set_lines(expected_bufnr, 0, -1, false, {
      "line 1",
      "line 2",
      "line 3 is the cursor line",
      "line 4",
      "line 5",
    })
    vim.api.nvim_win_set_cursor(0, { 3, 5 }) -- Set cursor to line 3, column 5

    -- Action
    peek_mod.cursor()

    -- Assert
    assert.are.equal(1, #mock_calls.create_popup)
    local call_args = mock_calls.create_popup[1]
    assert.is_table(call_args)
    assert.matches("test_buffer.txt", call_args.title) -- Expect filename again
    assert.are.equal(expected_bufnr, call_args.target_bufnr) -- target_bufnr should be the actual buffer
    assert.are.equal(3, call_args.lnum)
    assert.are.equal(5, call_args.col) -- Column from getpos is 1-indexed, set_cursor is 0-indexed
    assert.matches("test_buffer.txt", call_args.file_path) -- Check file_path
    assert.is_nil(call_args.content) -- Should not have content
    assert.is_nil(call_args.highlight_line) -- Should not have highlight_line

    -- Teardown (moved to after_each)
    -- vim.cmd("bw! test_buffer.txt")
  end)

  it("should handle unnamed buffers gracefully", function()
    -- Setup: Create an unnamed buffer
    vim.cmd("enew")
    -- Override mocks for this specific test case (unnamed buffer)
    vim.api.nvim_get_current_buf = function()
      return vim.fn.bufnr()
    end -- Use actual current unnamed buf
    vim.fn.getpos = function(target) -- Mock getpos for unnamed buffer scenario
      if target == "." then
        return { vim.fn.bufnr(), 1, 0, 0 }
      end -- e.g. line 1, col 0
      return { 0, 0, 0, 0 }
    end

    assert.equal("", vim.api.nvim_buf_get_name(0))

    -- Action
    peek_mod.cursor()

    -- Assert
    assert.are.equal(0, #mock_calls.create_popup) -- Should not be called
    assert.are.equal(1, #mock_calls.notify)
    local notify_call = mock_calls.notify[1]
    assert.matches("Cannot peek in unnamed buffer", notify_call.msg) -- Use matches for flexibility
    assert.are.equal(vim.log.levels.WARN, notify_call.level)

    -- Teardown (moved to after_each)
    -- vim.cmd("bw!")
  end)
end)
