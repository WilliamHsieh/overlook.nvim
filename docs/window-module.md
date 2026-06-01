# `feature/window-module-v2` — refactor + restore-all fix

This branch separates the per-host window operations from the per-popup data
that the old monolithic `overlook.stack` module mixed together, and fixes a
long-standing bug where `restore_all_popups` placed popups far from their
original positions.

## What changed

### Refactor: `Stack` → `Window` / `Stack` / `Popup`

Three modules with separated responsibilities, replacing the old `Stack` + `ui`
mix:

- **`overlook.window`** — per-host registry. Owns `close_all`, `restore_all`,
  `open_popup`, `promote`, `on_popup_closed` (WinClosed reconciliation),
  `switch_focus`, `prune_invalid`, `find_by_popup_winid`. Resolved via
  `Window.current()` from `vim.w.is_overlook_popup` (if inside a popup) or the
  current window. `M.instances` is keyed by root winid.
- **`overlook.stack`** — pure data: `items[]` + `trash[]`, with `push` (clears
  trash; redo semantics), `pop` (trashes), `peek_trash`, `pop_trash`,
  `restore_item`, `remove_by_winid`. No `vim.api`, no autocmd wiring.
- **`overlook.popup`** — per-popup object. `Popup.new(opts, ctx)` computes
  `win_config` without opening; `Popup:open(enter?)` does the actual
  `nvim_open_win` + post-open setup with rollback-on-error. `set_cursor_position`
  is a module helper.

### `restore_all` placement bug (the long arc)

**Symptom (in user's real config):** with focus.nvim and smear-cursor.nvim
loaded and 5 popups stacked across a vsplit, restored popups landed at the
far-right of the host instead of where they were before close. Master had the
same bug. The fix had two distinct root causes.

**Root cause 1 — recomputation drift.** The old `restore` path called
`Popup.new(opts)` which always ran `Popup:config_for_first_popup`, deriving the
first popup's position from the current host cursor via `screenpos`. If the
cursor drifted between close and restore (focus.nvim resize, etc.), the entire
stacked chain slid sideways. **Fix:** the trashed `Popup` object already holds
its computed `win_config`. `restore_one` now passes
`ctx.win_config = data.win_config` into `Popup.new`, which deep-copies it,
re-points only `cfg.win` to the current anchor (host for the first popup, the
freshly-restored prev for stacked ones), and skips
`determine_window_configuration` entirely.

**Root cause 2 — anchor-cascade not resolving in one tick.** With reuse fixed,
popups 1-2 landed correctly but popups 3+ collapsed to ~[0,0]. Neovim's
`relative="win"` layout pass doesn't fully propagate through deeper anchor
chains within a single event-loop tick: when `restore_all` opened all popups
in a tight Lua loop, popup 3 anchored to popup 2 read popup 2 at its
*provisional* position (before the cascade settled) and landed at a fallback
origin. Interactive peek doesn't hit this because each peek runs in its own
tick, so the layout always settles between opens. **Fix:** `restore_all` now
opens each popup with `enter=true` (the path that triggers Neovim's float-layout
pass at all) and calls `vim.cmd.redraw()` after each `restore_one` so the
just-opened float's screen position settles before the next iteration anchors
to it. The loop is wrapped in `eventignore` for Win/Buf Enter/Leave + WinClosed
so focus-reactive plugins (focus.nvim) don't observe the transient focus walk
across the restored popups, and in `pcall` so the option is always restored.

### Defensive hardening

- `popup.lua`: the reuse branch validates both `ctx.root_winid` and
  `ctx.prev.winid` are valid windows before re-pointing the anchor.
- `window.lua`: `restore_all`'s loop runs inside `pcall`; `eventignore` is
  removed unconditionally on the finalizer path so a Lua error inside the loop
  cannot leave Win/Buf Enter/Leave globally suppressed for the rest of the
  session.

### Tests

- New `tests/spec/window_spec.lua` (~500 lines): registry, `open_popup`
  (happy path + rollback), `close_all`, `on_popup_closed` (top + middle hole),
  `prune_invalid`, `find_by_popup_winid`, WinClosed autocmd integration,
  multi-split restore, single-restore vs `restore_all`, "WinEnter at most once"
  during restore, and the cursor-drift regression (compares stored
  `win_config.col/row` rather than rendered positions to be headless-stable).
- `tests/spec/stack_spec.lua` is now pure data tests (~225 lines), down from
  ~480 in the old mixed module.
- `tests/spec/popup_spec.lua` updated for the `Popup.new(opts, ctx)` signature.
- 77/77 tests pass.

## Architectural decisions worth flagging

1. **`win_config` reuse over recomputation on restore.** Restore reproduces the
   original placement verbatim. Trade-off: if user reloaded `Config` between
   close and restore, the restored popup keeps the old border/title/zindex
   style. Considered acceptable since restore is a fast-iteration tool.
2. **`enter=true` over `enter=false` for restore.** Earlier attempts to use
   `enter=false` (to literally not change focus) hit a Neovim-internal layout
   issue: floats opened without focus stay anchored to the host's position at
   the instant of `nvim_open_win` and never re-anchor. `enter=true` triggers
   the layout pass we need; `eventignore` keeps focus-reactive plugins blind.
3. **`vim.cmd.redraw()` between iterations.** Required for the layout cascade
   to propagate through deeper anchor chains. Interactive peek happens to be
   spared because of event-loop ticks between manual invocations.

## Outstanding TODOs (from extra-high-effort code review)

Listed by severity. Status: **open** until a decision is made.

### Correctness — high severity

- [ ] **#1 `eventignore`-stomp** (`lua/overlook/window.lua` :127 + :240) —
  `vim.opt.eventignore:remove(list)` unconditionally strips named events,
  clobbering pre-existing entries set by the user or another plugin. Verified
  repro. **Best fix:** `cfg.noautocmd = true` in `popup.lua`'s reuse branch
  + drop the `eventignore` dance from `restore_all`. Optional `_restoring`
  re-entry guard on Window for the WinClosed-during-redraw defense. Apply same
  pattern to `close_all` in a follow-up.
- [ ] **#2 `on_popup_closed` steals focus on external middle-close**
  (`lua/overlook/window.lua` :152) — handler unconditionally focuses the new
  top popup, even when the closed popup wasn't the focused window. Fix: guard
  with `nvim_get_current_win() == winid or not nvim_win_is_valid(<current>)`.

### Correctness — edge case

- [ ] **#3 `is_first_popup` misclassification on mutated stack**
  (`lua/overlook/popup.lua` :46) — if the user closes a popup externally
  (so on_popup_closed trashes it) and then calls `close_all` + `restore_all`,
  a previously-stacked popup can become bottom of the restored chain. Its
  stored `win_config` carries stack-offsets, not cursor-anchored offsets, so
  the reuse branch places it at the host's top-left instead of near the cursor.
  Options: (a) detect the case (e.g. `is_stack_offset_only(cfg)`) and recompute
  via `config_for_first_popup`, or (b) accept the misplacement.

### Performance / cleanup — minor

- [ ] **#4 `M.instances` accumulates unbounded** (`lua/overlook/window.lua` :282)
  — entries are created per host winid and never reaped when the host dies.
  `find_by_popup_winid` linearly scans every entry on every WinClosed. Lazy
  prune inside `find_by_popup_winid` (delete entries where the winid is invalid
  and the stack is empty) is the cheap fix.

### UX

- [ ] **#5 Title drift on restore** (`lua/overlook/popup.lua` :50) —
  `state.update_title` rewrites the title on `nvim_win_set_config` but never
  writes it back to `popup.win_config`. Restore reuses the original title.
  Options: (a) write back on `update_title`, (b) recompute title from current
  buffer in the reuse branch before opening, (c) drop title from the reused
  cfg and let `state.update_title` set it on the next BufEnter (only works if
  the loop's autocmd suppression doesn't block BufEnter — see Part 2 of the
  review discussion for the suppression-mechanism trade-offs).

### Observability — low

- [ ] **#6 WinClosed autocmd dropped its "invalid winid" notify**
  (`lua/overlook/init.lua` :12) — silent `return` on
  `tonumber(args.match) == nil`. Restore the `vim.notify(..., ERROR)` so a
  malformed event is observable.

### Cleanup — low

- [ ] **#7 `close_all(force)` is dead public API** (`lua/overlook/window.lua` :115)
  — no caller passes `force`. Either wire it through `api.close_all(force)` or
  drop the parameter.

### Test coverage gap — low

- [ ] **#8 Border-fallback chain not tested** (`lua/overlook/popup.lua` :154) —
  three-tier fallback (`Config.ui.border` → `vim.o.winborder` → `"rounded"`)
  lost its dedicated tests in the popup_spec refactor.

### Doc drift — low

- [ ] **#9 `Popup:open` docstring claims `restore_all` uses `enter=false`**
  (`lua/overlook/popup.lua` :167) — code now uses `enter=true` + eventignore.
- [ ] **#10 `window_spec.lua` "fires WinEnter at most once" test comment**
  (`tests/spec/window_spec.lua` :502) — same drift; comment says enter=false.
- [ ] **#11 Vimdoc references the old Stack module surface**
  (`doc/overlook-config.txt` :151 and likely others) — needs regeneration or
  hand-edit for the post-refactor module split.
