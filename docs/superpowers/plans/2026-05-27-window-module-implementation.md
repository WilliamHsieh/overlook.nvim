# Window Module Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decouple window operations from `stack.lua` into a `Window` → `Stack` → `Popups` hierarchy with an atomicity invariant — `stack.items` is exactly the set of live popup floats for that root window — preserved across every transaction.

**Architecture:** Three modules — `stack.lua` (pure data, zero `vim.api`), `popup.lua` (one popup owns its own float lifecycle), `window.lua` (`Window` object + per-root-window registry + all stack-aware / multi-popup transactions). `ui.lua` is deleted. Each transaction is written so any partial failure leaves no orphan float and no orphan stack item. See `docs/superpowers/specs/2026-05-22-window-module-design.md` for the full design.

**Tech Stack:** Lua, Neovim API, plenary.nvim + busted (testing). `make test` runs the suite inside a headless Neovim. The new `window_spec.lua` uses real floats rather than mocking `vim.api`.

**Branch:** `feature/window-module-v2` (already at master + the spec commit). Every task ends with a passing `make test` and a single commit.

**Conventional commits:** This repo uses `feat:` / `refactor:` / `test:` / `fix:` / `docs:` / `chore:` prefixes (see `git log`).

---

## File Map

| File | Disposition |
|---|---|
| `lua/overlook/stack.lua` | Rewritten — pure `Stack` class, no `vim.api`, no module facade |
| `lua/overlook/popup.lua` | Refactored — `Popup.new(opts, ctx)` + `popup:open/close/is_valid/focus`; no `Stack` require |
| `lua/overlook/window.lua` | **New** — `Window` class + host registry + all transaction methods |
| `lua/overlook/ui.lua` | **Deleted** — `create_popup` becomes `Window:open_popup`, `promote_popup_to_window` becomes `Window:promote` |
| `lua/overlook/peek.lua` | `Ui.create_popup` → `Window.current():open_popup` (sync + async paths) |
| `lua/overlook/api.lua` | Delegates to `Window.current():...` for `close_all`, `restore*`, `switch_focus`, `open_in_*` |
| `lua/overlook/init.lua` | `WinClosed` autocmd uses `Window.find_by_popup_winid(winid):on_popup_closed(winid)` |
| `lua/overlook/state.lua` | `Stack.top()` (×2) → `Window.current():top()` |
| `tests/spec/stack_spec.lua` | Rewritten — pure data tests, no `vim.api` mocking |
| `tests/spec/popup_spec.lua` | Adapted — pass `ctx`; add `popup:open/close/is_valid/focus` tests |
| `tests/spec/window_spec.lua` | **New** — real-window atomicity suite + invariant helper |
| `tests/spec/peek_spec.lua` | Updated for the new `Window` wiring |
| `tests/spec/state_spec.lua` | Updated for the new `Window` wiring |

---

### Task 1: Create `window.lua` skeleton with host registry

**Goal:** Stand up the new module with the registry only — no transaction methods, no behavior change. Pure scaffolding so later tasks have somewhere to land code.

**Files:**
- Create: `lua/overlook/window.lua`
- Create: `tests/spec/window_spec.lua`

- [ ] **Step 1: Write the failing registry tests**

Create `tests/spec/window_spec.lua` with:

```lua
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
    vim.w = {}
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
```

- [ ] **Step 2: Run, confirm failure**

Run: `make test`
Expected: `window_spec.lua` errors with `module 'overlook.window' not found` or similar.

- [ ] **Step 3: Create the minimal `window.lua`**

Create `lua/overlook/window.lua`:

```lua
local api = vim.api
local Stack = require("overlook.stack")

---@class OverlookWindow
---@field winid integer         -- root (host) window id
---@field stack OverlookStack
local Window = {}
Window.__index = Window

---@param winid integer
---@return OverlookWindow
function Window.new(winid)
  return setmetatable({ winid = winid, stack = Stack.new(winid) }, Window)
end

-- Module-level registry / facade
local M = {}

---@type table<integer, OverlookWindow>
M.instances = {}

---Get-or-create the Window for a given root winid.
---@param winid integer
---@return OverlookWindow
function M.get(winid)
  if not M.instances[winid] then
    M.instances[winid] = Window.new(winid)
  end
  return M.instances[winid]
end

---Resolve the Window for the current Neovim context.
---If the current window is one of our popups, use its recorded root_winid;
---otherwise use the current window itself as the root.
---@return OverlookWindow
function M.current()
  local winid
  if vim.w.is_overlook_popup then
    winid = vim.w.overlook_popup.root_winid
  else
    winid = api.nvim_get_current_win()
  end
  return M.get(winid)
end

return M
```

Note: `Stack.new(winid)` is the *current* (master) constructor signature; we still pass `winid` here to preserve compatibility. Task 5 drops the `winid` argument when Stack purifies.

- [ ] **Step 4: Run, confirm pass**

Run: `make test`
Expected: window_spec passes. No existing tests changed → all green.

- [ ] **Step 5: Commit**

```bash
git add lua/overlook/window.lua tests/spec/window_spec.lua
git commit -m "feat(window): add window module skeleton with host registry"
```

---

### Task 2: Move `ui.lua`'s `create_popup` and `promote` into `Window`; delete `ui.lua`

**Goal:** Relocate orchestration without changing behavior. The `Window:open_popup` and `Window:promote` methods initially wrap the existing `Popup.new` + `Stack.push` flow.

**Files:**
- Modify: `lua/overlook/window.lua`
- Modify: `lua/overlook/peek.lua`
- Modify: `lua/overlook/api.lua`
- Modify: `tests/spec/peek_spec.lua`
- Delete: `lua/overlook/ui.lua`

- [ ] **Step 1: Add `Window:open_popup` and `Window:promote`**

Append to `lua/overlook/window.lua` (above `return M`):

```lua
---Creates and pushes a popup. Behavior matches the deleted ui.create_popup.
---@param opts OverlookPopupOptions
---@return OverlookPopup?
function Window:open_popup(opts)
  local Popup = require("overlook.popup")
  local popup = Popup.new(opts)
  if not popup then
    return nil
  end
  -- Push onto the *popup's* root window's stack (Popup.new sets popup.root_winid
  -- based on the current real window). This matches the old ui.create_popup
  -- behavior exactly.
  local target = M.get(popup.root_winid)
  target.stack:push(popup)
  return popup
end

---Promote the top popup to a real window via the given command (split/vsplit/tabnew/buffer).
---Behavior matches the deleted ui.promote_popup_to_window.
---@param open_command string Vim command, e.g. "split | buffer" or "buffer".
function Window:promote(open_command)
  local Popup = require("overlook.popup")
  if self.stack:empty() or not vim.w.is_overlook_popup then
    vim.notify("Overlook: No popup to promote.", vim.log.levels.INFO)
    return
  end

  local buf_id = api.nvim_get_current_buf()
  ---@diagnostic disable-next-line: unused-local
  local _bufnum, lnum, col, _off = unpack(vim.fn.getpos("."))

  self.stack:clear()

  if not buf_id or not api.nvim_buf_is_valid(buf_id) then
    vim.notify(
      string.format("Overlook Error: Buffer to promote is invalid (ID: %s).", tostring(buf_id)),
      vim.log.levels.ERROR
    )
    return
  end

  local cmd = string.format("%s %d", open_command, buf_id)
  ---@diagnostic disable-next-line: param-type-mismatch
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify(
      string.format("Overlook Error: Failed to execute command '%s': %s", cmd, tostring(err)),
      vim.log.levels.ERROR
    )
    return
  end

  Popup.set_cursor_position(0, lnum, col)
  vim.bo.buflisted = true
end
```

- [ ] **Step 2: Update `peek.lua` to use `Window`**

In `lua/overlook/peek.lua`, replace **both** occurrences of `require("overlook.ui").create_popup(opts)` with `require("overlook.window").current():open_popup(opts)`:

```lua
-- async path (inside the `if adapter.async then ... end` block):
adapter.async_create_popup(function(opts)
  require("overlook.window").current():open_popup(opts)
end, ...)
return

-- sync path (after the opts nil check):
require("overlook.window").current():open_popup(opts)
```

- [ ] **Step 3: Update `api.lua` to use `Window`**

In `lua/overlook/api.lua`:

- Replace `local Ui = require("overlook.ui")` with `local Window = require("overlook.window")` at the top.
- Replace `Ui.promote_popup_to_window(cmd)` (inside `promote_top_to_window`) with `Window.current():promote(cmd)`.
- Replace `Ui.promote_popup_to_window("buffer")` (inside `M.open_in_original_window`) with `Window.current():promote("buffer")`.

- [ ] **Step 4: Delete `ui.lua`**

Run: `rm lua/overlook/ui.lua`

- [ ] **Step 5: Update `peek_spec.lua`**

In `tests/spec/peek_spec.lua`, any stub of `require("overlook.ui").create_popup` becomes a stub of `require("overlook.window")` returning a fake Window whose `open_popup` is the stubbed function. Concrete pattern:

```lua
local fake_window = { open_popup = stub() }
package.loaded["overlook.window"] = {
  current = function() return fake_window end,
}
```

- [ ] **Step 6: Run tests, confirm pass**

Run: `make test`
Expected: all green. If `peek_spec` was previously passing with the `ui` stub style, update it minimally to the pattern above. If any other test stubs `overlook.ui`, switch it to stub `overlook.window` similarly.

- [ ] **Step 7: Commit**

```bash
git add lua/overlook/window.lua lua/overlook/peek.lua lua/overlook/api.lua tests/spec/peek_spec.lua
git rm lua/overlook/ui.lua
git commit -m "refactor(window): absorb ui.lua into Window:open_popup and Window:promote"
```

---

### Task 3: Move stack-window operations from `Stack` to `Window`

**Goal:** Pull `clear`, `on_close`, `restore`, `restore_all`, `remove_invalid_windows` out of `Stack` and into the corresponding `Window` transaction methods. Add `Window:switch_focus` and `Window.find_by_popup_winid`. Update `state.lua`, `init.lua`, `api.lua` callers. `Stack` still has its augroup/`root_winid` at this stage — Task 5 strips those.

**Files:**
- Modify: `lua/overlook/window.lua`
- Modify: `lua/overlook/stack.lua`
- Modify: `lua/overlook/popup.lua` (remove `M.on_close` — its logic moves to Window)
- Modify: `lua/overlook/api.lua`
- Modify: `lua/overlook/init.lua`
- Modify: `lua/overlook/state.lua`

- [ ] **Step 1: Add `Window:close_all` (replaces `Stack:clear`)**

Append to `window.lua`:

```lua
---Close all popups in this Window's stack atomically.
---Suppresses WinClosed during the bulk close to prevent re-entrant reconciliation,
---then refocuses the root window.
---@param force? boolean
function Window:close_all(force)
  vim.opt.eventignore:append("WinClosed")

  while not self.stack:empty() do
    local top = self.stack:top()
    if top and api.nvim_win_is_valid(top.winid) then
      api.nvim_win_close(top.winid, force or false)
    end
    self.stack:pop()
  end

  vim.opt.eventignore:remove("WinClosed")
  pcall(api.nvim_set_current_win, self.winid)
end
```

- [ ] **Step 2: Add `Window:prune_invalid` (replaces `Stack:remove_invalid_windows`)**

Append to `window.lua`:

```lua
---Pop popups from the top while the top popup's window is invalid.
---Used as a reconciliation safety net.
function Window:prune_invalid()
  while not self.stack:empty() do
    local top = self.stack:top()
    if top and api.nvim_win_is_valid(top.winid) then
      return
    end
    self.stack:pop()
  end
end
```

- [ ] **Step 3: Add `Window:on_popup_closed` (replaces `Stack:on_close` and `Popup.on_close`)**

Append to `window.lua`:

```lua
---WinClosed reconciliation: a popup window is already gone; bring the stack in sync.
---Always refocuses (the closed window was typically the focused one).
---@param winid integer The closed popup's window id.
function Window:on_popup_closed(winid)
  self.stack:remove_by_winid(winid)
  self:prune_invalid()

  local top = self.stack:top()
  if top and api.nvim_win_is_valid(top.winid) then
    pcall(api.nvim_set_current_win, top.winid)
  else
    pcall(api.nvim_set_current_win, self.winid)

    local config = require("overlook.config").get()
    if type(config.on_stack_empty) == "function" then
      local ok, err = pcall(config.on_stack_empty)
      if not ok then
        vim.notify("Overlook Error: on_stack_empty callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  vim.schedule(function()
    require("overlook.state").update_keymap()
  end)
end
```

- [ ] **Step 4: Add `Window:restore` and `Window:restore_all`**

Append to `window.lua`:

```lua
---Restore the most recently closed popup.
function Window:restore()
  if #self.stack.trash == 0 then
    vim.notify("Overlook: No popup to restore", vim.log.levels.WARN)
    return
  end

  local Popup = require("overlook.popup")
  ---@type OverlookPopup
  local closed = self.stack.trash[#self.stack.trash]
  local restored = Popup.new(closed.opts)
  if not restored then
    vim.notify("Overlook: Failed to restore popup", vim.log.levels.ERROR)
    return
  end

  table.remove(self.stack.trash, #self.stack.trash)
  table.insert(self.stack.items, restored)
end

---Restore all previously closed popups in this Window's stack.
function Window:restore_all()
  while #self.stack.trash > 0 do
    local before = #self.stack.trash
    self:restore()
    if #self.stack.trash == before then
      break -- restore failed; stop to avoid infinite loop
    end
  end
end
```

Note: this still pokes into `stack.trash` directly. Task 4 introduces `Stack:peek_trash` / `Stack:pop_trash` / `Stack:restore_item` and refactors this method to use them — at which point the pokes go away.

- [ ] **Step 5: Add `Window:switch_focus`**

Append to `window.lua`:

```lua
---Toggle focus between the top popup and the root window.
function Window:switch_focus()
  local switch_to
  if vim.w.is_overlook_popup then
    switch_to = self.winid
  elseif not self.stack:empty() then
    switch_to = self.stack:top().winid
  end
  if not switch_to then
    vim.notify("Overlook: no popup to focus")
    return
  end
  pcall(api.nvim_set_current_win, switch_to)
end
```

- [ ] **Step 6: Add thin delegates `Window:top / size / empty`**

Append to `window.lua`:

```lua
function Window:top() return self.stack:top() end
function Window:size() return self.stack:size() end
function Window:empty() return self.stack:empty() end
```

- [ ] **Step 7: Add `M.find_by_popup_winid`**

Append to `window.lua` (registry section):

```lua
---Scan all hosts for a popup with this winid. Used by the WinClosed autocmd.
---Iterates every position in every stack (not just tops) because non-top popups
---can close (see spec §5).
---@param winid integer
---@return OverlookWindow?
function M.find_by_popup_winid(winid)
  for _, w in pairs(M.instances) do
    for _, item in ipairs(w.stack.items) do
      if item.winid == winid then
        return w
      end
    end
  end
  return nil
end
```

- [ ] **Step 8: Update `api.lua` to call `Window` for close/restore/switch_focus**

In `lua/overlook/api.lua`:

```lua
-- M.close_all
M.close_all = function()
  Window.current():close_all()
end

-- M.restore_popup
M.restore_popup = function()
  Window.current():restore()
end

-- M.restore_all_popups
M.restore_all_popups = function()
  Window.current():restore_all()
end

-- M.switch_focus
M.switch_focus = function()
  Window.current():switch_focus()
end
```

Remove the old `Stack.clear()` / `Stack.instances` / `Stack.empty()` lookups inside the old `switch_focus`.

- [ ] **Step 9: Update `init.lua` autocmd**

In `lua/overlook/init.lua`, replace the `WinClosed` callback body:

```lua
vim.api.nvim_create_autocmd("WinClosed", {
  group = augroup,
  callback = function(args)
    local winid = tonumber(args.match)
    if not winid then
      return
    end
    local w = require("overlook.window").find_by_popup_winid(winid)
    if w then
      w:on_popup_closed(winid)
    end
  end,
})
```

- [ ] **Step 10: Update `state.lua` to use `Window:top()`**

In `lua/overlook/state.lua`, replace the two `Stack.top()` callsites (in `update_keymap` and `update_title`) with `require("overlook.window").current():top()`. Remove the `local Stack = require("overlook.stack")` import if it becomes unused.

- [ ] **Step 11: Remove the moved methods from `Stack` and `Popup`**

In `lua/overlook/stack.lua`, delete:

- `Stack:clear`
- `Stack:on_close`
- `Stack:restore`
- `Stack:restore_all`
- `Stack:remove_invalid_windows`
- `M.clear` (the module-level delegate)

In `lua/overlook/popup.lua`, delete `M.on_close` and the `nvim_create_autocmd("WinClosed", ...)` block inside `Popup:create_close_autocommand` (note: master's popup.lua doesn't have this autocmd anymore — verify and skip if absent).

- [ ] **Step 12: Run tests; update failures**

Run: `make test`

Expected failures: `stack_spec.lua` tests that stubbed `Stack:clear` or `Stack:on_close` will fail because those methods are gone. Either skip the affected `describe` blocks for now or delete them — Task 5 rewrites `stack_spec` wholesale, so deletion is fine here. The goal of this step is just that the *non*-stack specs (popup_spec, peek_spec, state_spec, window_spec) pass.

If `state_spec.lua` references `Stack.top` directly via the mocked `Stack`, swap it to stub `require("overlook.window").current` returning a fake window with `top = function() return ... end`.

- [ ] **Step 13: Commit**

```bash
git add lua/overlook/window.lua lua/overlook/stack.lua lua/overlook/popup.lua lua/overlook/api.lua lua/overlook/init.lua lua/overlook/state.lua tests/spec/state_spec.lua tests/spec/stack_spec.lua
git commit -m "refactor(window): move close/restore/reconcile from Stack to Window"
```

---

### Task 4: Pure-ify `Stack` (no `vim.api`, no module facade)

**Goal:** `stack.lua` becomes a pure data structure. Add `peek_trash`, `pop_trash`, `restore_item`; make `pop` and `remove_by_winid` move to trash. Rewrite `stack_spec` as pure data tests. Refactor `Window:restore` / `Window:restore_all` to use the new trash API.

**Files:**
- Modify: `lua/overlook/stack.lua`
- Modify: `lua/overlook/window.lua`
- Replace: `tests/spec/stack_spec.lua`

- [ ] **Step 1: Replace `tests/spec/stack_spec.lua` with pure data tests**

Write a clean spec that uses no `vim.api` mocks:

```lua
local Stack = require("overlook.stack")

-- Tiny popup factory (just a plain table with the fields Stack inspects)
local function popup(winid)
  return { winid = winid }
end

describe("Stack — basic LIFO", function()
  it("starts empty", function()
    local s = Stack.new()
    assert.is_true(s:empty())
    assert.are.equal(0, s:size())
    assert.is_nil(s:top())
  end)

  it("push/pop maintains LIFO order", function()
    local s = Stack.new()
    local a, b, c = popup(1), popup(2), popup(3)
    s:push(a); s:push(b); s:push(c)
    assert.are.equal(3, s:size())
    assert.are.equal(c, s:top())
    assert.are.equal(c, s:pop())
    assert.are.equal(b, s:top())
    assert.are.equal(b, s:pop())
    assert.are.equal(a, s:pop())
    assert.is_true(s:empty())
  end)

  it("push clears trash (new popup invalidates redo history)", function()
    local s = Stack.new()
    s:push(popup(1)); s:pop()       -- trash: [{1}]
    assert.are.equal(1, #s.trash)
    s:push(popup(2))                -- new push -> clear trash
    assert.are.equal(0, #s.trash)
  end)
end)

describe("Stack — trash and restore", function()
  it("pop moves the popup to trash", function()
    local s = Stack.new()
    local a = popup(1)
    s:push(a)
    s:pop()
    assert.are.equal(a, s:peek_trash())
  end)

  it("pop_trash removes and returns the last trash item", function()
    local s = Stack.new()
    local a, b = popup(1), popup(2)
    s:push(a); s:pop()
    s:push(b); s:pop()              -- trash: [a, b]
    assert.are.equal(b, s:pop_trash())
    assert.are.equal(a, s:pop_trash())
    assert.is_nil(s:pop_trash())
  end)

  it("restore_item appends to items WITHOUT clearing trash", function()
    local s = Stack.new()
    local a, b = popup(1), popup(2)
    s:push(a); s:pop()
    s:push(b); s:pop()              -- trash: [a, b]
    local restored = s:pop_trash()  -- trash: [a]
    s:restore_item(restored)        -- items: [b]; trash MUST remain [a]
    assert.are.equal(1, #s.trash)
    assert.are.equal(a, s.trash[1])
    assert.are.equal(b, s:top())
  end)
end)

describe("Stack — remove_by_winid", function()
  it("removes a top item and moves it to trash", function()
    local s = Stack.new()
    s:push(popup(1)); s:push(popup(2)); s:push(popup(3))
    local removed = s:remove_by_winid(3)
    assert.are.equal(3, removed.winid)
    assert.are.equal(2, s:size())
    assert.are.equal(2, s:top().winid)
    assert.are.equal(3, s:peek_trash().winid)
  end)

  it("removes a middle item and moves it to trash", function()
    local s = Stack.new()
    s:push(popup(1)); s:push(popup(2)); s:push(popup(3))
    local removed = s:remove_by_winid(2)
    assert.are.equal(2, removed.winid)
    assert.are.equal(2, s:size())
    assert.are.equal(1, s.items[1].winid)
    assert.are.equal(3, s.items[2].winid)
    assert.are.equal(2, s:peek_trash().winid)
  end)

  it("returns nil and does not mutate when winid is absent", function()
    local s = Stack.new()
    s:push(popup(1)); s:push(popup(2))
    assert.is_nil(s:remove_by_winid(999))
    assert.are.equal(2, s:size())
    assert.are.equal(0, #s.trash)
  end)
end)
```

- [ ] **Step 2: Run — confirm failures**

Run: `make test`
Expected: `stack_spec` fails because `Stack.new` still requires a `winid` argument, `peek_trash` / `pop_trash` / `restore_item` don't exist, `remove_by_winid` doesn't return the removed item or trash it.

- [ ] **Step 3: Rewrite `stack.lua` as pure**

Replace `lua/overlook/stack.lua` with:

```lua
---@class OverlookStack
---@field items OverlookPopup[]   -- bottom -> top
---@field trash OverlookPopup[]   -- closed popups available for restore, oldest -> newest
local Stack = {}
Stack.__index = Stack

---@return OverlookStack
function Stack.new()
  return setmetatable({ items = {}, trash = {} }, Stack)
end

---@return integer
function Stack:size() return #self.items end

---@return boolean
function Stack:empty() return #self.items == 0 end

---@return OverlookPopup?
function Stack:top()
  if self:empty() then return nil end
  return self.items[#self.items]
end

---Append a popup; clears trash (a new popup invalidates the redo history).
---@param popup OverlookPopup
function Stack:push(popup)
  table.insert(self.items, popup)
  self.trash = {}
end

---Remove the top popup, append it to trash, return it.
---@return OverlookPopup?
function Stack:pop()
  if self:empty() then return nil end
  local top = table.remove(self.items)
  table.insert(self.trash, top)
  return top
end

---Remove the popup with this winid from any position; trash it; return it.
---@param winid integer
---@return OverlookPopup?
function Stack:remove_by_winid(winid)
  for i = #self.items, 1, -1 do
    if self.items[i].winid == winid then
      local removed = table.remove(self.items, i)
      table.insert(self.trash, removed)
      return removed
    end
  end
  return nil
end

---Last trash item without removing it.
---@return OverlookPopup?
function Stack:peek_trash()
  return self.trash[#self.trash]
end

---Remove + return the last trash item.
---@return OverlookPopup?
function Stack:pop_trash()
  if #self.trash == 0 then return nil end
  return table.remove(self.trash)
end

---Append to items WITHOUT clearing trash. Used by restore to re-insert a
---reopened popup while leaving the rest of the trash buffer intact.
---@param popup OverlookPopup
function Stack:restore_item(popup)
  table.insert(self.items, popup)
end

return Stack
```

Notes: `Stack.new` no longer takes a `winid`, there is no `augroup_id`, no `root_winid`, no module-level `M` facade. The returned table IS the `Stack` class — callers do `local Stack = require("overlook.stack"); local s = Stack.new()`.

- [ ] **Step 4: Update `window.lua` for the new `Stack` constructor and trash API**

In `lua/overlook/window.lua`:

```lua
-- in Window.new
function Window.new(winid)
  return setmetatable({ winid = winid, stack = Stack.new() }, Window)  -- no winid arg
end
```

Rewrite `Window:restore` using the new trash API:

```lua
function Window:restore()
  local Popup = require("overlook.popup")
  local data = self.stack:peek_trash()
  if not data then
    vim.notify("Overlook: No popup to restore", vim.log.levels.WARN)
    return
  end

  local restored = Popup.new(data.opts)
  if not restored then
    vim.notify("Overlook: Failed to restore popup", vim.log.levels.ERROR)
    return
  end

  self.stack:pop_trash()           -- consume only on success
  self.stack:restore_item(restored)
end

function Window:restore_all()
  while self.stack:peek_trash() do
    local before = #self.stack.trash
    self:restore()
    if #self.stack.trash == before then
      break -- restore failed; stop
    end
  end
end
```

- [ ] **Step 5: Run, confirm pass**

Run: `make test`
Expected: all green. `stack_spec` runs without any `vim.api` mocks.

- [ ] **Step 6: Commit**

```bash
git add lua/overlook/stack.lua lua/overlook/window.lua tests/spec/stack_spec.lua
git commit -m "refactor(stack): purify into a data-only module with explicit trash API"
```

---

### Task 5: Refactor `Popup` — take `ctx`, split construction from opening, add lifecycle methods

**Goal:** `Popup.new(opts, ctx)` only constructs and computes config (no `nvim_open_win`). `popup:open()` opens the float with internal rollback. Add `popup:close`, `popup:is_valid`, `popup:focus`. `popup.lua` no longer requires `stack.lua`. Update `Window:open_popup` to call `Popup.new` + `popup:open` + `stack:push`.

**Files:**
- Modify: `lua/overlook/popup.lua`
- Modify: `lua/overlook/window.lua`
- Modify: `tests/spec/popup_spec.lua`

- [ ] **Step 1: Add failing tests for the new Popup lifecycle**

In `tests/spec/popup_spec.lua`, append:

```lua
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
    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    assert.is_not_nil(p)
    assert.is_nil(p.winid)                                -- not opened yet
    assert.stub(api_mock.nvim_open_win).was_not_called()
  end)

  it("popup:open opens the window and registers state", function()
    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    local ok = p:open()
    assert.is_true(ok)
    assert.are.equal(1234, p.winid)
    assert.stub(api_mock.nvim_open_win).was_called(1)
  end)

  it("popup:open returns false when nvim_open_win returns 0", function()
    api_mock.nvim_open_win.returns(0)
    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    local ok = p:open()
    assert.is_false(ok)
    assert.is_nil(p.winid)
  end)

  it("popup:close calls nvim_win_close when valid", function()
    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    p:open()
    p:close()
    assert.stub(api_mock.nvim_win_close).was_called_with(1234, false)
  end)

  it("popup:is_valid returns false before open()", function()
    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    assert.is_false(p:is_valid())
  end)

  it("popup:focus delegates to nvim_set_current_win when valid", function()
    local Popup = require("overlook.popup")
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1 }, { root_winid = 100, prev = nil, depth = 0 })
    p:open()
    p:focus()
    assert.stub(api_mock.nvim_set_current_win).was_called_with(1234)
  end)

  it("stacked popup config uses ctx.prev and ctx.depth (no Stack lookup)", function()
    -- This must not touch Stack at all.
    local Popup = require("overlook.popup")
    local prev = { winid = 555, width = 50, height = 10, root_winid = 100 }
    local p = Popup.new({ target_bufnr = 1, lnum = 1, col = 1, title = "stacked" }, { root_winid = 100, prev = prev, depth = 1 })
    assert.is_not_nil(p)
    assert.are.equal(555, p.win_config.win)
    assert.is_false(p.is_first_popup)
  end)
end)
```

Also, **delete** any existing `popup_spec` blocks that stub `Stack.empty` / `Stack.size` / `Stack.top` — Popup no longer reads from Stack. Old config tests that called `Popup.new(opts)` need updating to `Popup.new(opts, { root_winid = 100, prev = nil, depth = 0 })`.

- [ ] **Step 2: Run, confirm failures**

Run: `make test`
Expected: new popup_spec tests fail (`p.winid` is set immediately, ctx not accepted, methods missing).

- [ ] **Step 3: Rewrite `popup.lua`**

Replace `lua/overlook/popup.lua` with:

```lua
local api = vim.api
local Config = require("overlook.config").get()
local State = require("overlook.state")

---@class OverlookPopupContext
---@field root_winid integer
---@field prev OverlookPopup?   -- previous (top) popup, nil for first
---@field depth integer         -- stack size before this popup is added

---@class OverlookPopup
---@field opts OverlookPopupOptions
---@field winid integer?
---@field win_config vim.api.keyset.win_config
---@field width integer
---@field height integer
---@field is_first_popup boolean
---@field root_winid integer
local Popup = {}
Popup.__index = Popup

local M = {}

---Constructs a Popup and computes its window config. Does NOT open the window.
---@param opts OverlookPopupOptions
---@param ctx OverlookPopupContext?
---@return OverlookPopup?
function M.new(opts, ctx)
  local this = setmetatable({}, Popup)
  ctx = ctx or { root_winid = api.nvim_get_current_win(), prev = nil, depth = 0 }

  if not this:initialize_state(opts) then
    return nil
  end

  if not this:determine_window_configuration(ctx) then
    return nil
  end

  return this
end

function Popup:initialize_state(opts)
  if not opts then
    vim.notify("Overlook: Invalid opts provided to Popup", vim.log.levels.ERROR)
    return false
  end
  if not opts.target_bufnr then
    vim.notify("Overlook: target_bufnr missing in opts for Popup", vim.log.levels.ERROR)
    return false
  end
  self.opts = opts
  if not api.nvim_buf_is_valid(opts.target_bufnr) then
    vim.notify("Overlook: Invalid target buffer for popup", vim.log.levels.ERROR)
    return false
  end
  return true
end

function Popup:config_for_first_popup()
  local current_winid = api.nvim_get_current_win()
  local cursor_buf_pos = api.nvim_win_get_cursor(current_winid)
  local cursor_abs_screen_pos = vim.fn.screenpos(current_winid, cursor_buf_pos[1], cursor_buf_pos[2] + 1)
  local win_pos = api.nvim_win_get_position(current_winid)

  local winbar_enabled = vim.o.winbar ~= ""
  local max_window_height = api.nvim_win_get_height(current_winid) - (winbar_enabled and 1 or 0)
  local max_window_width = api.nvim_win_get_width(current_winid)

  local screen_space_above = cursor_abs_screen_pos.row - win_pos[1] - 1 - (winbar_enabled and 1 or 0)
  local screen_space_below = max_window_height - screen_space_above - 1
  local screen_space_left = cursor_abs_screen_pos.col - win_pos[2] - 1

  local place_above = screen_space_above > max_window_height / 2

  local border_overhead = Config.ui.border ~= "none" and 2 or 0
  local max_fittable = (place_above and screen_space_above or screen_space_below) - border_overhead

  local target_height = math.min(math.floor(max_window_height * Config.ui.size_ratio), max_fittable)
  local target_width = math.floor(max_window_width * Config.ui.size_ratio)
  local height = math.max(Config.ui.min_height, target_height)
  local width = math.max(Config.ui.min_width, target_width)

  local win_config = {
    relative = "win", style = "minimal", focusable = true,
    width = width, height = height,
    win = current_winid,
    zindex = Config.ui.z_index_base,
    col = screen_space_left + Config.ui.col_offset,
  }
  if place_above then
    win_config.row = math.max(0, screen_space_above - height - border_overhead - Config.ui.row_offset)
  else
    win_config.row = screen_space_above + 1 + Config.ui.row_offset
  end
  return win_config, current_winid
end

---@param prev OverlookPopup
---@param depth integer
function Popup:config_for_stacked_popup(prev, depth)
  return {
    relative = "win", style = "minimal", focusable = true,
    win = prev.winid,
    zindex = Config.ui.z_index_base + depth,
    width = math.max(Config.ui.min_width, prev.width - Config.ui.width_decrement),
    height = math.max(Config.ui.min_height, prev.height - Config.ui.height_decrement),
    row = Config.ui.stack_row_offset - (vim.o.winbar ~= "" and 1 or 0),
    col = Config.ui.stack_col_offset,
  }
end

---@param ctx OverlookPopupContext
function Popup:determine_window_configuration(ctx)
  local win_cfg
  if ctx.prev == nil then
    self.is_first_popup = true
    local cfg, current_winid = self:config_for_first_popup()
    win_cfg = cfg
    self.root_winid = current_winid
  else
    self.is_first_popup = false
    win_cfg = self:config_for_stacked_popup(ctx.prev, ctx.depth)
    self.root_winid = ctx.root_winid
  end

  local border
  if Config.ui.border and Config.ui.border ~= "" then
    border = Config.ui.border
  elseif vim.o.winborder and vim.o.winborder ~= "" then
    border = vim.o.winborder
  else
    border = "rounded"
  end
  ---@diagnostic disable-next-line: assign-type-mismatch
  win_cfg.border = border
  win_cfg.title = self.opts.title or "Overlook default title"
  win_cfg.title_pos = "center"

  self.win_config = win_cfg
  return true
end

---Open the float. Internal rollback: if post-open setup throws, close the
---half-created window and return false. Caller (Window) checks the return.
---@return boolean ok
function Popup:open()
  self.winid = api.nvim_open_win(self.opts.target_bufnr, true, self.win_config)
  if self.winid == 0 then
    self.winid = nil
    vim.notify("Overlook: Failed to open popup window.", vim.log.levels.ERROR)
    return false
  end

  local ok, err = pcall(function()
    vim.w.is_overlook_popup = true
    vim.w.overlook_popup = { root_winid = self.root_winid }
    State.register_overlook_popup(self.winid, self.opts.target_bufnr)
    local actual = api.nvim_win_get_config(self.winid)
    self.width = actual.width
    self.height = actual.height
    M.set_cursor_position(self.winid, self.opts.lnum, self.opts.col)
  end)

  if not ok then
    pcall(api.nvim_win_close, self.winid, true)
    self.winid = nil
    vim.notify("Overlook: post-open setup failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

---@param force? boolean
function Popup:close(force)
  if self:is_valid() then
    pcall(api.nvim_win_close, self.winid, force or false)
  end
end

---@return boolean
function Popup:is_valid()
  return self.winid ~= nil and api.nvim_win_is_valid(self.winid)
end

function Popup:focus()
  if self:is_valid() then
    pcall(api.nvim_set_current_win, self.winid)
  end
end

---@param winid integer
---@param lnum integer
---@param col integer
function M.set_cursor_position(winid, lnum, col)
  api.nvim_win_set_cursor(winid, { lnum, math.max(0, col - 1) })
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zz")
  end)
end

return M
```

Key points: `popup.lua` no longer `require`s `overlook.stack`. `Popup.new` returns an object whose `winid` is `nil` until `:open()` succeeds. `:open()` `pcall`-guards the post-open steps and closes the half-created window on failure.

- [ ] **Step 4: Update `Window:open_popup` to use the split API**

In `lua/overlook/window.lua`, replace `Window:open_popup` with:

```lua
function Window:open_popup(opts)
  local Popup = require("overlook.popup")
  local ctx = {
    root_winid = self.winid,
    prev = self.stack:top(),
    depth = self.stack:size(),
  }
  local popup = Popup.new(opts, ctx)
  if not popup then
    return nil
  end
  if not popup:open() then
    return nil
  end
  self.stack:push(popup)
  return popup
end
```

Update `Window:close_all` and `Window:on_popup_closed` and `Window:prune_invalid` to use `popup:close()`, `popup:is_valid()`, `popup:focus()` instead of raw `nvim_win_*` calls:

```lua
function Window:close_all(force)
  vim.opt.eventignore:append("WinClosed")
  while not self.stack:empty() do
    local top = self.stack:top()
    if top then top:close(force) end
    self.stack:pop()
  end
  vim.opt.eventignore:remove("WinClosed")
  pcall(api.nvim_set_current_win, self.winid)
end

function Window:prune_invalid()
  while not self.stack:empty() do
    local top = self.stack:top()
    if top and top:is_valid() then return end
    self.stack:pop()
  end
end

function Window:on_popup_closed(winid)
  self.stack:remove_by_winid(winid)
  self:prune_invalid()

  local top = self.stack:top()
  if top and top:is_valid() then
    top:focus()
  else
    pcall(api.nvim_set_current_win, self.winid)
    local config = require("overlook.config").get()
    if type(config.on_stack_empty) == "function" then
      local ok, err = pcall(config.on_stack_empty)
      if not ok then
        vim.notify("Overlook Error: on_stack_empty callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  vim.schedule(function() require("overlook.state").update_keymap() end)
end
```

Also update `Window:restore` to build `ctx` and call `Popup.new(opts, ctx)` + `:open()`:

```lua
function Window:restore()
  local Popup = require("overlook.popup")
  local data = self.stack:peek_trash()
  if not data then
    vim.notify("Overlook: No popup to restore", vim.log.levels.WARN)
    return
  end

  local ctx = {
    root_winid = self.winid,
    prev = self.stack:top(),
    depth = self.stack:size(),
  }
  local restored = Popup.new(data.opts, ctx)
  if not restored or not restored:open() then
    vim.notify("Overlook: Failed to restore popup", vim.log.levels.ERROR)
    return  -- trash untouched on failure
  end

  self.stack:pop_trash()
  self.stack:restore_item(restored)
end
```

`Window:promote` keeps using `self.stack:clear()` — wait, `Stack:clear` was removed in Task 3. Use `self:close_all()` instead:

```lua
function Window:promote(open_command)
  local Popup = require("overlook.popup")
  if self.stack:empty() or not vim.w.is_overlook_popup then
    vim.notify("Overlook: No popup to promote.", vim.log.levels.INFO)
    return
  end
  local buf_id = api.nvim_get_current_buf()
  ---@diagnostic disable-next-line: unused-local
  local _bufnum, lnum, col, _off = unpack(vim.fn.getpos("."))

  self:close_all()

  if not buf_id or not api.nvim_buf_is_valid(buf_id) then
    vim.notify(
      string.format("Overlook Error: Buffer to promote is invalid (ID: %s).", tostring(buf_id)),
      vim.log.levels.ERROR
    )
    return
  end

  local cmd = string.format("%s %d", open_command, buf_id)
  ---@diagnostic disable-next-line: param-type-mismatch
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify(
      string.format("Overlook Error: Failed to execute command '%s': %s", cmd, tostring(err)),
      vim.log.levels.ERROR
    )
    return
  end
  Popup.set_cursor_position(0, lnum, col)
  vim.bo.buflisted = true
end
```

(If `Window:promote` from Task 2 already called `self.stack:clear()`, replace that call now.)

- [ ] **Step 5: Run, confirm pass**

Run: `make test`
Expected: all green. `popup_spec` covers ctx + lifecycle methods. `popup.lua` no longer requires `stack.lua` (audit: `grep -n 'require.*overlook.stack' lua/overlook/popup.lua` returns no results).

- [ ] **Step 6: Commit**

```bash
git add lua/overlook/popup.lua lua/overlook/window.lua tests/spec/popup_spec.lua
git commit -m "refactor(popup): take ctx, split open() from new(), add lifecycle methods"
```

---

### Task 6: Real-window atomicity test suite

**Goal:** Add the suite that proves the invariant holds across every transaction, including rollback paths and middle-hole reconciliation. Tests use real Neovim floats (no mocking `vim.api`).

**Files:**
- Modify: `tests/spec/window_spec.lua`

- [ ] **Step 1: Add the invariant helper and the open-popup tests**

Append to `tests/spec/window_spec.lua`:

```lua
local api = vim.api

-- Asserts: every item in window.stack.items is a live float, and the count
-- matches stack:size(). This is the atomicity invariant from spec §4.
local function assert_invariant(window)
  local items = window.stack.items
  for i, popup in ipairs(items) do
    assert.is_true(
      popup:is_valid(),
      string.format("stack.items[%d] (winid=%s) is not a live float", i, tostring(popup.winid))
    )
  end
  assert.are.equal(#items, window.stack:size())
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
    local p = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1, title = "t" })
    assert.is_not_nil(p)
    assert.is_true(p:is_valid())
    assert.are.equal(1, w.stack:size())
    assert.are.equal(p, w.stack:top())
    assert_invariant(w)
    w:close_all()
  end)

  it("stacks multiple popups; invariant holds at every step", function()
    local w = Window.current()
    local p1 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1, title = "1" })
    assert_invariant(w)
    local p2 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1, title = "2" })
    assert_invariant(w)
    local p3 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1, title = "3" })
    assert_invariant(w)
    assert.are.equal(3, w.stack:size())
    assert.are.equal(p3, w.stack:top())
    w:close_all()
  end)
end)
```

- [ ] **Step 2: Add the rollback tests**

Append:

```lua
describe("Window:open_popup — rollback", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("when nvim_open_win returns 0, nothing is pushed and no float leaks", function()
    local w = Window.current()
    local original = api.nvim_open_win
    api.nvim_open_win = function() return 0 end

    local p = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })

    api.nvim_open_win = original

    assert.is_nil(p)
    assert.is_true(w.stack:empty())
    assert_invariant(w)
  end)

  it("when post-open setup throws, the float is closed and nothing is pushed", function()
    local w = Window.current()
    -- Force the post-open path to throw by making nvim_win_get_config error.
    local original = api.nvim_win_get_config
    api.nvim_win_get_config = function() error("boom") end

    local p = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })

    api.nvim_win_get_config = original

    assert.is_nil(p)
    assert.is_true(w.stack:empty())
    assert_invariant(w)
    -- Best-effort check that no overlook float lingers: every win except the
    -- root should not advertise overlook_popup. (No reliable per-win read on
    -- closed windows, so we rely on the empty-stack assertion.)
  end)
end)
```

- [ ] **Step 3: Add close_all and on_popup_closed tests**

Append:

```lua
describe("Window:close_all", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("closes all popups, empties the stack, refocuses root, preserves invariant", function()
    local root = api.nvim_get_current_win()
    local w = Window.current()
    w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })

    w:close_all()

    assert.is_true(w.stack:empty())
    assert_invariant(w)
    assert.are.equal(root, api.nvim_get_current_win())
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
    local p1 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    local p2 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })

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
    local p1 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    local p2 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    local p3 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })

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
```

- [ ] **Step 4: Add prune_invalid and find_by_popup_winid tests**

Append:

```lua
describe("Window:prune_invalid", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
  end)

  it("pops invalid tops until a valid top is found", function()
    local w = Window.current()
    local p1 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    local p2 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })

    vim.opt.eventignore:append("WinClosed")
    api.nvim_win_close(p2.winid, true)
    vim.opt.eventignore:remove("WinClosed")

    -- p2's stack entry is now stale; p1 is still valid.
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
    local p1 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    local p2 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    assert.are.equal(w, Window.find_by_popup_winid(p1.winid))
    assert.are.equal(w, Window.find_by_popup_winid(p2.winid))
    assert.is_nil(Window.find_by_popup_winid(99999))
    w:close_all()
  end)
end)
```

- [ ] **Step 5: Add a WinClosed integration test**

Append:

```lua
describe("init.lua WinClosed integration", function()
  local Window = require("overlook.window")

  before_each(function()
    Window.instances = {}
    vim.w = {}
    require("overlook").setup({})  -- ensure the WinClosed autocmd is registered
  end)

  it("closing a popup window triggers stack reconciliation via the autocmd", function()
    local w = Window.current()
    local p1 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })
    local p2 = w:open_popup({ target_bufnr = make_buf(), lnum = 1, col = 1 })

    -- Real close — WinClosed should fire and Window:on_popup_closed should reconcile.
    api.nvim_win_close(p2.winid, true)

    -- WinClosed handler runs synchronously inside nvim_win_close; nothing to wait on.
    assert.are.equal(1, w.stack:size())
    assert.are.equal(p1, w.stack:top())
    assert_invariant(w)
    w:close_all()
  end)
end)
```

- [ ] **Step 6: Run, confirm all pass**

Run: `make test`
Expected: all green. If any rollback test still leaves a stale stack entry, the rollback is incomplete — fix the bug in `popup:open()` or `Window:open_popup`.

- [ ] **Step 7: Commit**

```bash
git add tests/spec/window_spec.lua
git commit -m "test(window): real-window atomicity suite with invariant helper"
```

---

### Task 7: Final cleanup, audit, format

**Goal:** Catch any stragglers, verify the structural goals hold, format with stylua.

**Files:** various (as needed)

- [ ] **Step 1: Audit — no `require("overlook.ui")` anywhere**

Run: `grep -rn 'require("overlook.ui")' lua tests`
Expected: no matches.

- [ ] **Step 2: Audit — `stack.lua` has zero `vim.api` references**

Run: `grep -n 'vim\.api\|vim\.opt\|nvim_' lua/overlook/stack.lua`
Expected: no matches. The whole file is pure Lua.

- [ ] **Step 3: Audit — `popup.lua` does not require `stack.lua`**

Run: `grep -n 'overlook.stack' lua/overlook/popup.lua`
Expected: no matches.

- [ ] **Step 4: Audit — `find_by_popup_winid` scans all positions**

Open `lua/overlook/window.lua`, locate `find_by_popup_winid`, confirm the inner loop is `for _, item in ipairs(w.stack.items) do` (not just `w.stack:top()`).

- [ ] **Step 5: Format and lint**

Run: `stylua --check lua tests || stylua lua tests`
Expected: no errors, or stylua applies fixes. If it reformats files, review the diff briefly.

Run: `selene lua` (if selene is installed locally) — expected clean.

- [ ] **Step 6: Run the full suite one more time**

Run: `make test`
Expected: all green.

- [ ] **Step 7: Commit any formatting / final tweaks**

```bash
git status
# If anything was modified by stylua:
git add -u
git commit -m "chore: format and final cleanup"
```

- [ ] **Step 8: Sanity-check the commit history**

Run: `git log --oneline master..HEAD`
Expected: a clean sequence of commits — `docs:` spec, then `feat(window)`, `refactor(window)`, `refactor(stack)`, `refactor(popup)`, `test(window)`, optional `chore:` final.

---

## Self-Review Notes

Spec coverage check:

- §3.1 pure Stack — Task 4 ✓
- §3.2 Popup ctx + lifecycle + rollback — Task 5 ✓
- §3.3 Window class + registry + transactions — Tasks 1–3 (then refined in 5) ✓
- §4 atomicity invariant + rollback table — Tasks 5 (rollback in `popup:open`), 3+5 (transactions) ✓
- §5 reconciliation, no cascade, middle hole, always-refocus — Task 3 (initial) + Task 5 (refined w/ `popup:is_valid`) + Task 6 (middle-hole test) ✓
- §6 module adaptations (peek, api, init, state, types, ui deleted) — Tasks 2 + 3 ✓
- §7 testing strategy (pure stack, popup lifecycle, window real-window suite, init integration) — Tasks 4, 5, 6 ✓
- §8 non-goals — respected (no registry GC introduced, no float repositioning)
- §9 open decisions — `api.close_all` keeps current-window behavior (Task 3 Step 8); `remove_by_winid` trashes on removal (Task 4 Step 3)
