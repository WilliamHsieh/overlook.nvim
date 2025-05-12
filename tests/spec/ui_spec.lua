---@module "plenary"

--[[-
  Setup critical mocks for modules that are required at the top level by 'overlook.ui'
  or its dependencies (like 'overlook.popup'). This ensures that when these modules
  execute their initial 'require' statements, they get the mocked versions.
--]]
local initial_mock_ui_config_table = {
  border = "double",
  z_index_base = 50,
  col_offset = 1,
  row_offset = 1,
  size_ratio = 0.8,
  min_width = 10, -- Default mock min_width
  min_height = 5, -- Default mock min_height
  width_decrement = 2,
  height_decrement = 1,
  stack_row_offset = 1,
  stack_col_offset = 1,
}
local global_mock_config_data = { ui = initial_mock_ui_config_table }
local global_mock_config_module = {
  options = global_mock_config_data, -- Store the data table here
  get = function()
    return global_mock_config_data -- Always return the same data table
  end,
  -- Helper for tests to reset the mock config to its initial state if needed
  reset_to_initial_state = function()
    global_mock_config_data.ui = vim.deepcopy(initial_mock_ui_config_table)
  end,
}
package.loaded["overlook.config"] = global_mock_config_module

-- Now, when 'overlook.ui' and 'overlook.popup' are required, they'll get the mocked config.
local stack_module_ref_for_reset = require("overlook.stack") -- Keep ref to original for reset
local ui = require("overlook.ui")

local orig_api = {}
local orig_fn = {}

-- Store arguments passed to mocks for assertions
local mock_call_args = {}

-- Helper to reset mocks and stack before each test
local function setup_mocks()
  -- Restore original functions before applying mocks
  for k, v in pairs(orig_api) do
    vim.api[k] = v
  end
  for k, v in pairs(orig_fn) do
    vim.fn[k] = v
  end
  orig_api = {}
  orig_fn = {}
  mock_call_args = { -- Reset args for each test
    nvim_open_win = nil,
    stack_push = nil,
  }

  -- Clear stack state directly (using a local reference to the stack module)
  stack_module_ref_for_reset.stack = {}
  stack_module_ref_for_reset.original_win_id = nil

  -- Reset our global mock config to its defined initial state for consistency
  global_mock_config_module.reset_to_initial_state()

  -- Mock stack module (ensure this is done correctly if stack is also a dependency of popup)
  -- For now, assuming the main issue was config. If stack needs similar pre-mocking, adjust.
  local stack_push_called = false
  local test_mock_stack_mod = {}
  test_mock_stack_mod.size = function()
    return #stack_module_ref_for_reset.stack
  end
  test_mock_stack_mod.push = function(popup_info)
    stack_push_called = true
    mock_call_args.stack_push = vim.deepcopy(popup_info) -- Store args
    table.insert(stack_module_ref_for_reset.stack, popup_info) -- Simulate actual push for size()
  end
  test_mock_stack_mod.top = function()
    if #stack_module_ref_for_reset.stack == 0 then
      return nil
    end
    return stack_module_ref_for_reset.stack[#stack_module_ref_for_reset.stack]
  end
  test_mock_stack_mod.find_by_win = stack_module_ref_for_reset.find_by_win
  test_mock_stack_mod.handle_win_close = stack_module_ref_for_reset.handle_win_close
  test_mock_stack_mod.close_all = stack_module_ref_for_reset.clear -- Assuming stack.clear is the intended function
  test_mock_stack_mod._push_called_flag = function()
    return stack_push_called
  end
  package.loaded["overlook.stack"] = test_mock_stack_mod

  -- Mock essential API calls LAST (Manual Mocks)
  local function mock_api(name, mock_fn_impl) -- Renamed mock_fn to mock_fn_impl
    if vim.api[name] then
      orig_api[name] = vim.api[name]
    end
    vim.api[name] = mock_fn_impl
  end
  local function mock_fn(name, mock_fn_impl) -- Renamed mock_fn to mock_fn_impl
    if vim.fn[name] then
      orig_fn[name] = vim.fn[name]
    end
    vim.fn[name] = mock_fn_impl
  end

  mock_api("nvim_get_current_win", function()
    return 1000
  end)
  mock_api("nvim_win_is_valid", function(win_id)
    return win_id == 1000 or win_id == 1001 or win_id == 999
  end)
  mock_api("nvim_buf_is_valid", function(bufnr)
    return bufnr == 1
  end)
  mock_api("nvim_win_get_cursor", function(_)
    return { 5, 10 }
  end)
  mock_fn("screenpos", function(_, _, _)
    return { row = 6, col = 11 }
  end)
  mock_api("nvim_win_get_position", function(_)
    return { 0, 0 }
  end)
  mock_api("nvim_win_get_height", function(_)
    return 20
  end)
  mock_api("nvim_win_get_width", function(_)
    return 80
  end)
  mock_api("nvim_get_option_value", function(name, _)
    if name == "lines" then
      return 40
    end
    if name == "columns" then
      return 100
    end
    if name == "cmdheight" then
      return 1
    end
    if name == "laststatus" then
      return 2
    end
    if name == "winbar" then
      -- Return empty string for disabled winbar, as per Neovim behavior
      return ""
    end
    return nil
  end)
  mock_api("nvim_open_win", function(bufnr, enter, config)
    mock_call_args.nvim_open_win = { bufnr = bufnr, enter = enter, config = vim.deepcopy(config) }
    return 1001
  end)
  mock_api("nvim_win_get_config", function(_)
    local args = mock_call_args.nvim_open_win
    if args and args.config then
      return vim.tbl_deep_extend("force", args.config, { win = 1001 })
    end
    return {
      relative = "win",
      width = 60,
      height = 15,
      row = 7,
      col = 12,
      border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
      title = "default title",
      title_pos = "center",
      zindex = 50,
    }
  end)
  mock_api("nvim_win_set_cursor", function(_, _)
    return true
  end)
  mock_api("nvim_win_call", function(_, cb)
    if cb then
      cb()
    end
    return true
  end)
  mock_api("nvim_create_autocmd", function(_, _)
    return true
  end)
end

describe("overlook.ui", function()
  before_each(setup_mocks)

  after_each(function()
    -- Restore original functions
    for k, v in pairs(orig_api) do
      vim.api[k] = v
    end
    for k, v in pairs(orig_fn) do
      vim.fn[k] = v
    end
    orig_api = {}
    orig_fn = {}

    -- Reset replaced modules to their state before this spec file's influence
    -- For config, it was mocked globally, so we ensure it's reset or tests might interfere.
    global_mock_config_module.reset_to_initial_state()
    -- If other modules were globally mocked (like stack potentially), reset them too.
    -- For stack, we restore the original module that was loaded by this test file.
    package.loaded["overlook.stack"] = stack_module_ref_for_reset
    collectgarbage()
  end)

  it("should attempt to create a popup with valid buffer", function()
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 5, col = 10 }

    -- Assert
    assert.is_not_nil(result)
    assert.are.equal(1001, result.win_id)
    assert.are.equal(1, result.buf_id)
    assert.is_not_nil(mock_call_args.stack_push)
    assert.is_not_nil(mock_call_args.nvim_open_win)
  end)

  it("should return nil if target buffer is invalid", function()
    -- Arrange: nvim_buf_is_valid is mocked in setup_mocks to only allow buffer 1
    -- Act
    local result = ui.create_popup { target_bufnr = 999, lnum = 1, col = 1 }
    -- Assert
    assert.is_nil(result)
    assert.is_nil(mock_call_args.nvim_open_win) -- Check open_win was NOT called
  end)

  it("should place popup below cursor if cursor is in upper half", function()
    -- Arrange: Default mocks place cursor at row 5/20
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 5, col = 10 }
    -- Assert
    assert.is_not_nil(result)
    assert.is_not_nil(mock_call_args.nvim_open_win)
    local win_config = mock_call_args.nvim_open_win.config
    -- Default cursor screen row is 6 (from screenpos mock)
    -- Default row offset is 1
    -- Expected row = cursor_relative_screen_row(5) + row_offset(1) = 6
    assert.are.equal(6, win_config.row)
  end)

  it("should place popup above cursor if cursor is in lower half", function()
    -- Arrange: Override cursor and screenpos mocks
    orig_api.nvim_win_get_cursor = vim.api.nvim_win_get_cursor -- Save original from setup_mocks if needed
    orig_fn.screenpos = vim.fn.screenpos
    vim.api.nvim_win_get_cursor = function(_)
      return { 15, 10 }
    end
    vim.fn.screenpos = function(_, _, _)
      return { row = 16, col = 11 }
    end
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 15, col = 10 }
    -- Assert
    assert.is_not_nil(result)
    assert.is_not_nil(mock_call_args.nvim_open_win)
    local win_config = mock_call_args.nvim_open_win.config
    -- height calc: min(floor(20*0.8), max(0, 15 - 2)) = min(16, 13) = 13
    -- target_height = 13. height = max(5, 13) = 13
    -- cursor_relative_screen_row = 15 (screenpos.row(16) - winpos.row(0) - 1)
    -- Expected row = screen_space_above(15) - height(13) - border_v_overhead(2) - row_offset(1) - 1 = 15-13-2-1-1 = -2 --> overflow
    -- If overflow, height becomes max(5, 13 - 2) = 11, row becomes 0 -- Adjusted calc based on code
    assert.are.equal(0, win_config.row)
    assert.are.equal(11, win_config.height)
  end)

  it("should stack subsequent popups relative to the previous one", function()
    -- Arrange: Simulate one existing popup
    local prev_popup_info = {
      win_id = 999,
      buf_id = 1,
      z_index = 50,
      width = 60,
      height = 15,
      row = 7,
      col = 12,
      original_win_id = 1000,
    }
    -- Manually push to stack to affect stack.size() and stack.top()
    package.loaded["overlook.stack"].push(prev_popup_info)
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 1, col = 1 }
    -- Assert
    assert.is_not_nil(result)
    assert.is_not_nil(mock_call_args.nvim_open_win)
    local win_config = mock_call_args.nvim_open_win.config
    assert.are.equal(999, win_config.win) -- Relative to previous window
    -- Expected width: max(min_width(10), prev_width(60) - width_decrement(2)) = 58 + 1 border = 59
    assert.are.equal(59, win_config.width)
    -- Expected height: max(min_height(5), prev_height(15) - height_decrement(1)) = 14
    assert.are.equal(14, win_config.height)
    -- Expected row: stack_row_offset(1) - winbar(0) = 1
    assert.are.equal(1, win_config.row)
    -- Expected col: stack_col_offset(1)
    assert.are.equal(1, win_config.col)
    assert.are.equal(51, win_config.zindex) -- Incremented zindex
  end)

  it("should respect minimum width and height", function()
    -- Arrange: Make window very small so size_ratio calc is below min
    orig_api.nvim_win_get_height = vim.api.nvim_win_get_height
    orig_api.nvim_win_get_width = vim.api.nvim_win_get_width
    orig_api.nvim_win_get_cursor = vim.api.nvim_win_get_cursor
    orig_fn.screenpos = vim.fn.screenpos
    vim.api.nvim_win_get_height = function(_)
      return 8
    end
    vim.api.nvim_win_get_width = function(_)
      return 10
    end
    vim.api.nvim_win_get_cursor = function(_)
      return { 2, 2 }
    end
    vim.fn.screenpos = function(_, _, _)
      return { row = 3, col = 3 }
    end

    -- Modify the globally mocked config for this test
    -- The 'global_mock_config_module' is what 'Popup' instances will see.
    global_mock_config_module.options.ui.min_width = 15
    global_mock_config_module.options.ui.min_height = 7

    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 1, col = 1 }

    -- Assert
    assert.is_not_nil(result)
    assert.is_not_nil(mock_call_args.nvim_open_win)
    local win_config = mock_call_args.nvim_open_win.config
    -- Calculation based on code walkthrough (assuming min_height=5 due to cache):
    -- final content width = 4 -> clamped by min_width(15) -> 15
    -- final content height = 3 -> clamped by min_height(7) -> 7 (if override works) or 5 (if cached)
    assert.are.equal(15, win_config.width) -- Corrected expectation based on min_width override
    assert.are.equal(7, win_config.height) -- Corrected expectation based on working min_height override
  end)

  it("should return nil and restore focus if nvim_open_win fails", function()
    -- Arrange: Make nvim_open_win return 0
    orig_api.nvim_open_win = vim.api.nvim_open_win -- Save original
    vim.api.nvim_open_win = function(_, _, _)
      mock_call_args.nvim_open_win = "called" -- Mark as called
      return 0
    end
    -- Mock nvim_set_current_win to track calls
    orig_api.nvim_set_current_win = vim.api.nvim_set_current_win -- Save original
    local set_current_win_calls = {}
    vim.api.nvim_set_current_win = function(win_id)
      table.insert(set_current_win_calls, win_id)
    end
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 1, col = 1 }
    -- Assert
    assert.is_nil(result)
    assert.are.equal("called", mock_call_args.nvim_open_win) -- Ensure it was attempted
    assert.are.same({ 1000 }, set_current_win_calls) -- Should restore to original window (mocked as 1000)
  end)

  it("should adjust stacking row offset if winbar is enabled", function()
    -- Arrange: Simulate one existing popup
    local prev_popup_info = {
      win_id = 999,
      buf_id = 1,
      z_index = 50,
      width = 60,
      height = 15,
      row = 7,
      col = 12,
      original_win_id = 1000,
    }
    package.loaded["overlook.stack"].push(prev_popup_info)
    -- Mock winbar to be enabled *specifically for the previous window*
    orig_api.nvim_get_option_value = vim.api.nvim_get_option_value
    vim.api.nvim_get_option_value = function(name, opts)
      if name == "winbar" and opts and opts.win == 999 then -- Check win_id is the previous popup
        return "%{1*Winbar%*}" -- Enable winbar for previous window
      elseif name == "winbar" then
        return "" -- Disabled for others
      end
      -- Provide other defaults needed by the function
      if name == "lines" then
        return 40
      end
      if name == "columns" then
        return 100
      end
      if name == "cmdheight" then
        return 1
      end
      if name == "laststatus" then
        return 2
      end

      return nil
    end
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 1, col = 1 }
    -- Assert
    assert.is_not_nil(result)
    assert.is_not_nil(mock_call_args.nvim_open_win)
    local win_config = mock_call_args.nvim_open_win.config
    -- Expected row: stack_row_offset(1) - winbar(1) = 0
    assert.are.equal(0, win_config.row)
  end)

  it("should handle nvim_win_get_config failure", function()
    -- Arrange: Make nvim_win_get_config return nil
    orig_api.nvim_win_get_config = vim.api.nvim_win_get_config
    vim.api.nvim_win_get_config = function(_)
      return nil
    end
    -- Track close calls
    orig_api.nvim_win_close = vim.api.nvim_win_close
    local closed_windows = {}
    vim.api.nvim_win_close = function(win_id, force)
      table.insert(closed_windows, { id = win_id, force = force })
    end
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 1, col = 1 }
    -- Assert
    assert.is_nil(result)
    assert.are.same({ { id = 1001, force = true } }, closed_windows) -- Should close the opened window
  end)

  it("should use the provided title option", function()
    -- Arrange
    local custom_title = "My Custom Popup Title"
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 1, col = 1, title = custom_title }
    -- Assert
    assert.is_not_nil(result)
    assert.is_not_nil(mock_call_args.nvim_open_win)
    assert.are.equal(custom_title, mock_call_args.nvim_open_win.config.title)
  end)

  it("should clamp stacked dimensions at minimums", function()
    -- Arrange: Simulate a small previous popup
    local prev_popup_info = {
      win_id = 999,
      buf_id = 1,
      z_index = 50,
      width = 11, -- width_decrement=2, min_width=10 -> next width should be max(10, 11-2)=10
      height = 6, -- height_decrement=1, min_height=5 -> next height should be max(5, 6-1)=5
      row = 7,
      col = 12,
      original_win_id = 1000,
    }
    package.loaded["overlook.stack"].push(prev_popup_info)
    -- Act
    local result = ui.create_popup { target_bufnr = 1, lnum = 1, col = 1 }
    -- Assert
    assert.is_not_nil(result)
    assert.is_not_nil(mock_call_args.nvim_open_win)
    local win_config = mock_call_args.nvim_open_win.config
    assert.are.equal(10 + 1, win_config.width) -- Clamp at min_width (10) + 1 border
    assert.are.equal(5, win_config.height) -- Clamp at min_height (5)
  end)
end)
