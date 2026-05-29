---@diagnostic disable: undefined-field
local Window = require("overlook.window")

describe("overlook.window registry", function()
  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("creates a Window per root winid and returns the same instance for repeat calls", function()
    local w1 = Window.get(100)
    local w2 = Window.get(100)
    local w3 = Window.get(200)
    assert.are.equal(w1, w2)
    assert.are_not.equal(w1, w3)
    assert.are.equal(100, w1.winid)
    assert.are.equal(200, w3.winid)
  end)

  it("each Window owns its own Stack", function()
    local w1 = Window.get(100)
    local w2 = Window.get(200)
    assert.are_not.equal(w1.stack, w2.stack)
    assert.is_true(w1.stack:empty())
  end)

  it("Window.current resolves to the current real window when not in a popup", function()
    local real_win = vim.api.nvim_get_current_win()
    local w = Window.current()
    assert.are.equal(real_win, w.winid)
  end)

  it("Window.current uses vim.w.overlook_popup.root_winid when in a popup", function()
    vim.w = { is_overlook_popup = true, overlook_popup = { root_winid = 999 } }
    local w = Window.current()
    assert.are.equal(999, w.winid)
  end)
end)

local api = vim.api

-- Asserts the atomicity invariant from spec §4: every item in window.stack.items
-- is a live float. The reverse direction ("no overlook float exists outside the
-- stack") is not checked here — verifying that would require enumerating every
-- window in nvim and inspecting vim.w per window. These tests control float
-- creation, so we trust the absence of orphan floats by construction.
local function assert_invariant(window)
  for i, popup in ipairs(window.stack.items) do
    assert.is_true(
      popup:is_valid(),
      string.format("stack.items[%d] (winid=%s) is not a live float", i, tostring(popup.winid))
    )
  end
end

local function make_buf()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2", "line 3" })
  return buf
end

describe("Window:open_popup — happy path", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("opens a popup, pushes it, preserves the invariant", function()
    local w = Window.current()
    local p = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = "t" }
    assert.is_not_nil(p)
    assert.is_true(p:is_valid())
    assert.are.equal(1, w.stack:size())
    assert.are.equal(p, w.stack:top())
    assert_invariant(w)
    w:close_all()
  end)

  it("stacks multiple popups; invariant holds at every step", function()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = "1" }
    assert_invariant(w)
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = "2" }
    assert_invariant(w)
    local p3 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = "3" }
    assert_invariant(w)
    assert.are.equal(3, w.stack:size())
    assert.are.equal(p3, w.stack:top())
    w:close_all()
  end)
end)

describe("Window:open_popup — rollback", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("when nvim_open_win returns 0, nothing is pushed and no float leaks", function()
    local w = Window.current()
    local windows_before = #api.nvim_list_wins()
    local original = api.nvim_open_win
    api.nvim_open_win = function()
      return 0
    end

    local p = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    api.nvim_open_win = original

    assert.is_nil(p)
    assert.is_true(w.stack:empty())
    assert.are.equal(windows_before, #api.nvim_list_wins())
    assert_invariant(w)
  end)

  it("when post-open setup throws, the float is closed and nothing is pushed", function()
    local w = Window.current()
    local windows_before = #api.nvim_list_wins()
    -- Force the post-open path to throw by making nvim_win_get_config error.
    local original = api.nvim_win_get_config
    api.nvim_win_get_config = function()
      error("boom")
    end

    local p = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    api.nvim_win_get_config = original

    assert.is_nil(p)
    assert.is_true(w.stack:empty())
    assert.are.equal(windows_before, #api.nvim_list_wins())
    assert_invariant(w)
  end)
end)

describe("Window:close_all", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("closes all popups, empties the stack, refocuses root, preserves invariant", function()
    local root = api.nvim_get_current_win()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local winid1, winid2 = p1.winid, p2.winid

    w:close_all()

    assert.is_true(w.stack:empty())
    assert_invariant(w)
    assert.are.equal(root, api.nvim_get_current_win())
    assert.is_false(api.nvim_win_is_valid(winid1))
    assert.is_false(api.nvim_win_is_valid(winid2))
  end)
end)

describe("Window:on_popup_closed", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("reconciles a top close: pops, refocuses new top, preserves invariant", function()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    -- Simulate p2 closing under us (suppress WinClosed so we drive reconciliation manually).
    vim.opt.eventignore:append("WinClosed")
    api.nvim_win_close(p2.winid, true)
    vim.opt.eventignore:remove("WinClosed")

    w:on_popup_closed(p2.winid)

    assert.are.equal(1, w.stack:size())
    assert.are.equal(p1, w.stack:top())
    assert_invariant(w)
    w:close_all()
  end)

  it("reconciles a MIDDLE hole: removes the middle item, leaves siblings intact", function()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p3 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    vim.opt.eventignore:append("WinClosed")
    api.nvim_win_close(p2.winid, true)
    vim.opt.eventignore:remove("WinClosed")

    w:on_popup_closed(p2.winid)

    assert.are.equal(2, w.stack:size())
    assert.are.equal(p1, w.stack.items[1])
    assert.are.equal(p3, w.stack.items[2])
    assert_invariant(w)
    w:close_all()
  end)
end)

describe("Window:prune_invalid", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("pops invalid tops until a valid top is found", function()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p3 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    -- Close p3 and p2 manually without firing WinClosed; both top entries are now stale.
    vim.opt.eventignore:append("WinClosed")
    api.nvim_win_close(p3.winid, true)
    api.nvim_win_close(p2.winid, true)
    vim.opt.eventignore:remove("WinClosed")

    -- prune_invalid must remove both stale tops, leaving p1.
    w:prune_invalid()
    assert.are.equal(1, w.stack:size())
    assert.are.equal(p1, w.stack:top())
    assert_invariant(w)
    w:close_all()
  end)
end)

describe("Window.find_by_popup_winid", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("finds a popup in any stack position, not just the top", function()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    assert.are.equal(w, Window.find_by_popup_winid(p1.winid))
    assert.are.equal(w, Window.find_by_popup_winid(p2.winid))
    assert.is_nil(Window.find_by_popup_winid(99999))
    w:close_all()
  end)
end)

describe("init.lua WinClosed integration", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
    -- setup() registers a WinClosed autocmd on the global OverlookStateManagement
    -- augroup. The autocmd persists across all subsequent tests (re-registering it
    -- via setup() with clear=true is idempotent). Earlier describe blocks reset
    -- Window.instances = {} in their before_each, so find_by_popup_winid returns
    -- nil for any popups they create and the autocmd's branch is a no-op there.
    require("overlook").setup {}
  end)

  it("closing a popup window triggers stack reconciliation via the autocmd", function()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    -- Real close — WinClosed should fire and Window:on_popup_closed should reconcile.
    api.nvim_win_close(p2.winid, true)

    assert.are.equal(1, w.stack:size())
    assert.are.equal(p1, w.stack:top())
    assert_invariant(w)
    w:close_all()
  end)
end)

describe("Window:restore_all in multi-split layouts", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("restores all popups under the original host even if focus drifts mid-loop", function()
    -- Setup: two real splits.
    local root_left = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local root_right = api.nvim_get_current_win()
    assert.are_not.equal(root_left, root_right)

    -- Create 3 popups stacked under root_right (we're currently there).
    local w = Window.current()
    assert.are.equal(root_right, w.winid)
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = "1" }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = "2" }
    local p3 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = "3" }
    assert.is_not_nil(p1)
    assert.is_not_nil(p2)
    assert.is_not_nil(p3)
    assert_invariant(w)

    -- close_all puts them in trash and refocuses root_right.
    w:close_all()
    assert.are.equal(3, #w.stack.trash)
    assert.are.equal(root_right, api.nvim_get_current_win())

    -- Simulate focus drift to the OTHER split (root_left) before restore.
    -- This can happen in real usage via autocmds, plugin interactions, etc.
    api.nvim_set_current_win(root_left)
    assert.are.equal(root_left, api.nvim_get_current_win())

    -- Restore on the original Window (root_right). Even though focus is on root_left,
    -- all restored popups must anchor back to root_right, not to root_left.
    w:restore_all()

    assert.are.equal(3, w.stack:size())
    assert_invariant(w)

    -- The bottom-of-chain popup must be anchored to root_right (NOT root_left).
    local bottom = w.stack.items[1]
    local cfg = api.nvim_win_get_config(bottom.winid)
    assert.are.equal(root_right, cfg.win)
    assert.are.equal(root_right, bottom.root_winid)

    -- Each subsequent popup must be anchored to the previous one (chain stays within root_right).
    for i = 2, 3 do
      local popup = w.stack.items[i]
      local pcfg = api.nvim_win_get_config(popup.winid)
      assert.are.equal(w.stack.items[i - 1].winid, pcfg.win)
      assert.are.equal(root_right, popup.root_winid)
    end

    w:close_all()
    -- Clean up the extra vsplit so other tests aren't disturbed.
    local current = api.nvim_get_current_win()
    local to_close = (current ~= root_right) and root_right or root_left
    pcall(api.nvim_win_close, to_close, true)
  end)
end)

describe("Window:restore focuses the restored popup", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("leaves focus on the restored popup (single restore)", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    assert.are.equal(1, #w.stack.trash)

    w:restore()

    local top = w.stack:top()
    assert.is_not_nil(top)
    assert.are.equal(top.winid, api.nvim_get_current_win())
    assert_invariant(w)
    w:close_all()
  end)

  it("ends with focus on the top popup after restore_all", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()

    w:restore_all()

    assert.are.equal(3, w.stack:size())
    assert.are.equal(w.stack:top().winid, api.nvim_get_current_win())
    assert_invariant(w)
    w:close_all()
  end)
end)
