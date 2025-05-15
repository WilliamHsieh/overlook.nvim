---@diagnostic disable: undefined-global
---@module "plenary"

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

-- The module under test
local Popup = require("overlook.popup")
local Stack = require("overlook.stack")
local State = require("overlook.state")

describe("Popup:config_for_first_popup", function()
  local orig_api_mocks = {}
  local orig_fn_mocks = {}
  local orig_vim_o = {}

  local function mock_api(name, func)
    if vim.api[name] then
      orig_api_mocks[name] = vim.api[name]
    end
    vim.api[name] = func
  end

  local function mock_fn(name, func)
    if vim.fn[name] then
      orig_fn_mocks[name] = vim.fn[name]
    end
    vim.fn[name] = func
  end

  before_each(function()
    orig_api_mocks = {}
    orig_fn_mocks = {}
    orig_vim_o = {}

    global_mock_config_module.reset_to_initial_state()

    -- Common Neovim API mocks
    mock_api("nvim_get_current_win", function()
      return 1000
    end)
    mock_api("nvim_win_get_position", function(_)
      return { 0, 0 }
    end) -- {row, col} of window's top-left
    mock_api("nvim_win_get_height", function(_)
      return 20
    end) -- Total window height
    mock_api("nvim_win_get_width", function(_)
      return 80
    end) -- Total window width

    -- Store and set vim.o.winbar (default to disabled)
    if vim.o.winbar ~= nil then
      orig_vim_o.winbar = vim.o.winbar
    else
      orig_vim_o.winbar = "" -- Assume it would have been empty
    end
    vim.o.winbar = "" -- Default to disabled for tests
  end)

  after_each(function()
    for name, func in pairs(orig_api_mocks) do
      vim.api[name] = func
    end
    for name, func in pairs(orig_fn_mocks) do
      vim.fn[name] = func
    end

    if vim.o.winbar ~= nil then
      vim.o.winbar = orig_vim_o.winbar
    end
    global_mock_config_module.reset_to_initial_state()
  end)

  local function create_popup_instance()
    local instance = setmetatable({}, Popup)
    instance.opts = { target_bufnr = 1, lnum = 1, col = 1 }
    return instance
  end

  describe("when popup is placed below the cursor", function()
    before_each(function()
      mock_api("nvim_win_get_cursor", function(_)
        return { 5, 10 }
      end)
      mock_fn("screenpos", function(_, _, _)
        return { row = 6, col = 11 }
      end)
    end)

    it("should calculate config correctly with winbar disabled", function()
      vim.o.winbar = ""
      local popup_instance = create_popup_instance()
      local Config = require("overlook.config").get()
      local win_config = popup_instance:config_for_first_popup()
      assert.are.same({
        relative = "win",
        style = "minimal",
        focusable = true,
        width = 64,
        height = 12,
        win = 1000,
        zindex = Config.ui.z_index_base,
        col = 11,
        row = 7,
      }, win_config)
      assert.are.equal(1000, popup_instance.orginal_win_id)
    end)

    it("should calculate config correctly with winbar enabled", function()
      vim.o.winbar = "enabled"
      local popup_instance = create_popup_instance()
      local Config = require("overlook.config").get()
      local win_config = popup_instance:config_for_first_popup()
      assert.are.same({
        relative = "win",
        style = "minimal",
        focusable = true,
        width = 64,
        height = 12,
        win = 1000,
        zindex = Config.ui.z_index_base,
        col = 11,
        row = 6,
      }, win_config)
      assert.are.equal(1000, popup_instance.orginal_win_id)
    end)
  end)

  describe("when popup is placed above the cursor", function()
    before_each(function()
      mock_api("nvim_win_get_cursor", function(_)
        return { 15, 10 }
      end)
      mock_fn("screenpos", function(_, _, _)
        return { row = 16, col = 11 }
      end)
    end)

    it("should calculate config correctly with winbar disabled", function()
      vim.o.winbar = ""
      local popup_instance = create_popup_instance()
      local Config = require("overlook.config").get()
      local win_config = popup_instance:config_for_first_popup()
      assert.are.same({
        relative = "win",
        style = "minimal",
        focusable = true,
        width = 64,
        height = 13,
        win = 1000,
        zindex = Config.ui.z_index_base,
        col = 11,
        row = 0,
      }, win_config)
      assert.are.equal(1000, popup_instance.orginal_win_id)
    end)

    it("should calculate config correctly with winbar enabled", function()
      vim.o.winbar = "enabled"
      local popup_instance = create_popup_instance()
      local Config = require("overlook.config").get()
      local win_config = popup_instance:config_for_first_popup()
      assert.are.same({
        relative = "win",
        style = "minimal",
        focusable = true,
        width = 64,
        height = 12,
        win = 1000,
        zindex = Config.ui.z_index_base,
        col = 11,
        row = 0,
      }, win_config)
      assert.are.equal(1000, popup_instance.orginal_win_id)
    end)
  end)

  describe(
    "when popup is at the threshold for placing below (screen_space_above == floor(max_window_height / 2))",
    function()
      it("should place BELOW with winbar disabled", function()
        vim.o.winbar = ""
        mock_fn("screenpos", function(_, _, _)
          return { row = 11, col = 11 }
        end)
        mock_api("nvim_win_get_cursor", function(_)
          return { 10, 10 }
        end)
        local popup_instance = create_popup_instance()
        local Config = require("overlook.config").get()
        local win_config = popup_instance:config_for_first_popup()
        assert.are.same({
          relative = "win",
          style = "minimal",
          focusable = true,
          width = 64,
          height = 7,
          win = 1000,
          zindex = Config.ui.z_index_base,
          col = 11,
          row = 12,
        }, win_config)
      end)

      it("should place BELOW with winbar enabled", function()
        vim.o.winbar = "enabled"
        mock_fn("screenpos", function(_, _, _)
          return { row = 11, col = 11 }
        end)
        mock_api("nvim_win_get_cursor", function(_)
          return { 10, 10 }
        end)
        local popup_instance = create_popup_instance()
        local Config = require("overlook.config").get()
        local win_config = popup_instance:config_for_first_popup()
        assert.are.same({
          relative = "win",
          style = "minimal",
          focusable = true,
          width = 64,
          height = 7,
          win = 1000,
          zindex = Config.ui.z_index_base,
          col = 11,
          row = 11,
        }, win_config)
      end)
    end
  )

  describe(
    "when popup is at the threshold for placing above (screen_space_above == floor(max_window_height / 2) + 1)",
    function()
      it("should place ABOVE with winbar disabled", function()
        vim.o.winbar = ""
        mock_fn("screenpos", function(_, _, _)
          return { row = 12, col = 11 }
        end)
        mock_api("nvim_win_get_cursor", function(_)
          return { 11, 10 }
        end)
        local popup_instance = create_popup_instance()
        local Config = require("overlook.config").get()
        local win_config = popup_instance:config_for_first_popup()
        assert.are.same({
          relative = "win",
          style = "minimal",
          focusable = true,
          width = 64,
          height = 9,
          win = 1000,
          zindex = Config.ui.z_index_base,
          col = 11,
          row = 0,
        }, win_config)
      end)

      it("should place ABOVE with winbar enabled", function()
        vim.o.winbar = "enabled"
        mock_fn("screenpos", function(_, _, _)
          return { row = 12, col = 11 }
        end)
        mock_api("nvim_win_get_cursor", function(_)
          return { 11, 10 }
        end)
        local popup_instance = create_popup_instance()
        local Config = require("overlook.config").get()
        local win_config = popup_instance:config_for_first_popup()
        assert.are.same({
          relative = "win",
          style = "minimal",
          focusable = true,
          width = 64,
          height = 8,
          win = 1000,
          zindex = Config.ui.z_index_base,
          col = 11,
          row = 0,
        }, win_config)
      end)
    end
  )
end)

describe("Popup:initialize_state", function()
  local orig_api_mocks = {}
  local orig_fn_mocks = {}
  local other_originals = {}
  local vim_notify_calls

  local function mock_api(name, func)
    if vim.api[name] then
      orig_api_mocks[name] = vim.api[name]
    else
      orig_api_mocks[name] = "__was_nil__"
    end
    vim.api[name] = func
  end

  before_each(function()
    orig_api_mocks = {}
    orig_fn_mocks = {}
    other_originals = {}
    vim_notify_calls = {}

    global_mock_config_module.reset_to_initial_state() -- Reset global config

    -- Mock vim.notify
    if vim.notify then
      other_originals.vim_notify = vim.notify
    end
    vim.notify = function(msg, level, opts)
      table.insert(vim_notify_calls, { msg = msg, level = level, opts = opts })
    end

    -- Default mock for nvim_buf_is_valid (can be overridden in tests)
    mock_api("nvim_buf_is_valid", function(_bufnr)
      return true
    end)
  end)

  after_each(function()
    for name, func in pairs(orig_api_mocks) do
      if func == "__was_nil__" then
        vim.api[name] = nil
      else
        vim.api[name] = func
      end
    end
    for name, func in pairs(orig_fn_mocks) do
      if func == "__was_nil__" then
        vim.fn[name] = nil
      else
        vim.fn[name] = func
      end
    end
    if other_originals.vim_notify then
      vim.notify = other_originals.vim_notify
    else
      vim.notify = nil -- If it didn't exist before, set to nil
    end
  end)

  it("should return false and notify if opts is nil", function()
    local popup_instance = setmetatable({}, Popup)
    local result = popup_instance:initialize_state(nil)
    assert.is_false(result)
    assert.are.equal(1, #vim_notify_calls)
    assert.match("Overlook: Invalid opts provided to Popup", vim_notify_calls[1].msg)
  end)

  it("should return false and notify if opts.target_bufnr is nil", function()
    local popup_instance = setmetatable({}, Popup)
    local result = popup_instance:initialize_state {}
    assert.is_false(result)
    assert.are.equal(1, #vim_notify_calls)
    assert.match("Overlook: target_bufnr missing in opts for Popup", vim_notify_calls[1].msg, 1, true)
  end)

  it("should return false and notify if target_bufnr is invalid", function()
    mock_api("nvim_buf_is_valid", function(bufnr)
      assert.are.equal(123, bufnr)
      return false
    end)
    local popup_instance = setmetatable({}, Popup)
    local result = popup_instance:initialize_state { target_bufnr = 123 }
    assert.is_false(result)
    assert.are.equal(1, #vim_notify_calls)
    assert.match("Overlook: Invalid target buffer for popup", vim_notify_calls[1].msg, 1, true)
  end)

  it("should return true and set opts if target_bufnr is valid", function()
    mock_api("nvim_buf_is_valid", function(bufnr)
      assert.are.equal(456, bufnr)
      return true
    end)
    local popup_instance = setmetatable({}, Popup)
    local opts_to_set = { target_bufnr = 456, lnum = 10, col = 5 }
    local result = popup_instance:initialize_state(opts_to_set)

    assert.is_true(result)
    assert.are.same(opts_to_set, popup_instance.opts)
    assert.are.equal(0, #vim_notify_calls) -- Should not notify
  end)
end)

describe("Popup:determine_window_configuration", function()
  local orig_api_mocks = {}
  local orig_fn_mocks = {}
  local other_originals = { vim_o = {} }
  local mock_method_calls -- To track calls to mocked methods of Popup
  local vim_notify_calls

  local original_popup_methods = {}
  local function mock_popup_method(instance, method_name, func)
    if not original_popup_methods[method_name] then
      original_popup_methods[method_name] = instance[method_name]
    end
    instance[method_name] = func
    table.insert(mock_method_calls.restoration_keys, { instance = instance, name = method_name })
  end

  before_each(function()
    orig_api_mocks = {}
    orig_fn_mocks = {}
    other_originals = { vim_o = {} }
    mock_method_calls = { log = {}, restoration_keys = {} }
    vim_notify_calls = {}
    original_popup_methods = {}

    global_mock_config_module.reset_to_initial_state()

    -- Mock Stack methods
    if Stack.empty then
      other_originals.Stack_empty = Stack.empty
    end
    Stack.empty = function()
      table.insert(mock_method_calls.log, { name = "Stack.empty" })
      return true
    end -- Default to empty
    if Stack.top then
      other_originals.Stack_top = Stack.top
    end
    Stack.top = function()
      table.insert(mock_method_calls.log, { name = "Stack.top" })
      return nil
    end -- Default to nil

    -- Mock vim.o.winborder
    if vim.o.winborder ~= nil then
      other_originals.vim_o.winborder = vim.o.winborder
    else
      other_originals.vim_o.winborder = "__was_nil__"
    end
    vim.o.winborder = nil -- Default to nil for testing fallbacks

    -- Mock vim.notify
    if vim.notify then
      other_originals.vim_notify = vim.notify
    end
    vim.notify = function(msg, level)
      table.insert(vim_notify_calls, { msg = msg, level = level })
    end
  end)

  after_each(function()
    for name, func in pairs(orig_api_mocks) do
      if func == "__was_nil__" then
        vim.api[name] = nil
      else
        vim.api[name] = func
      end
    end
    for name, func in pairs(orig_fn_mocks) do
      if func == "__was_nil__" then
        vim.fn[name] = nil
      else
        vim.fn[name] = func
      end
    end

    if other_originals.Stack_empty then
      Stack.empty = other_originals.Stack_empty
    else
      Stack.empty = nil
    end
    if other_originals.Stack_top then
      Stack.top = other_originals.Stack_top
    else
      Stack.top = nil
    end

    for _, key_info in ipairs(mock_method_calls.restoration_keys) do
      if original_popup_methods[key_info.name] then
        key_info.instance[key_info.name] = original_popup_methods[key_info.name]
      end
    end

    if other_originals.vim_o.winborder ~= nil then
      if other_originals.vim_o.winborder == "__was_nil__" then
        vim.o.winborder = nil
      else
        vim.o.winborder = other_originals.vim_o.winborder
      end
    end
    if other_originals.vim_notify then
      vim.notify = other_originals.vim_notify
    else
      vim.notify = nil
    end
  end)

  local function create_test_instance(opts)
    local instance = setmetatable({}, Popup)
    instance.opts = opts or { target_bufnr = 1 } -- Basic opts
    -- Mock actual methods that would be called
    mock_popup_method(instance, "config_for_first_popup", function(self_arg)
      table.insert(mock_method_calls.log, { name = "config_for_first_popup", self = self_arg })
      return { mock_cfg = "first_popup_base" } -- Return a base config
    end)
    mock_popup_method(instance, "config_for_stacked_popup", function(self_arg, prev_arg)
      table.insert(mock_method_calls.log, { name = "config_for_stacked_popup", self = self_arg, prev = prev_arg })
      return { mock_cfg = "stacked_popup_base" } -- Return a base config
    end)
    return instance
  end

  it("first popup: should call config_for_first_popup and set defaults", function()
    local popup_instance = create_test_instance { title = "Test Title" }
    Stack.empty = function()
      table.insert(mock_method_calls.log, { name = "Stack.empty" })
      return true
    end

    local result = popup_instance:determine_window_configuration()

    assert.is_true(result)
    assert.is_true(popup_instance.is_first_popup)
    local called_config_first = false
    for _, call in ipairs(mock_method_calls.log) do
      if call.name == "config_for_first_popup" then
        called_config_first = true
        break
      end
    end
    assert.is_true(called_config_first, "config_for_first_popup was not called")

    assert.is_table(popup_instance.win_config)
    assert.are.equal("double", popup_instance.win_config.border) -- From global_mock_config_module
    assert.are.equal("Test Title", popup_instance.win_config.title)
    assert.are.equal("center", popup_instance.win_config.title_pos)
    assert.are.equal("first_popup_base", popup_instance.win_config.mock_cfg)
  end)

  it("first popup: should use default title if opts.title is nil", function()
    local popup_instance = create_test_instance { target_bufnr = 1 } -- No title in opts
    Stack.empty = function()
      table.insert(mock_method_calls.log, { name = "Stack.empty" })
      return true
    end

    popup_instance:determine_window_configuration()
    assert.are.equal("Overlook default title", popup_instance.win_config.title)
  end)

  it("stacked popup: should call config_for_stacked_popup and set defaults", function()
    local mock_prev_item = { win_id = 2000, width = 50, height = 10, bufnr = 2, opts = {} } -- Basic prev item
    local popup_instance = create_test_instance { title = "Stacked Title" }

    Stack.empty = function()
      table.insert(mock_method_calls.log, { name = "Stack.empty" })
      return false
    end
    Stack.top = function()
      table.insert(mock_method_calls.log, { name = "Stack.top" })
      return mock_prev_item
    end

    local result = popup_instance:determine_window_configuration()

    assert.is_true(result)
    assert.is_false(popup_instance.is_first_popup)

    local called_config_stacked = false
    local passed_prev_item
    for _, call in ipairs(mock_method_calls.log) do
      if call.name == "config_for_stacked_popup" then
        called_config_stacked = true
        passed_prev_item = call.prev
        break
      end
    end
    assert.is_true(called_config_stacked, "config_for_stacked_popup was not called")
    assert.are.same(mock_prev_item, passed_prev_item)

    assert.is_table(popup_instance.win_config)
    assert.are.equal("double", popup_instance.win_config.border) -- From global_mock_config_module
    assert.are.equal("Stacked Title", popup_instance.win_config.title)
    assert.are.equal("center", popup_instance.win_config.title_pos)
    assert.are.equal("stacked_popup_base", popup_instance.win_config.mock_cfg)
  end)

  it("stacked popup: should return false if Stack.top() is nil", function()
    local popup_instance = create_test_instance()
    Stack.empty = function()
      table.insert(mock_method_calls.log, { name = "Stack.empty" })
      return false
    end
    Stack.top = function()
      table.insert(mock_method_calls.log, { name = "Stack.top" })
      return nil
    end -- Stack.top returns nil

    local result = popup_instance:determine_window_configuration()
    assert.is_false(result)
    assert.are.equal(1, #vim_notify_calls)
    assert.match("Overlook: Failed to get previous popup from stack", vim_notify_calls[1].msg, 1, true)
  end)

  -- Tests for border logic
  it("border: should use Config.ui.border if available", function()
    global_mock_config_module.options.ui.border = "single"
    local popup_instance = create_test_instance()
    Stack.empty = function()
      return true
    end -- Make it a first popup for simplicity

    popup_instance:determine_window_configuration()
    assert.are.equal("single", popup_instance.win_config.border)
  end)

  it("border: should use vim.o.winborder if Config.ui.border is nil", function()
    global_mock_config_module.options.ui.border = nil
    vim.o.winborder = "single"
    local popup_instance = create_test_instance()
    Stack.empty = function()
      return true
    end

    popup_instance:determine_window_configuration()
    assert.are.equal("single", popup_instance.win_config.border)
  end)

  it("border: should use 'rounded' if Config.ui.border and vim.o.winborder are nil", function()
    global_mock_config_module.options.ui.border = nil
    vim.o.winborder = nil -- This is also the default set in before_each for this describe block
    local popup_instance = create_test_instance()
    Stack.empty = function()
      return true
    end

    popup_instance:determine_window_configuration()
    assert.are.equal("rounded", popup_instance.win_config.border)
  end)
end)

describe("Popup:open_and_register_window", function()
  local orig_api_mocks = {}
  local other_originals = {}
  local vim_notify_calls
  local state_register_calls

  local function mock_api(name, func) -- standard mock_api
    if vim.api[name] then
      orig_api_mocks[name] = vim.api[name]
    else
      orig_api_mocks[name] = "__was_nil__"
    end
    vim.api[name] = func
  end

  before_each(function()
    orig_api_mocks = {}
    other_originals = {}
    vim_notify_calls = {}
    state_register_calls = {}
    global_mock_config_module.reset_to_initial_state()

    -- Mock vim.notify
    if vim.notify then
      other_originals.vim_notify = vim.notify
    end
    vim.notify = function(msg, level)
      table.insert(vim_notify_calls, { msg = msg, level = level })
    end

    -- Mock State.register_overlook_popup
    if State.register_overlook_popup then
      other_originals.State_register = State.register_overlook_popup
    end
    State.register_overlook_popup = function(win_id, bufnr)
      table.insert(state_register_calls, { win_id = win_id, bufnr = bufnr })
    end

    -- Default mock for nvim_open_win (can be overridden in tests)
    mock_api("nvim_open_win", function()
      return 1001
    end)
  end)

  after_each(function()
    for name, func in pairs(orig_api_mocks) do
      if func == "__was_nil__" then
        vim.api[name] = nil
      else
        vim.api[name] = func
      end
    end
    if other_originals.vim_notify then
      vim.notify = other_originals.vim_notify
    else
      vim.notify = nil
    end
    if other_originals.State_register then
      State.register_overlook_popup = other_originals.State_register
    else
      State.register_overlook_popup = nil
    end
  end)

  local function create_test_instance(opts_override, win_config_override)
    local instance = setmetatable({}, Popup)
    instance.opts = opts_override or { target_bufnr = 1 } -- Default opts
    instance.win_config = win_config_override or { style = "minimal", width = 10, height = 5 } -- Default win_config
    return instance
  end

  it("should open window, register it, and return true on success", function()
    local test_opts = { target_bufnr = 99 }
    local test_win_config = { border = "single", width = 20, height = 8 }
    local popup_instance = create_test_instance(test_opts, test_win_config)
    local nvim_open_win_calls = {}
    mock_api("nvim_open_win", function(bufnr, enter, config)
      table.insert(nvim_open_win_calls, { bufnr = bufnr, enter = enter, config = config })
      return 1001 -- Mocked win_id
    end)

    local result = popup_instance:open_and_register_window()

    assert.is_true(result)
    assert.are.equal(1001, popup_instance.win_id)

    assert.are.equal(1, #nvim_open_win_calls)
    assert.are.equal(test_opts.target_bufnr, nvim_open_win_calls[1].bufnr)
    assert.is_true(nvim_open_win_calls[1].enter)
    assert.are.same(test_win_config, nvim_open_win_calls[1].config)

    assert.are.equal(1, #state_register_calls)
    assert.are.equal(1001, state_register_calls[1].win_id)
    assert.are.equal(test_opts.target_bufnr, state_register_calls[1].bufnr)

    assert.are.equal(0, #vim_notify_calls)
  end)

  it("should return false and notify if nvim_open_win fails", function()
    local popup_instance = create_test_instance()
    mock_api("nvim_open_win", function()
      return 0
    end) -- nvim_open_win returns 0 (failure)

    local result = popup_instance:open_and_register_window()

    assert.is_false(result)
    assert.are.equal(1, #vim_notify_calls)
    assert.match("Overlook: Failed to open popup window", vim_notify_calls[1].msg, 1, true)
    assert.are.equal(0, #state_register_calls) -- State.register should not be called
    assert.are.equal(0, popup_instance.win_id) -- win_id should be 0 on failure, not nil
  end)
end)

describe("Popup:configure_opened_window_details", function()
  local orig_api_mocks = {}
  local other_originals = {}
  local nvim_win_set_cursor_calls
  local nvim_win_call_calls
  local vim_cmd_calls -- To specifically track vim.cmd calls from within nvim_win_call

  local function mock_api(name, func) -- standard mock_api
    if vim.api[name] then
      orig_api_mocks[name] = vim.api[name]
    else
      orig_api_mocks[name] = "__was_nil__"
    end
    vim.api[name] = func
  end

  before_each(function()
    orig_api_mocks = {}
    other_originals = {}
    nvim_win_set_cursor_calls = {}
    nvim_win_call_calls = {}
    vim_cmd_calls = {}
    global_mock_config_module.reset_to_initial_state()

    -- Mock nvim_win_set_cursor
    mock_api("nvim_win_set_cursor", function(winid, pos)
      table.insert(nvim_win_set_cursor_calls, { winid = winid, pos = pos })
    end)

    -- Mock nvim_win_call
    mock_api("nvim_win_call", function(winid, callback_fn)
      table.insert(nvim_win_call_calls, { winid = winid, callback_fn = callback_fn })
      -- Execute the callback, but with vim.cmd mocked to capture its call
      local original_vim_cmd = vim.cmd
      if vim.cmd then
        other_originals.vim_cmd_in_win_call = vim.cmd
      end
      vim.cmd = function(cmd_str)
        table.insert(vim_cmd_calls, cmd_str)
      end
      callback_fn() -- Execute the callback
      if other_originals.vim_cmd_in_win_call then
        vim.cmd = other_originals.vim_cmd_in_win_call
      else
        vim.cmd = original_vim_cmd
      end
    end)
  end)

  after_each(function()
    for name, func in pairs(orig_api_mocks) do
      if func == "__was_nil__" then
        vim.api[name] = nil
      else
        vim.api[name] = func
      end
    end
    -- Restore vim.cmd if it was mocked by nvim_win_call mock (it should be restored by the mock itself but as a safeguard)
    if other_originals.vim_cmd_in_win_call then
      vim.cmd = other_originals.vim_cmd_in_win_call
    end
  end)

  local function create_test_instance(win_id_val, opts_val)
    local instance = setmetatable({}, Popup)
    instance.win_id = win_id_val or 1001
    instance.opts = opts_val or { lnum = 5, col = 10 } -- Default opts
    return instance
  end

  it("should set cursor and execute 'normal! zz' via nvim_win_call", function()
    local test_win_id = 1234
    local test_opts = { lnum = 7, col = 15 }
    local popup_instance = create_test_instance(test_win_id, test_opts)

    popup_instance:configure_opened_window_details()

    assert.are.equal(1, #nvim_win_set_cursor_calls)
    assert.are.equal(test_win_id, nvim_win_set_cursor_calls[1].winid)
    assert.are.same({ test_opts.lnum, math.max(0, test_opts.col - 1) }, nvim_win_set_cursor_calls[1].pos)

    assert.are.equal(1, #nvim_win_call_calls)
    assert.are.equal(test_win_id, nvim_win_call_calls[1].winid)
    assert.is_function(nvim_win_call_calls[1].callback_fn)

    assert.are.equal(1, #vim_cmd_calls)
    assert.are.equal("normal! zz", vim_cmd_calls[1])
  end)
end)

describe("Popup:create_close_autocommand", function()
  local orig_api_mocks = {}
  local other_originals = {}
  local nvim_create_autocmd_calls
  local stack_handle_win_close_calls

  local function mock_api(name, func) -- standard mock_api
    if vim.api[name] then
      orig_api_mocks[name] = vim.api[name]
    else
      orig_api_mocks[name] = "__was_nil__"
    end
    vim.api[name] = func
  end

  before_each(function()
    orig_api_mocks = {}
    other_originals = {}
    nvim_create_autocmd_calls = {}
    stack_handle_win_close_calls = {}
    global_mock_config_module.reset_to_initial_state()

    -- Mock nvim_create_autocmd
    mock_api("nvim_create_autocmd", function(event, opts)
      table.insert(nvim_create_autocmd_calls, { event = event, opts = opts })
    end)

    -- Mock Stack.handle_win_close
    if Stack.handle_win_close then
      other_originals.Stack_handle_win_close = Stack.handle_win_close
    end
    Stack.handle_win_close = function(win_id)
      table.insert(stack_handle_win_close_calls, win_id)
    end
  end)

  after_each(function()
    for name, func in pairs(orig_api_mocks) do
      if func == "__was_nil__" then
        vim.api[name] = nil
      else
        vim.api[name] = func
      end
    end
    if other_originals.Stack_handle_win_close then
      Stack.handle_win_close = other_originals.Stack_handle_win_close
    else
      Stack.handle_win_close = nil
    end
  end)

  local function create_test_instance(win_id_val)
    local instance = setmetatable({}, Popup)
    instance.win_id = win_id_val or 1001
    -- opts is not directly used by create_close_autocommand but usually present
    instance.opts = { target_bufnr = 1, lnum = 1, col = 1 }
    return instance
  end

  it("should create WinClosed autocommand with correct parameters and callback logic", function()
    local test_win_id = 5555
    local popup_instance = create_test_instance(test_win_id)

    popup_instance:create_close_autocommand()

    assert.are.equal(1, #nvim_create_autocmd_calls)
    local autocmd_call = nvim_create_autocmd_calls[1]
    assert.are.equal("WinClosed", autocmd_call.event)

    local opts = autocmd_call.opts
    assert.is_table(opts)
    assert.is_number(opts.group) -- Check that augroup_id is a number (actual ID is module-private)
    assert.are.equal(tostring(test_win_id), opts.pattern)
    assert.is_true(opts.once)
    assert.is_function(opts.callback)

    -- Test the callback logic
    -- 1. Call with non-matching args.match (Neovim provides args.match for WinClosed with pattern)
    opts.callback { match = tostring(test_win_id + 1) } -- Different win_id
    assert.are.equal(
      0,
      #stack_handle_win_close_calls,
      "Stack.handle_win_close should not be called for non-matching win_id"
    )

    opts.callback { file = "somefile.lua" } -- Call with irrelevant args, match will be nil
    assert.are.equal(0, #stack_handle_win_close_calls, "Stack.handle_win_close should not be called for nil args.match")

    -- 2. Call with matching args.match
    opts.callback { match = tostring(test_win_id) } -- Matching win_id
    assert.are.equal(1, #stack_handle_win_close_calls, "Stack.handle_win_close was not called for matching win_id")
    assert.are.equal(test_win_id, stack_handle_win_close_calls[1])
  end)
end)
