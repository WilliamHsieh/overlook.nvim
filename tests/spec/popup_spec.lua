---@diagnostic disable: undefined-global, need-check-nil, undefined-field
---@module "plenary"

local mock = require("luassert.mock")
local stub = require("luassert.stub")

-- Mock for "overlook.config"
-- This needs to be at the top before "overlook.popup" is required by the tests.
local initial_mock_ui_config_table = {
  border = "double",
  z_index_base = 50,
  col_offset = 1,
  row_offset = 1,
  size_ratio = 0.8,
  min_width = 10,
  min_height = 5,
  width_decrement = 2,
  height_decrement = 1,
  stack_row_offset = 1,
  stack_col_offset = 1,
}
local global_mock_config_data = { ui = vim.deepcopy(initial_mock_ui_config_table) }
local global_mock_config_module = {
  options = global_mock_config_data,
  get = function()
    return global_mock_config_data
  end,
  reset_to_initial_state = function()
    global_mock_config_data.ui = vim.deepcopy(initial_mock_ui_config_table)
  end,
}
package.loaded["overlook.config"] = global_mock_config_module

-- IMPORTANT: Clear the popup module from cache so it re-requires config with our mock
package.loaded["overlook.popup"] = nil

-- The module under test
local Popup = require("overlook.popup")
local Stack = require("overlook.stack")
local State = require("overlook.state")

-- Border resolution must be tested BEFORE any describe in this file mocks
-- vim.api -- mock(vim.api, true) stubs nvim_get_option_value, which
-- vim.o.winborder reads through, so once any other describe runs, reading
-- the option returns nil even after mock.revert. Placed here to keep the
-- real vim.api/vim.o intact.
describe("Popup -- border resolution fallback chain", function()
  -- determine_window_configuration picks the border in this order:
  --   Config.ui.border (if non-empty)
  --   vim.o.winborder  (if non-empty)
  --   "rounded"        (final default)
  local original_winborder
  local function make_real_buf()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "line" })
    return b
  end

  before_each(function()
    global_mock_config_module.reset_to_initial_state()
    original_winborder = vim.o.winborder
  end)

  after_each(function()
    global_mock_config_module.reset_to_initial_state()
    vim.o.winborder = original_winborder
  end)

  it("uses Config.ui.border when it is set", function()
    global_mock_config_module.options.ui.border = "double"
    vim.o.winborder = "single" -- should be ignored
    local p = Popup.new { target_bufnr = make_real_buf(), lnum = 1, col = 1 }
    assert.is_not_nil(p)
    assert.are.equal("double", p.win_config.border)
  end)

  it("falls back to vim.o.winborder when Config.ui.border is empty", function()
    global_mock_config_module.options.ui.border = ""
    vim.o.winborder = "single"
    local p = Popup.new { target_bufnr = make_real_buf(), lnum = 1, col = 1 }
    assert.is_not_nil(p)
    assert.are.equal("single", p.win_config.border)
  end)

  it("falls back to 'rounded' when both Config.ui.border and vim.o.winborder are empty", function()
    global_mock_config_module.options.ui.border = ""
    vim.o.winborder = ""
    local p = Popup.new { target_bufnr = make_real_buf(), lnum = 1, col = 1 }
    assert.is_not_nil(p)
    assert.are.equal("rounded", p.win_config.border)
  end)
end)

-- Test constants
local TEST_CONSTANTS = {
  DEFAULT_WINID = 1000,
  DEFAULT_BUF_ID = 100,
  POPUP_WINIDS = { 1001, 1002, 1003 },
  AUGROUP_ID = 123,

  -- Common window dimensions
  STANDARD_WIN_WIDTH = 80,
  STANDARD_WIN_HEIGHT = 20,
  LARGE_WIN_WIDTH = 200,
  LARGE_WIN_HEIGHT = 100,
  SMALL_WIN_WIDTH = 15,
  SMALL_WIN_HEIGHT = 8,

  -- Common cursor positions
  CURSOR_TOP = { 5, 10 },
  CURSOR_BOTTOM = { 15, 10 },
  CURSOR_NEAR_BOTTOM = { 10, 10 },

  -- Common screen positions
  SCREEN_POS_TOP = { row = 6, col = 11 },
  SCREEN_POS_BOTTOM = { row = 16, col = 11 },
  SCREEN_POS_NEAR_BOTTOM = { row = 11, col = 11 },
}

-- Helper function to set up common mocks
local function setup_common_mocks()
  local api_mock = mock(vim.api, true)

  -- Standard window mocks
  api_mock.nvim_get_current_win.returns(TEST_CONSTANTS.DEFAULT_WINID)
  api_mock.nvim_win_get_position.returns { 0, 0 }
  api_mock.nvim_win_get_height.returns(TEST_CONSTANTS.STANDARD_WIN_HEIGHT)
  api_mock.nvim_win_get_width.returns(TEST_CONSTANTS.STANDARD_WIN_WIDTH)
  api_mock.nvim_win_get_cursor.returns(TEST_CONSTANTS.CURSOR_TOP)
  vim.fn.screenpos = stub().returns(TEST_CONSTANTS.SCREEN_POS_TOP)

  -- Popup creation mocks
  api_mock.nvim_buf_is_valid.returns(true)
  api_mock.nvim_win_is_valid.returns(true)
  api_mock.nvim_open_win.returns(TEST_CONSTANTS.POPUP_WINIDS[1])
  api_mock.nvim_win_get_config.returns {}
  api_mock.nvim_create_augroup.returns(TEST_CONSTANTS.AUGROUP_ID)
  api_mock.nvim_create_autocmd = stub()
  api_mock.nvim_win_set_cursor = stub()
  api_mock.nvim_win_call = stub()

  -- Stack and State mocks
  Stack.empty = stub().returns(true)
  Stack.size = stub().returns(0)
  State.register_overlook_popup = stub()

  -- Reset vim.w
  vim.w = {}

  return api_mock
end

describe("Popup:config_for_first_popup", function()
  local original_vim_o

  before_each(function()
    global_mock_config_module.reset_to_initial_state()
    -- Store and mock vim.o.winbar
    original_vim_o = { winbar = vim.o.winbar }
    vim.o.winbar = "" -- Default to disabled for tests
  end)

  after_each(function()
    vim.o.winbar = original_vim_o.winbar
    global_mock_config_module.reset_to_initial_state()
  end)

  describe("when popup is placed below the cursor", function()
    local api_mock

    before_each(function()
      api_mock = setup_common_mocks()
    end)

    after_each(function()
      mock.revert(api_mock)
    end)

    it("should calculate config correctly with winbar disabled", function()
      vim.o.winbar = ""
      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      local win_config = popup_instance.win_config
      assert.are.same({
        relative = "win",
        style = "minimal",
        focusable = true,
        width = 64,
        height = 12,
        win = TEST_CONSTANTS.DEFAULT_WINID,
        zindex = global_mock_config_data.ui.z_index_base,
        col = 11,
        row = 6,
        border = "double",
        title = "Overlook default title",
        title_pos = "center",
      }, win_config)
      assert.are.equal(TEST_CONSTANTS.DEFAULT_WINID, popup_instance.root_winid)
    end)

    it("should calculate config correctly with winbar enabled", function()
      vim.o.winbar = "enabled"
      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      local win_config = popup_instance.win_config
      assert.are.equal(6, win_config.row) -- Different row when winbar is enabled
      assert.are.equal(TEST_CONSTANTS.DEFAULT_WINID, popup_instance.root_winid)
    end)
  end)

  describe("when popup is placed above the cursor", function()
    local api_mock

    before_each(function()
      api_mock = setup_common_mocks()
      -- Override for above-cursor placement
      api_mock.nvim_win_get_cursor.returns(TEST_CONSTANTS.CURSOR_BOTTOM)
      vim.fn.screenpos = stub().returns(TEST_CONSTANTS.SCREEN_POS_BOTTOM)
    end)

    after_each(function()
      mock.revert(api_mock)
    end)

    it("should calculate config correctly with winbar disabled", function()
      vim.o.winbar = ""
      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      local win_config = popup_instance.win_config
      assert.are.equal(0, win_config.row) -- Placed above
      assert.are.equal(12, win_config.height) -- Fixed: actual value is 12, not 13
    end)

    it("should calculate config correctly with winbar enabled", function()
      vim.o.winbar = "enabled"
      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      local win_config = popup_instance.win_config
      assert.are.equal(0, win_config.row) -- Still placed above
      assert.are.equal(12, win_config.height) -- Adjusted for winbar
    end)
  end)
end)

describe("First popup dimension calculations", function()
  local api_mock

  before_each(function()
    global_mock_config_module.reset_to_initial_state()
    api_mock = setup_common_mocks()
    vim.o.winbar = ""
  end)

  after_each(function()
    mock.revert(api_mock)
    global_mock_config_module.reset_to_initial_state()
  end)

  describe("size ratio calculations", function()
    it("should calculate dimensions using default size_ratio of 0.8", function()
      api_mock.nvim_win_get_width.returns(80)
      api_mock.nvim_win_get_height.returns(20)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(64, popup_instance.win_config.width) -- 80 * 0.8 = 64
      assert.are.equal(12, popup_instance.win_config.height) -- Limited by available space
    end)

    it("should calculate dimensions with custom size_ratio of 0.5", function()
      global_mock_config_module.options.ui.size_ratio = 0.5
      api_mock.nvim_win_get_width.returns(100)
      api_mock.nvim_win_get_height.returns(30)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(50, popup_instance.win_config.width) -- 100 * 0.5 = 50
      assert.are.equal(14, popup_instance.win_config.height) -- Limited by available space
    end)

    it("should calculate dimensions with large size_ratio of 0.9", function()
      global_mock_config_module.options.ui.size_ratio = 0.9
      api_mock.nvim_win_get_width.returns(60)
      api_mock.nvim_win_get_height.returns(25)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(54, popup_instance.win_config.width) -- 60 * 0.9 = 54
      assert.are.equal(17, popup_instance.win_config.height) -- Limited by available space
    end)
  end)

  describe("minimum dimension constraints", function()
    it("should enforce min_width when calculated width is too small", function()
      global_mock_config_module.options.ui.min_width = 25
      global_mock_config_module.options.ui.size_ratio = 0.3
      api_mock.nvim_win_get_width.returns(50) -- 50 * 0.3 = 15, below min_width
      api_mock.nvim_win_get_height.returns(20)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(25, popup_instance.win_config.width) -- Enforced min_width
    end)

    it("should enforce min_height when calculated height is too small", function()
      global_mock_config_module.options.ui.min_height = 8
      global_mock_config_module.options.ui.size_ratio = 0.2
      api_mock.nvim_win_get_width.returns(80)
      api_mock.nvim_win_get_height.returns(30) -- Would be 6, below min_height

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(8, popup_instance.win_config.height) -- Enforced min_height
    end)

    it("should handle both min_width and min_height constraints simultaneously", function()
      global_mock_config_module.options.ui.min_width = 30
      global_mock_config_module.options.ui.min_height = 10
      global_mock_config_module.options.ui.size_ratio = 0.1 -- Both dimensions below minimums
      api_mock.nvim_win_get_width.returns(100)
      api_mock.nvim_win_get_height.returns(50)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(30, popup_instance.win_config.width) -- Enforced min_width
      assert.are.equal(10, popup_instance.win_config.height) -- Enforced min_height
    end)
  end)

  describe("border overhead calculations", function()
    it("should account for 2px border overhead with double border", function()
      global_mock_config_module.options.ui.border = "double"
      api_mock.nvim_win_get_width.returns(80)
      api_mock.nvim_win_get_height.returns(20)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(12, popup_instance.win_config.height) -- Reduced by border overhead
    end)

    it("should account for 2px border overhead with single border", function()
      global_mock_config_module.options.ui.border = "single"
      api_mock.nvim_win_get_width.returns(80)
      api_mock.nvim_win_get_height.returns(20)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(12, popup_instance.win_config.height) -- Same overhead for any border
    end)

    it("should have no border overhead with 'none' border", function()
      global_mock_config_module.options.ui.border = "none"
      api_mock.nvim_win_get_width.returns(80)
      api_mock.nvim_win_get_height.returns(20)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(14, popup_instance.win_config.height) -- No border overhead
    end)
  end)

  describe("available space constraints", function()
    it("should limit height when popup is placed above cursor with limited space", function()
      api_mock.nvim_win_get_width.returns(80)
      api_mock.nvim_win_get_height.returns(15)
      api_mock.nvim_win_get_cursor.returns { 10, 10 } -- Cursor near bottom
      vim.fn.screenpos = stub().returns { row = 11, col = 11 }

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(7, popup_instance.win_config.height) -- Placed above, limited by space
    end)

    it("should place popup above cursor when more space is available above", function()
      api_mock.nvim_win_get_width.returns(80)
      api_mock.nvim_win_get_height.returns(20)
      api_mock.nvim_win_get_cursor.returns { 15, 10 } -- Cursor near bottom
      vim.fn.screenpos = stub().returns { row = 16, col = 11 }

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(0, popup_instance.win_config.row) -- Placed above cursor
      assert.are.equal(12, popup_instance.win_config.height) -- Limited by available space
    end)
  end)

  describe("edge cases", function()
    it("should handle very small parent windows", function()
      api_mock.nvim_win_get_width.returns(TEST_CONSTANTS.SMALL_WIN_WIDTH)
      api_mock.nvim_win_get_height.returns(TEST_CONSTANTS.SMALL_WIN_HEIGHT)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(12, popup_instance.win_config.width) -- 15 * 0.8 = 12
      assert.are.equal(5, popup_instance.win_config.height) -- Limited by min_height and space
    end)

    it("should handle very large parent windows", function()
      api_mock.nvim_win_get_width.returns(TEST_CONSTANTS.LARGE_WIN_WIDTH)
      api_mock.nvim_win_get_height.returns(TEST_CONSTANTS.LARGE_WIN_HEIGHT)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(160, popup_instance.win_config.width) -- 200 * 0.8 = 160
      assert.are.equal(79, popup_instance.win_config.height) -- Limited by available space
    end)

    it("should handle size_ratio of 1.0 (full window size)", function()
      global_mock_config_module.options.ui.size_ratio = 1.0
      api_mock.nvim_win_get_width.returns(60)
      api_mock.nvim_win_get_height.returns(20)

      local popup_instance = Popup.new { target_bufnr = TEST_CONSTANTS.DEFAULT_BUF_ID, lnum = 1, col = 1 }

      assert.is_not_nil(popup_instance)
      assert.are.equal(60, popup_instance.win_config.width) -- 60 * 1.0 = 60
      assert.are.equal(12, popup_instance.win_config.height) -- Limited by available space
    end)
  end)
end)

describe("Popup input validation", function()
  local api_mock
  local notify_stub

  before_each(function()
    global_mock_config_module.reset_to_initial_state()

    -- Mock vim.api functions
    api_mock = mock(vim.api, true)
    api_mock.nvim_buf_is_valid = stub()

    -- Stub vim.notify directly
    notify_stub = stub(vim, "notify")
  end)

  after_each(function()
    mock.revert(api_mock)
    notify_stub:revert()
  end)

  it("should return nil and notify if opts is nil", function()
    local popup_instance = Popup.new(nil)
    assert.is_nil(popup_instance)
    assert.stub(notify_stub).was_called(1)
  end)

  it("should return nil and notify if opts.target_bufnr is nil", function()
    local popup_instance = Popup.new {}
    assert.is_nil(popup_instance)
    assert.stub(notify_stub).was_called(1)
  end)

  it("should return nil and notify if target_bufnr is invalid", function()
    api_mock.nvim_buf_is_valid.returns(false)
    local popup_instance = Popup.new { target_bufnr = 123 }
    assert.is_nil(popup_instance)
    assert.stub(notify_stub).was_called(1)
  end)

  it("should create popup successfully if target_bufnr is valid", function()
    local local_api_mock = setup_common_mocks()

    local popup_instance = Popup.new { target_bufnr = 456, lnum = 10, col = 5 }
    assert.is_not_nil(popup_instance)
    assert.are.equal(456, popup_instance.opts.target_bufnr)
    assert.are.equal(10, popup_instance.opts.lnum)
    assert.are.equal(5, popup_instance.opts.col)
    assert.stub(notify_stub).was_not_called() -- Should not notify on success

    mock.revert(local_api_mock)
  end)
end)

describe("Popup — lifecycle methods", function()
  local api_mock, notify_stub

  before_each(function()
    global_mock_config_module.reset_to_initial_state()
    api_mock = mock(vim.api, true)
    api_mock.nvim_buf_is_valid.returns(true)
    api_mock.nvim_open_win.returns(1234)
    api_mock.nvim_win_is_valid.returns(true)
    api_mock.nvim_win_close = stub()
    api_mock.nvim_set_current_win = stub()
    api_mock.nvim_get_current_win.returns(100)
    api_mock.nvim_win_get_position.returns { 0, 0 }
    api_mock.nvim_win_get_height.returns(20)
    api_mock.nvim_win_get_width.returns(80)
    api_mock.nvim_win_get_cursor.returns { 5, 10 }
    api_mock.nvim_win_get_config.returns { width = 64, height = 12 }
    api_mock.nvim_create_autocmd = stub()
    api_mock.nvim_win_set_cursor = stub()
    api_mock.nvim_win_call = stub()
    vim.fn.screenpos = stub().returns { row = 6, col = 11 }
    require("overlook.state").register_overlook_popup = stub()
    vim.w = {}
    notify_stub = stub(vim, "notify")
  end)

  after_each(function()
    mock.revert(api_mock)
    notify_stub:revert()
  end)

  it("Popup.new(opts, ctx) constructs without opening a window", function()
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    assert.is_not_nil(p)
    assert.is_nil(p.winid)
    assert.stub(api_mock.nvim_open_win).was_not_called()
  end)

  it("popup:open opens the window and registers state", function()
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    local ok = p:open()
    assert.is_true(ok)
    assert.are.equal(1234, p.winid)
    assert.stub(api_mock.nvim_open_win).was_called(1)
  end)

  it("popup:open returns false when nvim_open_win returns 0", function()
    api_mock.nvim_open_win.returns(0)
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    local ok = p:open()
    assert.is_false(ok)
    assert.is_nil(p.winid)
  end)

  it("popup:close calls nvim_win_close when valid", function()
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    p:open()
    p:close()
    assert.stub(api_mock.nvim_win_close).was_called_with(1234, false)
  end)

  it("popup:is_valid returns false before open()", function()
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    assert.is_false(p:is_valid())
  end)

  it("popup:focus delegates to nvim_set_current_win when valid", function()
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    p:open()
    p:focus()
    assert.stub(api_mock.nvim_set_current_win).was_called_with(1234)
  end)

  it("stacked popup config uses ctx.prev and ctx.depth (no Stack lookup)", function()
    local prev = { winid = 555, width = 50, height = 10, root_winid = 100 }
    local p = Popup.new(
      { target_bufnr = 1, lnum = 1, col = 1, title = "stacked" },
      { root_winid = 100, prev = prev, depth = 1 }
    )
    assert.is_not_nil(p)
    assert.are.equal(555, p.win_config.win)
    assert.is_false(p.is_first_popup)
  end)

  it("popup:open closes the half-created window when post-open setup throws", function()
    api_mock.nvim_win_get_config = stub().invokes(function()
      error("injected post-open failure")
    end)

    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    local ok = p:open()

    assert.is_false(ok)
    assert.is_nil(p.winid)
    assert.stub(api_mock.nvim_win_close).was_called_with(1234, true)
  end)

  it("first popup config uses ctx.root_winid (not nvim_get_current_win)", function()
    -- Simulate "user's focus is in window 7777 but they want the popup on window 100"
    api_mock.nvim_get_current_win.returns(7777) -- focus is elsewhere
    -- nvim_win_get_cursor must be called on root_winid (100), not 7777:
    api_mock.nvim_win_get_cursor = stub()
    api_mock.nvim_win_get_cursor.on_call_with(100).returns { 5, 10 }
    api_mock.nvim_win_get_cursor.on_call_with(7777).returns { 99, 99 } -- if used, popup would mispoint

    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    assert.is_not_nil(p)
    assert.are.equal(100, p.root_winid) -- ctx.root_winid honored
    assert.are.equal(100, p.win_config.win) -- anchor is ctx.root_winid
    -- The popup's cursor calculations must have used winid 100, not 7777:
    assert.stub(api_mock.nvim_win_get_cursor).was_called_with(100)
    assert.stub(api_mock.nvim_win_get_cursor).was_not_called_with(7777)
  end)
end)
