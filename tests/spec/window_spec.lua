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

  -- Regression: peek depth-5 collapse. Opening many popups in a tight loop
  -- (no event-loop tick between opens) used to leave deep-chain popups
  -- anchored to a still-provisional parent, collapsing them near the editor
  -- origin. Window:_spawn_popup now calls vim.cmd.redraw() after popup:open
  -- so each anchor is settled before the next iteration reads it.
  it("chain at depth 6 does not collapse (popups form a staircase)", function()
    local host = api.nvim_get_current_win()
    api.nvim_buf_set_lines(api.nvim_win_get_buf(host), 0, -1, false, { string.rep("x", 120) })
    api.nvim_win_set_cursor(host, { 1, 10 })

    local w = Window.current()
    for i = 1, 6 do
      w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1, title = tostring(i) }
    end
    assert.are.equal(6, w.stack:size())
    assert_invariant(w)

    -- Each popup must land at a distinct screen position from the previous
    -- one. If the layout cascade failed to resolve mid-loop, popups 2+ would
    -- collapse onto popup 1's position (or near the origin).
    local positions = {}
    for i, p in ipairs(w.stack.items) do
      positions[i] = api.nvim_win_get_position(p.winid)
    end
    for i = 2, #positions do
      assert.are_not.same(positions[i - 1], positions[i], string.format("popup %d collapsed onto popup %d", i, i - 1))
    end

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

  -- Compare eventignore as a SET (Neovim dedupes the option on assignment, so
  -- two sequences that differ only by duplicates are semantically equal).
  local function eventignore_set()
    local s = {}
    for _, v in ipairs(vim.opt.eventignore:get()) do
      s[v] = true
    end
    return s
  end

  before_each(function()
    Window.instances = {}
    vim.w = {}
    vim.opt.eventignore = ""
  end)

  after_each(function()
    vim.opt.eventignore = ""
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

  -- Regression: the previous `vim.opt.eventignore:remove(list)` cleanup stripped
  -- the named events unconditionally, wiping entries the user or another plugin
  -- had set before close_all. close_all now snapshots and restores verbatim.
  it("restores the caller's eventignore verbatim (empty before -> empty after)", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    assert.are.same({}, eventignore_set())
  end)

  it("restores the caller's eventignore verbatim (non-overlapping pre-set)", function()
    vim.opt.eventignore = { "CursorHold", "InsertLeave" }
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    assert.are.same({ CursorHold = true, InsertLeave = true }, eventignore_set())
  end)

  it("preserves the caller's eventignore entry that overlaps our suppression list", function()
    -- User had WinEnter in their eventignore BEFORE calling close_all. Our
    -- suppression added it (no-op via :append set semantics) and the old
    -- :remove(list) would have stripped it — losing the user's setting.
    vim.opt.eventignore = { "WinEnter" }
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    assert.are.same({ WinEnter = true }, eventignore_set())
  end)
end)

describe("Window bulk-op re-entry guard", function()
  local Window = require("overlook.window")

  local function eventignore_set()
    local s = {}
    for _, v in ipairs(vim.opt.eventignore:get()) do
      s[v] = true
    end
    return s
  end

  before_each(function()
    Window.instances = {}
    vim.w = {}
    vim.opt.eventignore = ""
  end)

  after_each(function()
    vim.opt.eventignore = ""
  end)

  it("on_popup_closed is a no-op while _reconcile_suspended is set", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    -- Close p2's window externally with WinClosed suppressed so we drive
    -- reconciliation by hand.
    vim.opt.eventignore:append("WinClosed")
    api.nvim_win_close(p2.winid, true)
    vim.opt.eventignore:remove("WinClosed")

    w._reconcile_suspended = true
    w:on_popup_closed(p2.winid)
    assert.are.equal(2, w.stack:size(), "guarded on_popup_closed must not touch the stack")

    w._reconcile_suspended = false
    w:on_popup_closed(p2.winid)
    assert.are.equal(1, w.stack:size(), "unguarded on_popup_closed reconciles normally")

    w:close_all()
  end)

  -- WinClosed is no longer suppressed during close_all: other plugins
  -- legitimately track window closes. Only OUR reconciliation is suspended.
  it("lets third-party WinClosed autocmds observe popup closes during close_all", function()
    local w = Window.current()
    local p1 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local p2 = w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local id1, id2 = p1.winid, p2.winid

    local seen = {}
    local aug = api.nvim_create_augroup("TestWinClosedSpy", { clear = true })
    api.nvim_create_autocmd("WinClosed", {
      group = aug,
      callback = function(args)
        seen[tonumber(args.match)] = true
      end,
    })

    w:close_all()
    api.nvim_del_augroup_by_id(aug)

    assert.is_true(seen[id1] == true, "third-party autocmd should see p1 close")
    assert.is_true(seen[id2] == true, "third-party autocmd should see p2 close")
  end)

  it("close_all re-raises loop errors after restoring eventignore and the flag", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    local top = w.stack:top()

    -- Shadow the instance's close to throw (hides the metatable method).
    top.close = function()
      error("boom")
    end

    vim.opt.eventignore = { "CursorHold" }
    assert.has_error(function()
      w:close_all()
    end)

    -- The guard's finalizer ran despite the re-raise.
    assert.are.same({ CursorHold = true }, eventignore_set())
    assert.is_false(w._reconcile_suspended)

    -- Cleanup: drop the shadow and close for real.
    top.close = nil
    w:close_all()
  end)

  -- Rider: close_all schedules update_keymap explicitly. The final
  -- nvim_set_current_win(host) is a no-op (firing no WinEnter) when focus is
  -- already on the host, so without the explicit schedule the dynamic close
  -- keymap on the dead popup's buffer would linger until the next Buf/WinEnter.
  it("close_all schedules update_keymap even when focus is already on the host", function()
    local host = api.nvim_get_current_win()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }

    -- Park focus on the host BEFORE close_all so the final set_current_win
    -- is a no-op; flush the WinEnter-noise schedule from this switch first.
    api.nvim_set_current_win(host)
    vim.wait(50, function()
      return false
    end)

    local state = require("overlook.state")
    local original = state.update_keymap
    local calls = 0
    state.update_keymap = function()
      calls = calls + 1
    end

    w:close_all()
    vim.wait(100, function()
      return calls > 0
    end)

    state.update_keymap = original
    assert.is_true(calls >= 1, "close_all must schedule update_keymap")
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

  -- Lazy prune: M.instances accumulates one entry per host winid the user ever
  -- peeked into. Without reaping, find_by_popup_winid's scan grows unbounded
  -- over a long session. The function now drops entries whose host winid is
  -- invalid AND whose stack + trash are both empty.
  it("reaps stale Window entries whose host is invalid with empty stack and trash", function()
    -- 9999 is not a real winid; Window.get creates an entry regardless.
    local stale = Window.get(9999)
    assert.are.equal(stale, Window.instances[9999])

    Window.find_by_popup_winid(0) -- any winid; trigger the scan

    assert.is_nil(Window.instances[9999])
  end)

  it("keeps stale-host Window entries that still hold popups (live or trashed)", function()
    -- Stale host, but stack has a live popup -> must NOT be reaped (otherwise
    -- the live popup would have no Window to dispatch on_popup_closed to).
    local with_items = Window.get(9998)
    table.insert(with_items.stack.items, { winid = 100 })

    -- Stale host, empty stack but non-empty trash -> must NOT be reaped (user
    -- could still restore_all those popups).
    local with_trash = Window.get(9997)
    table.insert(with_trash.stack.trash, { winid = 200 })

    Window.find_by_popup_winid(0)

    assert.is_not_nil(Window.instances[9998])
    assert.is_not_nil(Window.instances[9997])

    -- Cleanup so subsequent tests don't see these fakes.
    with_items.stack.items = {}
    with_trash.stack.trash = {}
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

describe("Window:restore_all eventignore preservation", function()
  local Window = require("overlook.window")

  -- Compare eventignore as a set (Neovim dedupes on assignment).
  local function eventignore_set()
    local s = {}
    for _, v in ipairs(vim.opt.eventignore:get()) do
      s[v] = true
    end
    return s
  end

  before_each(function()
    Window.instances = {}
    vim.w = {}
    vim.opt.eventignore = ""
  end)

  after_each(function()
    vim.opt.eventignore = ""
  end)

  it("restores empty eventignore verbatim", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    w:restore_all()
    assert.are.same({}, eventignore_set())
    w:close_all()
  end)

  it("preserves caller's non-overlapping eventignore entries", function()
    vim.opt.eventignore = { "CursorHold", "InsertLeave" }
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    -- close_all clears its own additions; re-set the user's entries here to
    -- isolate restore_all's behavior from close_all's.
    vim.opt.eventignore = { "CursorHold", "InsertLeave" }
    w:restore_all()
    assert.are.same({ CursorHold = true, InsertLeave = true }, eventignore_set())
    w:close_all()
  end)

  it("preserves caller's eventignore entry overlapping our suppression list", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    vim.opt.eventignore = { "WinEnter" }
    w:restore_all()
    assert.are.same({ WinEnter = true }, eventignore_set())
    w:close_all()
  end)

  it("restores eventignore even when the loop errors mid-restore", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()

    -- Shadow restore_one on this instance (via __index lookup, the metatable's
    -- restore_one is hidden by an instance field) to force it to throw on the
    -- second iteration. We monkey-patch the INSTANCE, not the module, because
    -- the test sees only the module exports (M), while restore_one lives on
    -- the metatable inside window.lua.
    local original = w.restore_one
    local call_count = 0
    w.restore_one = function(self_, enter)
      call_count = call_count + 1
      if call_count == 2 then
        error("boom")
      end
      return original(self_, enter)
    end

    vim.opt.eventignore = { "CursorHold" }
    local notify_calls = 0
    local original_notify = vim.notify
    vim.notify = function()
      notify_calls = notify_calls + 1
    end

    w:restore_all() -- should NOT propagate the error

    vim.notify = original_notify
    w.restore_one = nil -- remove the instance shadow

    assert.are.equal(1, notify_calls)
    assert.are.same({ CursorHold = true }, eventignore_set())

    w:close_all()
  end)
end)

describe("Window:restore_all rollback when a trashed popup is unrestorable", function()
  local Window = require("overlook.window")

  local function eventignore_set()
    local s = {}
    for _, v in ipairs(vim.opt.eventignore:get()) do
      s[v] = true
    end
    return s
  end

  before_each(function()
    Window.instances = {}
    vim.w = {}
    vim.opt.eventignore = ""
  end)

  after_each(function()
    vim.opt.eventignore = ""
  end)

  -- The rollback contract: if a trashed popup can no longer be opened (its
  -- target_bufnr has been wiped, the host died, etc.), Popup.new returns nil,
  -- restore_one returns (nil, true), the `peek_trash() == before` guard in
  -- restore_all breaks the loop, eventignore is restored, and a single notify
  -- explains why. Stack stays empty; trash retains the doomed entry.
  it("exits cleanly when a trashed popup's target_bufnr has been wiped", function()
    local w = Window.current()
    local doomed_buf = make_buf()
    w:open_popup { target_bufnr = doomed_buf, lnum = 1, col = 1 }
    w:close_all()
    assert.are.equal(1, #w.stack.trash)

    -- Wipe the buffer while the popup sits in trash.
    api.nvim_buf_delete(doomed_buf, { force = true })

    -- User-set entry to verify eventignore preservation across the rollback.
    vim.opt.eventignore = { "CursorHold" }

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    w:restore_all() -- must NOT crash

    vim.notify = original_notify

    assert.are.equal(0, w.stack:size(), "stack must stay empty when restore fails")
    assert.are.equal(1, #w.stack.trash, "doomed popup must remain in trash")
    assert.are.equal(1, #notifications, "exactly one notify should fire")
    assert.is_true(
      notifications[1].msg:find("target buffer") ~= nil,
      "notify message should mention the bad target buffer, got: " .. notifications[1].msg
    )
    assert.are.same({ CursorHold = true }, eventignore_set())
  end)
end)

describe("Window: restore preserves live buffer and cursor", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
    -- Register the WinLeave snapshot autocmd (idempotent: the augroup uses
    -- clear = true).
    require("overlook").setup {}
  end)

  -- When the user navigates inside a popup (gd, gf, :edit, etc.) the popup's
  -- window buffer changes but popup.opts.target_bufnr is captured once at
  -- peek time and never refreshed -- restore would reopen the ORIGINAL peek
  -- target instead of what the user was last viewing. Same applies to
  -- cursor position. Two snapshot paths cover this:
  --   (1) WinLeave autocmd in init.lua  -- focus leaves the popup
  --   (2) Popup:close                    -- close_all suppresses WinLeave
  it("snapshots via WinLeave when user switches focus before close_all", function()
    local host = api.nvim_get_current_win()
    local buf_a = make_buf()
    local buf_b = make_buf()

    local w = Window.current()
    local p = w:open_popup { target_bufnr = buf_a, lnum = 1, col = 1 }
    assert.is_not_nil(p)

    -- Mimic gd: switch popup's buffer and move the cursor.
    api.nvim_win_set_buf(p.winid, buf_b)
    api.nvim_win_set_cursor(p.winid, { 3, 0 }) -- 0-indexed col 0 == 1-indexed col 1

    -- User switches focus -> WinLeave fires on the popup -> snapshot.
    api.nvim_set_current_win(host)

    -- Live state was written back to opts.
    assert.are.equal(buf_b, p.opts.target_bufnr)
    assert.are.equal(3, p.opts.lnum)
    assert.are.equal(1, p.opts.col) -- opts.col is 1-indexed

    -- Close + restore should reopen buf_b at the snapshotted cursor.
    w:close_all()
    w:restore()
    local restored = w.stack:top()
    assert.are.equal(buf_b, api.nvim_win_get_buf(restored.winid))
    local cursor = api.nvim_win_get_cursor(restored.winid)
    assert.are.equal(3, cursor[1])
    assert.are.equal(0, cursor[2])

    w:close_all()
  end)

  it("snapshots via Popup:close when user is inside the popup at close_all time", function()
    local buf_a = make_buf()
    local buf_b = make_buf()

    local w = Window.current()
    local p = w:open_popup { target_bufnr = buf_a, lnum = 1, col = 1 }
    assert.is_not_nil(p)

    api.nvim_win_set_buf(p.winid, buf_b)
    api.nvim_win_set_cursor(p.winid, { 2, 0 })

    -- Do NOT leave focus first. close_all wraps the loop in eventignore so
    -- WinLeave is suppressed; Popup:close's snapshot must catch the live state.
    w:close_all()

    assert.are.equal(buf_b, w.stack.trash[1].opts.target_bufnr)
    assert.are.equal(2, w.stack.trash[1].opts.lnum)
    assert.are.equal(1, w.stack.trash[1].opts.col)

    w:restore()
    local restored = w.stack:top()
    assert.are.equal(buf_b, api.nvim_win_get_buf(restored.winid))
    local cursor = api.nvim_win_get_cursor(restored.winid)
    assert.are.equal(2, cursor[1])
    assert.are.equal(0, cursor[2])

    w:close_all()
  end)
end)

describe("Popup:open(false) opens without taking focus", function()
  local Popup = require("overlook.popup")

  before_each(function()
    require("overlook.window").instances = {}
    vim.w = {}
  end)

  it("leaves focus on the host but still marks the popup window", function()
    local host = api.nvim_get_current_win()
    local p = Popup.new({ target_bufnr = make_buf(), lnum = 1, col = 1 }, { root_winid = host, prev = nil, depth = 0 })
    assert.is_not_nil(p)

    local ok = p:open(false)

    assert.is_true(ok)
    assert.is_true(p:is_valid())
    assert.are.equal(host, api.nvim_get_current_win()) -- focus did NOT move to the popup
    assert.is_true(api.nvim_win_get_var(p.winid, "is_overlook_popup"))
    assert.are.equal(host, api.nvim_win_get_var(p.winid, "overlook_popup").root_winid)

    p:close()
  end)
end)

describe("Window:restore_all does not move focus through the popups", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("fires WinEnter at most once (final settle), not once per restored popup", function()
    local w = Window.current()
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:open_popup { target_bufnr = make_buf(), lnum = 1, col = 1 }
    w:close_all()
    assert.are.equal(3, #w.stack.trash)

    local win_enter = 0
    local grp = api.nvim_create_augroup("OverlookTestRestoreFocus", { clear = true })
    api.nvim_create_autocmd("WinEnter", {
      group = grp,
      callback = function()
        win_enter = win_enter + 1
      end,
    })

    w:restore_all()

    api.nvim_del_augroup_by_id(grp)

    assert.are.equal(3, w.stack:size())
    assert_invariant(w)
    -- restore_all uses enter=true on every iteration (the float-layout pass
    -- requires it); WinEnter is kept from firing because the loop is wrapped in
    -- eventignore for Win/Buf Enter/Leave. The single permissible WinEnter is
    -- the final top:focus() outside the eventignore window.
    assert.is_true(win_enter <= 1, "WinEnter fired " .. win_enter .. " times during restore_all; expected <= 1")
    -- focus ends on the top popup
    assert.are.equal(w.stack:top().winid, api.nvim_get_current_win())

    w:close_all()
  end)
end)
