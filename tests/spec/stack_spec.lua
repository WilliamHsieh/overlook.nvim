---@diagnostic disable: undefined-field

local mock = require("luassert.mock")
local stack = require("overlook.stack")
local stub = require("luassert.stub")

-- Test constants
local TEST_CONSTANTS = {
  AUGROUP_ID = 123,
  DEFAULT_WINID = 1000,
  DEFAULT_BUF_ID = 100,
  POPUP_WINIDS = { 1, 2, 3, 4, 5 },
  ROOT_WINIDS = { 100, 200, 300, 500, 600, 999 },
}

-- Test data factories
local function create_test_item(winid, buf_id, z_index)
  return {
    winid = winid or TEST_CONSTANTS.POPUP_WINIDS[1],
    buf_id = buf_id or TEST_CONSTANTS.DEFAULT_BUF_ID,
    z_index = z_index or 1,
    width = 80,
    height = 24,
    row = 1,
    col = 1,
  }
end

local function create_popup_context(root_winid)
  return {
    is_overlook_popup = true,
    overlook_popup = { root_winid = root_winid },
  }
end

describe("overlook.stack", function()
  local api_mock
  local original_config
  local original_state
  local schedule_stub

  before_each(function()
    -- Reset stack instances
    stack.instances = {}

    -- Mock vim.api functions with proper behavior
    api_mock = mock(vim.api, true)

    -- Use constants for consistent mock returns
    api_mock.nvim_create_augroup = stub()
    api_mock.nvim_create_augroup.returns(TEST_CONSTANTS.AUGROUP_ID)

    api_mock.nvim_get_current_win = stub()
    api_mock.nvim_get_current_win.returns(TEST_CONSTANTS.DEFAULT_WINID)
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

    -- Properly stub vim.schedule using luassert
    schedule_stub = stub(vim, "schedule")
    schedule_stub.invokes(function(fn)
      fn() -- Execute immediately for testing
    end)

    -- Reset vim.w for each test
    vim.w = {}
  end)

  after_each(function()
    mock.revert(api_mock)

    -- Restore original modules
    package.loaded["overlook.config"] = original_config
    package.loaded["overlook.state"] = original_state

    -- Properly revert the vim.schedule stub
    schedule_stub:revert()
  end)

  describe("Stack instance management", function()
    it("should create separate stacks for different root windows", function()
      local winid_1 = TEST_CONSTANTS.ROOT_WINIDS[1]
      local winid_2 = TEST_CONSTANTS.ROOT_WINIDS[2]

      local stack1 = stack.win_get_stack(winid_1)
      local stack2 = stack.win_get_stack(winid_2)

      assert.are_not.equal(stack1, stack2)
      assert.are.equal(winid_1, stack1.root_winid)
      assert.are.equal(winid_2, stack2.root_winid)
      assert.are.equal(TEST_CONSTANTS.AUGROUP_ID, stack1.augroup_id)
      assert.are.equal(TEST_CONSTANTS.AUGROUP_ID, stack2.augroup_id)
    end)

    it("should return the same stack instance for the same root window", function()
      local winid = TEST_CONSTANTS.ROOT_WINIDS[1]

      local stack1 = stack.win_get_stack(winid)
      local stack2 = stack.win_get_stack(winid)

      assert.are.equal(stack1, stack2)
      assert.are.equal(winid, stack1.root_winid)
    end)

    it("should determine correct root_winid from regular window", function()
      vim.w = {} -- No popup context
      local expected_winid = TEST_CONSTANTS.ROOT_WINIDS[3]
      api_mock.nvim_get_current_win.returns(expected_winid)

      local winid = stack.get_current_root_winid()

      assert.are.equal(expected_winid, winid)
      assert.stub(api_mock.nvim_get_current_win).was_called()
    end)

    it("should determine correct root_winid from popup context", function()
      local root_winid = TEST_CONSTANTS.ROOT_WINIDS[4]
      vim.w = create_popup_context(root_winid)

      local winid = stack.get_current_root_winid()

      assert.are.equal(root_winid, winid)
      -- Should not call nvim_get_current_win when in popup context
      assert.stub(api_mock.nvim_get_current_win).was_not_called()
    end)

    it("should create new stack instance with proper initialization", function()
      local winid = TEST_CONSTANTS.ROOT_WINIDS[5]

      local new_stack = stack.win_get_stack(winid)

      assert.is_not_nil(new_stack)
      assert.are.equal(winid, new_stack.root_winid)
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
      test_stack = stack.new(TEST_CONSTANTS.DEFAULT_WINID)
    end)

    it("should initialize with empty stack", function()
      assert.are.equal(0, test_stack:size())
      assert.is_true(test_stack:empty())
      assert.is_nil(test_stack:top())
      assert.are.equal(TEST_CONSTANTS.DEFAULT_WINID, test_stack.root_winid)
      assert.are.equal(TEST_CONSTANTS.AUGROUP_ID, test_stack.augroup_id)
    end)

    it("should push items onto the stack in correct order", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10, 1)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[2], 20, 2)
      local item3 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[3], 30, 3)

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
        local item = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[i], i * 10, i)
        test_stack:push(item)
        assert.are.equal(i, test_stack:size())
      end
    end)

    it("should return correct top item without modifying stack", function()
      assert.is_nil(test_stack:top())

      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10)
      test_stack:push(item1)
      assert.are.same(item1, test_stack:top())
      assert.are.equal(1, test_stack:size()) -- Size unchanged

      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[2], 20)
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

      test_stack:push(create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1]))
      assert.is_false(test_stack:empty())
    end)
  end)

  describe("Window removal operations", function()
    local test_stack

    before_each(function()
      test_stack = stack.new(TEST_CONSTANTS.DEFAULT_WINID)
      stack.instances[TEST_CONSTANTS.DEFAULT_WINID] = test_stack
    end)

    it("should remove window by ID from middle of stack", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[2], 20)
      local item3 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[3], 30)

      test_stack:push(item1)
      test_stack:push(item2)
      test_stack:push(item3)

      test_stack:remove_by_winid(TEST_CONSTANTS.POPUP_WINIDS[2]) -- Remove middle item

      assert.are.equal(2, test_stack:size())
      assert.are.same(item3, test_stack:top())
      assert.are.same(item1, test_stack.items[1])
      assert.are.same(item3, test_stack.items[2])
    end)

    it("should remove window by ID from top of stack", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10)
      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[2], 20)

      test_stack:push(item1)
      test_stack:push(item2)

      test_stack:remove_by_winid(TEST_CONSTANTS.POPUP_WINIDS[2]) -- Remove top item

      assert.are.equal(1, test_stack:size())
      assert.are.same(item1, test_stack:top())
    end)

    it("should handle removal of non-existent window ID", function()
      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10)
      test_stack:push(item1)

      test_stack:remove_by_winid(999) -- Non-existent ID

      assert.are.equal(1, test_stack:size())
      assert.are.same(item1, test_stack:top())
    end)

  end)

  describe("Module-level API delegation", function()
    before_each(function()
      vim.w = {}
    end)

    it("should delegate push to current stack", function()
      local item = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10, 1)

      stack.push(item)

      local current_stack = stack.get_current_stack()
      assert.are.equal(1, current_stack:size())
      assert.are.same(item, current_stack:top())
      assert.are.equal(1, stack.size())
      assert.are.same(item, stack.top())
    end)

    it("should delegate size to current stack", function()
      assert.are.equal(0, stack.size())

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10))
      assert.are.equal(1, stack.size())

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WINIDS[2], 20))
      assert.are.equal(2, stack.size())
    end)

    it("should delegate top to current stack", function()
      assert.is_nil(stack.top())

      local item1 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10)
      stack.push(item1)
      assert.are.same(item1, stack.top())

      local item2 = create_test_item(TEST_CONSTANTS.POPUP_WINIDS[2], 20)
      stack.push(item2)
      assert.are.same(item2, stack.top())
    end)

    it("should delegate empty to current stack", function()
      assert.is_true(stack.empty())

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10))
      assert.is_false(stack.empty())
    end)

    it("should work with different window contexts", function()
      -- Test with regular window context
      vim.w = {}
      local regular_winid = TEST_CONSTANTS.ROOT_WINIDS[4]
      api_mock.nvim_get_current_win.returns(regular_winid)

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WINIDS[1], 10))
      assert.are.equal(1, stack.size())

      -- Test with popup window context
      local popup_root_winid = TEST_CONSTANTS.ROOT_WINIDS[5]
      vim.w = create_popup_context(popup_root_winid)

      stack.push(create_test_item(TEST_CONSTANTS.POPUP_WINIDS[2], 20))
      assert.are.equal(1, stack.size()) -- Different stack

      -- Verify separate stacks
      local regular_stack = stack.win_get_stack(regular_winid)
      local popup_stack = stack.win_get_stack(popup_root_winid)
      assert.are.equal(1, regular_stack:size())
      assert.are.equal(1, popup_stack:size())
      assert.are_not.equal(regular_stack, popup_stack)
    end)
  end)
end)
