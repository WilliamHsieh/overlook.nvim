local mock = require("luassert.mock")
local stack = require("overlook.stack")
local stub = require("luassert.stub")

-- Test constants
local TEST_CONSTANTS = {
  AUGROUP_ID = 123,
  DEFAULT_WIN_ID = 1000,
  DEFAULT_BUF_ID = 100,
  POPUP_WIN_IDS = { 1, 2, 3, 4, 5 },
  ORIGINAL_WIN_IDS = { 100, 200, 300, 500, 600, 999 },
}

-- Test data factories
local function create_test_item(win_id, buf_id, z_index)
  return {
    win_id = win_id or TEST_CONSTANTS.POPUP_WIN_IDS[1],
    buf_id = buf_id or TEST_CONSTANTS.DEFAULT_BUF_ID,
    z_index = z_index or 1,
    width = 80,
    height = 24,
    row = 1,
    col = 1,
  }
end

local function create_popup_context(original_win_id)
  return {
    is_overlook_popup = true,
    overlook_popup = { original_win_id = original_win_id },
  }
end

describe("overlook.stack", function()
  local api_mock
  local original_config
  local original_state
  local original_schedule

  before_each(function()
    -- Reset stack instances
    stack.stack_instances = {}

    -- Mock vim.api functions with proper behavior
    api_mock = mock(vim.api, true)

    -- Use constants for consistent mock returns
    api_mock.nvim_create_augroup = stub()
    api_mock.nvim_create_augroup.returns(TEST_CONSTANTS.AUGROUP_ID)

    api_mock.nvim_get_current_win = stub()
    api_mock.nvim_get_current_win.returns(TEST_CONSTANTS.DEFAULT_WIN_ID)
    api_mock.nvim_win_is_valid = stub()
    api_mock.nvim_win_is_valid.returns(true)
    api_mock.nvim_win_close = stub()
    api_mock.nvim_clear_autocmds = stub()
    api_mock.nvim_set_current_win = stub()

    -- Store original modules and replace with minimal mocks
    original_config = package.loaded["overlook.config"]
    package.loaded["overlook.config"] = {
      options = {
        on_stack_empty = nil, -- No hook by default
      },
    }

    original_state = package.loaded["overlook.state"]
    package.loaded["overlook.state"] = {
      update_keymap = stub(),
    }

    -- Store original vim.schedule and mock it
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end

    -- Reset vim.w for each test
    vim.w = {}
  end)

  after_each(function()
    mock.revert(api_mock)

    -- Restore original modules
    package.loaded["overlook.config"] = original_config
    package.loaded["overlook.state"] = original_state

    -- Restore original vim.schedule
    vim.schedule = original_schedule
  end)

  describe("Stack instance management", function()
    it("should create separate stacks for different original windows", function()
      local win_id_1 = TEST_CONSTANTS.ORIGINAL_WIN_IDS[1]
      local win_id_2 = TEST_CONSTANTS.ORIGINAL_WIN_IDS[2]

      local stack1 = stack.win_get_stack(win_id_1)
      local stack2 = stack.win_get_stack(win_id_2)

      assert.are_not.equal(stack1, stack2)
      assert.are.equal(win_id_1, stack1.original_win_id)
      assert.are.equal(win_id_2, stack2.original_win_id)
      assert.are.equal(TEST_CONSTANTS.AUGROUP_ID, stack1.augroup_id)
      assert.are.equal(TEST_CONSTANTS.AUGROUP_ID, stack2.augroup_id)
    end)

    it("should return the same stack instance for the same original window", function()
      local win_id = TEST_CONSTANTS.ORIGINAL_WIN_IDS[1]

      local stack1 = stack.win_get_stack(win_id)
      local stack2 = stack.win_get_stack(win_id)

      assert.are.equal(stack1, stack2)
      assert.are.equal(win_id, stack1.original_win_id)
    end)

    it("should determine correct original_win_id from regular window", function()
      vim.w = {} -- No popup context
      local expected_win_id = TEST_CONSTANTS.ORIGINAL_WIN_IDS[3]
      api_mock.nvim_get_current_win.returns(expected_win_id)

      local win_id = stack.get_current_original_win_id()

      assert.are.equal(expected_win_id, win_id)
      assert.stub(api_mock.nvim_get_current_win).was_called()
    end)

    it("should determine correct original_win_id from popup context", function()
      local original_win_id = TEST_CONSTANTS.ORIGINAL_WIN_IDS[4]
      vim.w = create_popup_context(original_win_id)

      local win_id = stack.get_current_original_win_id()

      assert.are.equal(original_win_id, win_id)
      -- Should not call nvim_get_current_win when in popup context
      assert.stub(api_mock.nvim_get_current_win).was_not_called()
    end)

    it("should create new stack instance with proper initialization", function()
      local win_id = TEST_CONSTANTS.ORIGINAL_WIN_IDS[5]

      local new_stack = stack.win_get_stack(win_id)

      assert.is_not_nil(new_stack)
      assert.are.equal(win_id, new_stack.original_win_id)
      assert.are.equal(TEST_CONSTANTS.AUGROUP_ID, new_stack.augroup_id)
      assert.are.same({}, new_stack.items)
      assert.are.equal(0, new_stack:size())
      assert.is_true(new_stack:empty())

      -- Verify augroup was created
      assert.stub(api_mock.nvim_create_augroup).was_called_with("OverlookPopupClose", { clear = true })
    end)
  end)

  describe("Basic stack operations", function()
    local test_stack

    before_each(function()
      test_stack = stack.new(TEST_CONSTANTS.DEFAULT_WIN_ID)
    end)

    it("should initialize with empty stack", function()
      assert.are.equal(0, test_stack:size())
      assert.is_true(test_stack:empty())
      assert.is_nil(test_stack:top())
      assert.are.equal(TEST_CONSTANTS.DEFAULT_WIN_ID, test_stack.original_win_id)
      assert.are.equal(TEST_CONSTANTS.AUGROUP_ID, test_stack.augroup_id)
    end)

    it("should push items onto the stack in correct order", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10, 1)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20, 2)
      local item3 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[3], 30, 3)

      test_stack:push(item1)
      assert.are.equal(1, test_stack:size())
      assert.are.same(item1, test_stack:top())
      assert.is_false(test_stack:empty())

      test_stack:push(item2)
      assert.are.equal(2, test_stack:size())
      assert.are.same(item2, test_stack:top()) -- LIFO behavior

      test_stack:push(item3)
      assert.are.equal(3, test_stack:size())
      assert.are.same(item3, test_stack:top())

      -- Verify internal structure
      assert.are.same(item1, test_stack.items[1])
      assert.are.same(item2, test_stack.items[2])
      assert.are.same(item3, test_stack.items[3])
    end)

    it("should return correct size for various operations", function()
      assert.are.equal(0, test_stack:size())

      for i = 1, 5 do
        local item = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[i], i * 10, i)
        test_stack:push(item)
        assert.are.equal(i, test_stack:size())
      end
    end)

    it("should return correct top item without modifying stack", function()
      assert.is_nil(test_stack:top())

      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10)
      test_stack:push(item1)
      assert.are.same(item1, test_stack:top())
      assert.are.equal(1, test_stack:size()) -- Size unchanged

      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20)
      test_stack:push(item2)
      assert.are.same(item2, test_stack:top())
      assert.are.equal(2, test_stack:size()) -- Size unchanged

      -- Multiple calls to top() should return same result
      assert.are.same(item2, test_stack:top())
      assert.are.same(item2, test_stack:top())
    end)

    it("should handle empty stack operations gracefully", function()
      assert.is_true(test_stack:empty())
      assert.are.equal(0, test_stack:size())
      assert.is_nil(test_stack:top())

      -- Multiple calls on empty stack
      assert.is_nil(test_stack:top())
      assert.is_nil(test_stack:top())
      assert.is_true(test_stack:empty())

      test_stack:push(create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1]))
      assert.is_false(test_stack:empty())
    end)
  end)

  describe("Window removal operations", function()
    local test_stack

    before_each(function()
      test_stack = stack.new(TEST_CONSTANTS.DEFAULT_WIN_ID)
      stack.stack_instances[TEST_CONSTANTS.DEFAULT_WIN_ID] = test_stack
    end)

    it("should remove window by ID from middle of stack", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20)
      local item3 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[3], 30)

      test_stack:push(item1)
      test_stack:push(item2)
      test_stack:push(item3)

      test_stack:remove_by_winid(TEST_CONSTANTS.POPUP_WIN_IDS[2]) -- Remove middle item

      assert.are.equal(2, test_stack:size())
      assert.are.same(item3, test_stack:top())
      assert.are.same(item1, test_stack.items[1])
      assert.are.same(item3, test_stack.items[2])
    end)

    it("should remove window by ID from top of stack", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20)

      test_stack:push(item1)
      test_stack:push(item2)

      test_stack:remove_by_winid(TEST_CONSTANTS.POPUP_WIN_IDS[2]) -- Remove top item

      assert.are.equal(1, test_stack:size())
      assert.are.same(item1, test_stack:top())
    end)

    it("should handle removal of non-existent window ID", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10)
      test_stack:push(item1)

      test_stack:remove_by_winid(999) -- Non-existent ID

      assert.are.equal(1, test_stack:size())
      assert.are.same(item1, test_stack:top())
    end)

    it("should remove invalid windows from top of stack", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20)
      local item3 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[3], 30)

      test_stack:push(item1)
      test_stack:push(item2)
      test_stack:push(item3)

      -- Configure the existing mock with specific return values
      api_mock.nvim_win_is_valid:clear()
      api_mock.nvim_win_is_valid.on_call_with(TEST_CONSTANTS.POPUP_WIN_IDS[3]).returns(false)
      api_mock.nvim_win_is_valid.on_call_with(TEST_CONSTANTS.POPUP_WIN_IDS[2]).returns(false)
      api_mock.nvim_win_is_valid.on_call_with(TEST_CONSTANTS.POPUP_WIN_IDS[1]).returns(true)

      test_stack:remove_invalid_windows()

      assert.are.equal(1, test_stack:size())
      assert.are.same(item1, test_stack:top())

      -- Verify the correct windows were checked
      assert.stub(api_mock.nvim_win_is_valid).was_called_with(TEST_CONSTANTS.POPUP_WIN_IDS[3])
      assert.stub(api_mock.nvim_win_is_valid).was_called_with(TEST_CONSTANTS.POPUP_WIN_IDS[2])
      assert.stub(api_mock.nvim_win_is_valid).was_called_with(TEST_CONSTANTS.POPUP_WIN_IDS[1])
    end)

    it("should handle all invalid windows in stack", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20)

      test_stack:push(item1)
      test_stack:push(item2)

      -- Configure the existing mock to return false for all windows
      api_mock.nvim_win_is_valid:clear()
      api_mock.nvim_win_is_valid.returns(false)

      test_stack:remove_invalid_windows()

      assert.are.equal(0, test_stack:size())
      assert.is_true(test_stack:empty())
      assert.is_nil(test_stack:top())
    end)
  end)

  describe("Module-level API delegation", function()
    before_each(function()
      vim.w = {}
    end)

    it("should delegate push to current stack", function()
      local item = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10, 1)

      stack.push(item)

      local current_stack = stack.get_current_stack()
      assert.are.equal(1, current_stack:size())
      assert.are.same(item, current_stack:top())
      assert.are.equal(1, stack.size())
      assert.are.same(item, stack.top())
    end)

    it("should delegate size to current stack", function()
      assert.are.equal(0, stack.size())

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10))
      assert.are.equal(1, stack.size())

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20))
      assert.are.equal(2, stack.size())
    end)

    it("should delegate top to current stack", function()
      assert.is_nil(stack.top())

      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10)
      stack.push(item1)
      assert.are.same(item1, stack.top())

      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20)
      stack.push(item2)
      assert.are.same(item2, stack.top())
    end)

    it("should delegate empty to current stack", function()
      assert.is_true(stack.empty())

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10))
      assert.is_false(stack.empty())
    end)

    it("should work with different window contexts", function()
      -- Test with regular window context
      vim.w = {}
      local regular_win_id = TEST_CONSTANTS.ORIGINAL_WIN_IDS[4]
      api_mock.nvim_get_current_win.returns(regular_win_id)

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[1], 10))
      assert.are.equal(1, stack.size())

      -- Test with popup window context
      local popup_original_win_id = TEST_CONSTANTS.ORIGINAL_WIN_IDS[5]
      vim.w = create_popup_context(popup_original_win_id)

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WIN_IDS[2], 20))
      assert.are.equal(1, stack.size()) -- Different stack

      -- Verify separate stacks
      local regular_stack = stack.win_get_stack(regular_win_id)
      local popup_stack = stack.win_get_stack(popup_original_win_id)
      assert.are.equal(1, regular_stack:size())
      assert.are.equal(1, popup_stack:size())
      assert.are_not.equal(regular_stack, popup_stack)
    end)
  end)
end)
