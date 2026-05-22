# Window Module: Decoupling Window Operations from the Stack

- **Date:** 2026-05-22
- **Status:** Approved design — ready for implementation planning
- **Base:** a fresh branch off `master` (`feature/window-module-v2`). The original
  `feature/window-module` branch is ~50 commits stale and is kept only for reference.

## 1. Problem

In overlook.nvim today, *object operations* (stack push/pop) and *window
operations* (the Neovim window API: open/close/focus/validity) are tangled
together, mostly inside `stack.lua`:

- `Stack:clear()` calls `vim.opt.eventignore`, `nvim_win_close`,
  `nvim_win_is_valid`, `nvim_set_current_win`, `nvim_clear_autocmds`.
- `Stack:on_close()` does focus management and validity checks.
- `Stack:remove_invalid_windows()` calls `nvim_win_is_valid`.
- `Stack:restore()` actually *creates* a window via `Popup.new()`.
- `Stack.new()` creates an augroup that is already dead code
  (`TODO: this group is no longer needed`).
- The module-level `Stack.instances` registry keyed by `root_winid` is really
  a *window* registry.

Consequences:

- `stack.lua` cannot be unit-tested without mocking `vim.api`.
- No single object owns the "host window → its popups" relationship.
- Window-lifecycle and stack-mutation logic is scattered across `stack.lua`,
  `popup.lua`, `ui.lua`, and `init.lua`, with no single place that guarantees
  the two stay consistent.

## 2. Goal

Establish a three-level ownership hierarchy — **Window → Stack → Popups**:

- A **Window** is a host (root) window. It owns exactly one **Stack** and is the
  top-level entry point for every overlook operation.
- A **Stack** is a pure LIFO of **Popups** plus a trash buffer for undo. It makes
  zero `vim.api` calls.
- A **Popup** is a single floating window and owns its own Neovim window
  lifecycle.

Every window operation lives in `popup.lua` (one window) or `window.lua`
(coordinating many). `stack.lua` becomes pure and testable with no mocks.

Each top-level operation is designed to be **atomic**: it either completes fully
or leaves no partial state.

## 3. Architecture

Three modules, replacing the current `stack.lua` / `popup.lua` / `ui.lua` split.
`ui.lua` is **deleted**; its `create_popup` and `promote_popup_to_window` move
onto the `Window` object.

```
api.lua / peek.lua / init.lua / state.lua
                 |
                 v
        window.lua  (Window object + registry)   <-- top-level entry point
                 |  owns one
                 v
         stack.lua  (pure data structure)
                 |  holds many
                 v
         popup.lua  (one float, owns its window)
```

`peek.lua` and `popup.lua` no longer `require("overlook.stack")`.

### 3.1 `stack.lua` — pure data structure

`stack.lua` exports only the `Stack` class. No module-level facade, no registry,
no `vim.api`, no `root_winid`, no augroup.

```lua
---@class OverlookStack
---@field items OverlookPopup[]   -- bottom -> top
---@field trash OverlookPopup[]   -- closed popups available for restore, oldest -> newest

Stack.new() -> OverlookStack
Stack:size() -> integer
Stack:empty() -> boolean
Stack:top() -> OverlookPopup?
Stack:push(popup)                  -- append to items; CLEARS trash
Stack:pop() -> OverlookPopup?      -- remove top, append it to trash, return it
Stack:remove_by_winid(winid) -> OverlookPopup?
                                   -- remove the item with this winid from ANY
                                   -- position, append it to trash, return it
Stack:peek_trash() -> OverlookPopup?  -- last trash item, without removing
Stack:pop_trash() -> OverlookPopup?   -- remove and return last trash item
Stack:restore_item(popup)          -- append to items WITHOUT clearing trash
```

Rationale for the two insert paths:

- `push` clears trash — a freshly created popup invalidates the redo history,
  exactly like typing after an undo in an editor.
- `restore_item` does **not** clear trash — restoring must be able to walk back
  through the whole trash buffer (`restore_all`).

Both `pop` and `remove_by_winid` move the removed popup into trash, so a popup
closed by the user is restorable regardless of its stack position (see §9.2).

**Removed from the current `stack.lua`:** the `Stack` methods `clear`,
`on_close`, `restore`, `restore_all`, `remove_invalid_windows`; the `augroup_id`
and `root_winid` fields; and the entire module-level `M` facade — the
`instances` registry, `get_current_root_winid`, `win_get_stack`,
`get_current_stack`, and the `M.push` / `M.top` / `M.size` / `M.empty` /
`M.clear` delegates. `Stack.new()` survives as the plain class constructor: it
no longer takes a `root_winid` argument and no longer creates an augroup.

### 3.2 `popup.lua` — a single popup window

A `Popup` represents exactly one float and owns that window's lifecycle.
Construction is split from opening so a failed open leaves nothing behind.

```lua
---@class OverlookPopupContext
---@field root_winid integer
---@field prev OverlookPopup?   -- previous (current top) popup; nil for the first popup
---@field depth integer         -- stack size before this popup is added

---@class OverlookPopup
---@field opts OverlookPopupOptions
---@field winid integer?        -- popup window id; nil until open() succeeds
---@field win_config table      -- computed nvim_open_win config
---@field width integer
---@field height integer
---@field is_first_popup boolean
---@field root_winid integer

Popup.new(opts, ctx) -> OverlookPopup?   -- validate opts + compute config. Opens NO window.
Popup:open() -> boolean                  -- nvim_open_win + register + cursor; see rollback below
Popup:close(force?)                      -- nvim_win_close, guarded by is_valid()
Popup:is_valid() -> boolean              -- winid ~= nil and nvim_win_is_valid(winid)
Popup:focus()                            -- nvim_set_current_win, guarded by is_valid()
Popup.set_cursor_position(winid, lnum, col)  -- unchanged; still used by promote
```

- `Popup.new(opts, ctx)` runs `initialize_state` (validate `opts` /
  `target_bufnr`) and `determine_window_configuration(ctx)`. The first-vs-stacked
  decision is based on `ctx.prev` being nil, not on a global `Stack` lookup.
  `config_for_stacked_popup(prev, depth)` takes `prev` and `depth` as parameters
  (`zindex = z_index_base + depth`). **`popup.lua` no longer requires
  `stack.lua`.**
- `Popup:open()` calls `nvim_open_win`. If it returns 0, notify and return
  `false`. The post-open steps (set `vim.w` popup vars, `State.register_overlook_popup`,
  read back `width`/`height`, set cursor) run inside `pcall`; on failure it
  closes the half-created float, clears `self.winid`, notifies, and returns
  `false`. This is the window-level rollback point (§4).

### 3.3 `window.lua` — `Window` object + registry

```lua
---@class OverlookWindow
---@field winid integer         -- root (host) window id
---@field stack OverlookStack

-- Registry / facade (module level)
M.instances : table<integer, OverlookWindow>   -- keyed by root winid
M.get(winid) -> OverlookWindow                 -- get-or-create
M.current() -> OverlookWindow                  -- resolve current context
M.find_by_popup_winid(winid) -> OverlookWindow? -- scan all stacks, ANY position

-- Window class
Window.new(winid) -> OverlookWindow            -- { winid = winid, stack = Stack.new() }
Window:open_popup(opts) -> OverlookPopup?
Window:close_all(force?)
Window:on_popup_closed(winid)
Window:restore()
Window:restore_all()
Window:promote(open_command)
Window:focus()
Window:switch_focus()
Window:prune_invalid()
Window:top() / Window:size() / Window:empty()  -- thin delegates to self.stack
```

- `M.current()` — if `vim.w.is_overlook_popup` is set, resolve to
  `M.get(vim.w.overlook_popup.root_winid)`; otherwise `M.get(nvim_get_current_win())`.
  (This is the old `Stack.get_current_root_winid` logic, relocated.)
- `M.find_by_popup_winid(winid)` — iterate `M.instances`; for each Window iterate
  `stack.items`; return the Window holding a popup with that winid, else nil.
  Scans all positions because non-top popups can close (see §5).
- `state.lua` reaches the current top popup through `Window:top()`, never through
  `.stack` directly.

#### Transaction methods

`Window:open_popup(opts)` — the create transaction:

```
ctx   = { root_winid = self.winid, prev = self.stack:top(), depth = self.stack:size() }
popup = Popup.new(opts, ctx)        -- nil -> return nil (nothing changed)
ok    = popup:open()                -- false -> return nil (nothing opened, nothing pushed)
self.stack:push(popup)              -- reached only with a confirmed-live float
return popup
```

`Window:on_popup_closed(winid)` — `WinClosed` reconciliation (the float is
already gone by the time this runs):

```
self.stack:remove_by_winid(winid)   -- removes from any position; no-op if absent
self:prune_invalid()                -- mop up any now-invalid top popups
-- always refocus: the closed window was (typically) the focused one
local top = self.stack:top()
if top then top:focus()
else
  pcall(nvim_set_current_win, self.winid)   -- focus the root window
  -- fire Config.get().on_stack_empty hook (pcall-guarded)
end
vim.schedule(require("overlook.state").update_keymap)
```

`Window:close_all(force)` — the bulk-close transaction (old `Stack:clear`):

```
vim.opt.eventignore:append("WinClosed")    -- suppress per-window reconciliation
while not self.stack:empty() do
  self.stack:top():close(force)
  self.stack:pop()
end
vim.opt.eventignore:remove("WinClosed")
pcall(nvim_set_current_win, self.winid)
```

The dead per-stack augroup is gone, so there is no `nvim_clear_autocmds` call.

`Window:prune_invalid()`:

```
while not self.stack:empty() and not self.stack:top():is_valid() do
  self.stack:pop()
end
```

`Window:restore()` — atomic restore (the trash item is consumed only after the
float is confirmed reopened):

```
data = self.stack:peek_trash()      -- nil -> notify "nothing to restore", return
ctx   = { root_winid = self.winid, prev = self.stack:top(), depth = self.stack:size() }
popup = Popup.new(data.opts, ctx)
if not popup or not popup:open() then
  notify "failed to restore"        -- trash untouched
  return
end
self.stack:pop_trash()              -- consume only on success
self.stack:restore_item(popup)
```

`Window:restore_all()` — `while self.stack:peek_trash() do` call `restore()`;
stop on the first failure.

`Window:promote(open_command)` — same semantics as the current
`ui.promote_popup_to_window`, relocated: guard (stack non-empty and currently in
a popup), capture buffer + cursor, `self:close_all()`, run the split/tab/buffer
command via `pcall(vim.cmd, ...)`, restore the cursor, set `buflisted`.

`Window:switch_focus()` — if in a popup, focus the root; else if the stack is
non-empty, focus the top popup; else notify.

## 4. The Atomicity Model

**The invariant** (holds for every `Window` between transactions):

> `stack.items` is exactly the set of currently-open popup floats for that root
> window, ordered bottom → top. No orphan floats (a float with no stack item),
> no orphan items (a stack item with no live float).

Every transaction is written to preserve it. Rollback points:

| Transaction         | Failure handling                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------- |
| `popup:open()`      | `nvim_open_win` returns 0 → return `false`. Post-open steps `pcall`-guarded → on error, close the half-created float, clear `winid`, return `false`. |
| `Window:open_popup` | `stack:push` is reached only after `popup:open()` confirmed a live float. Any earlier failure → nothing opened, nothing pushed. |
| `Window:close_all`  | `eventignore` blocks re-entrant `WinClosed`; close + pop run in lockstep per iteration.                       |
| `on_popup_closed`   | The float is already gone; `remove_by_winid` + `prune_invalid` re-sync the ledger.                            |
| `Window:restore`    | The trash item is consumed (`pop_trash`) only after `popup:open()` succeeds; a failed reopen leaves trash intact. |

**The asymmetry that makes this safe:** the stack gains a popup *only after* its
float is confirmed open, and only ever *catches up* to a float that has already
closed. Window creation leads the ledger; on destruction, the ledger trails.

**Two close paths, one rule:** user-initiated closes (`q` keymap, `:close`,
`:q`) flow through `WinClosed` → `on_popup_closed`. Plugin-initiated bulk closes
(`close_all`, `promote`) suppress `WinClosed` and reconcile inline. The stack is
never mutated for a window event in two places at once.

## 5. Reconciliation: closing popups and stack holes

A popup that is **not** the top of the stack can be closed at any time (e.g. the
user runs `:close` while focused in a non-top popup, or another plugin closes
it).

Empirically verified (Neovim v0.12.2): closing a parent float does **not**
cascade-close child floats. Opening floats `a` (relative to root), `b`
(relative to `a`), `c` (relative to `b`), then closing the middle one:

```
before    : a=true b=true c=true
closed  b : a=true b=false c=true     -- c survives; b is a hole
```

So invalid popups are **not** always a contiguous top-suffix — real holes occur.

**Handling (decision: scan + eager prune):**

- `WinClosed(winid)` → `M.find_by_popup_winid(winid)` scans all stacks for the
  winid (any position). Cost is O(total popups across all stacks) — realistically
  a handful, worst case a few dozen — on a cold path (window close happens at
  human speed). No reverse index is introduced; that would add a second
  structure to keep in sync and optimize a non-problem.
- `Window:on_popup_closed` calls `stack:remove_by_winid(winid)`, which removes
  the popup from any position (including a middle hole), then `prune_invalid()`.
- **Refocus always happens** on a close: the closed window was typically the
  focused one, so focus moves to the new top popup, or to the root window if the
  stack is now empty.

A surviving float above a closed hole (e.g. `c` above closed `b`) is left open
and usable; it is merely visually anchored to a dead window. Repositioning it is
out of scope (§8).

## 6. Module Adaptations

| Module        | Change                                                                                                                            |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `peek.lua`    | `require("overlook.ui").create_popup(opts)` → `require("overlook.window").current():open_popup(opts)`, in both the sync and async adapter paths. |
| `api.lua`     | `switch_focus`, `restore_popup`, `restore_all_popups`, `close_all`, `open_in_split/vsplit/tab`, `open_in_original_window` delegate to `Window.current():...`. The `peek_*` functions are unchanged. |
| `init.lua`    | The `WinClosed` autocmd replaces its `Stack.instances` loop with `local w = require("overlook.window").find_by_popup_winid(winid); if w then w:on_popup_closed(winid) end`. |
| `state.lua`   | `Stack.top()` (in `update_keymap` and `update_title`) → `require("overlook.window").current():top()`.                              |
| `types.lua`   | Unchanged. The `OverlookWindow` annotation lives in `window.lua` next to the class (consistent with `OverlookStack` / `OverlookPopup`). |
| `ui.lua`      | **Deleted.**                                                                                                                       |

## 7. Testing Strategy

The repo uses plenary + busted. Existing suites mock `vim.api` heavily; for the
atomicity work that is not convincing, and plenary already runs inside a real
Neovim — so the transaction tests use **real floats**.

1. **`stack_spec.lua`** — rewritten as **pure** data-structure tests, with no
   `vim.api` mocking at all. Covers `push` (and its trash-clearing), `pop`,
   `top`, `size`, `empty`, `remove_by_winid` (top / middle / absent),
   `peek_trash`, `pop_trash`, `restore_item` (and its trash-preserving).
2. **`popup_spec.lua`** — keep the existing config-calculation tests (adapted to
   `Popup.new(opts, ctx)`); add `popup:open` / `close` / `is_valid` / `focus`.
3. **`window_spec.lua`** *(new)* — the atomicity suite, using real windows:
   - `assert_invariant(window)` helper — every `stack.items` entry satisfies
     `popup:is_valid()`, and the count of live floats equals `stack:size()`.
   - `open_popup` happy path; **rollback** when `nvim_open_win` fails and when a
     post-open step throws (stub only that one failure point) — assert no leaked
     float and an unchanged stack.
   - `close_all` — all floats closed, stack empty, focus on the root window.
   - `on_popup_closed` — a top close and a real **middle-hole** close: the
     correct item is removed, the others remain, refocus happened.
   - `prune_invalid` and `restore` — assert the invariant holds afterward.
4. **`init` integration test** — open a real popup, `nvim_win_close` it, assert
   the `WinClosed` → `find_by_popup_winid` → `on_popup_closed` path reconciled
   the stack.
5. **`peek_spec.lua` / `state_spec.lua`** — updated for the new wiring (`peek`
   and `state` now route through `Window`).

`make test` must pass.

## 8. Non-Goals

- **Registry garbage collection.** When a root window closes, its `Window`
  instance and stack remain in `M.instances`. Explicitly out of scope (decided
  during design); a stale entry is harmless because every popup operation guards
  with `is_valid()`.
- **Repositioning orphaned floats.** A float left above a closed hole stays
  anchored to a dead window. Fixing its position is a Neovim limitation and out
  of scope.
- **No behavior changes.** This is a structural refactor; user-visible behavior
  of `peek_*`, `close_all`, `restore*`, `open_in_*`, and `switch_focus` is
  unchanged.

## 9. Open Decisions (confirm during spec review)

1. **`api.close_all` scope.** Its current docstring says "Closes every overlook
   popup in all window stacks," but the code only clears the *current* window's
   stack. This design keeps the **current-window** behavior (matching the code)
   and corrects the docstring. Alternative: make `close_all` iterate
   `M.instances` and genuinely close every stack.
2. **`remove_by_winid` trashing.** This design has `remove_by_winid` move the
   removed popup into trash, so a popup closed from a middle position is still
   restorable. Alternative: only top-closed popups (via `pop`) are restorable.
