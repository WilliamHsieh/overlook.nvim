# overlook.nvim

Explore without losing context. Stackable, editable floating popups for Neovim.

## Demo

https://github.com/user-attachments/assets/ac784f7e-e4ad-45be-b2f5-60e8318c8089

## The Problem

You know the frustration: you're deep in a function, need to check a definition, so you jump to it... and now you've lost your place.
Or you use a peek feature but can't fix that typo you just spotted.

## The Solution

`overlook.nvim` creates **stackable floating popups** that are **actual buffers** - edit them, save them, navigate from them. Build a visual trail of your code exploration without ever losing where you started.

## Key Features

- 🔍 **Peek at definitions** - View LSP definitions, marks, or any location in floating windows
- ✏️ **Actually editable** - Spot a bug? Fix it right there in the popup and `:w` to save
- 📚 **Visual stack navigation** - See your entire exploration path as cascading popups
- 🔄 **Undo your exploration** - Accidentally closed a popup? Bring it back with `restore_popup()`
- 🪟 **Popup promotion** - Found something important? Convert any popup to a split/tab
- 🎯 **Window-local stacks** - Each window maintains its own popup stack for parallel exploration

## Why overlook.nvim?

The core philosophy is simple: **popups are buffers**. Edit them, save them, navigate them - they behave exactly like any other window.

### Real-world use cases:

1. **Trace through call chains**: Peek definition → find another reference → peek again → you now have a visual stack showing your exploration path
2. **Fix as you explore**: Reviewing a function and spot a typo? Fix it in the popup and save - no context switching needed
3. **Visual debugging**: Build a breadcrumb trail of function calls while debugging

### What makes it different:

- All your keybindings work normally in popups
- Switch buffers inside popups - `:bnext`, `<C-^>`, telescope/fzf all work
- Popups automatically offset and resize to stay readable when stacked
- Full undo/redo support for your exploration history

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "WilliamHsieh/overlook.nvim",
  opts = {},

  -- Optional: set up common keybindings
  keys = {
    { "<leader>pd", function() require("overlook.api").peek_definition() end, desc = "Overlook: Peek definition" },
    { "<leader>pc", function() require("overlook.api").close_all() end, desc = "Overlook: Close all popup" },
    { "<leader>pu", function() require("overlook.api").restore_popup() end, desc = "Overlook: Restore popup" },
  },
}
```

## Quick Start

1. Install the plugin with your favorite package manager
2. Add a keybinding for `peek_definition()`
3. Navigate to any symbol and trigger the peek
4. Edit the popup content if needed
5. Press `q` to close or continue exploring

That's it! No complex setup required.

## Configuration

`overlook.nvim` works out of the box, but you can customize everything, these are default options:

```lua
require("overlook").setup({
  -- UI settings for popup windows
  ui = {
    border = "rounded",              -- Border style: "none", "single", "double", "rounded", etc.
    z_index_base = 30,              -- Base z-index for first popup
    row_offset = 2,                 -- Initial row offset from cursor
    col_offset = 5,                 -- Initial column offset from cursor
    stack_row_offset = 1,           -- Vertical offset for stacked popups
    stack_col_offset = 2,           -- Horizontal offset for stacked popups
    width_decrement = 2,            -- Width reduction for each stacked popup
    height_decrement = 1,           -- Height reduction for each stacked popup
    min_width = 10,                 -- Minimum popup width
    min_height = 3,                 -- Minimum popup height
    size_ratio = 0.65,              -- Default size ratio (0.0 to 1.0)
    title_pos = "center",           -- Popup title position: "left", "center", or "right"
    keys = {
      close = "q",                  -- Key to close the topmost popup
    },
  },

  -- Optional callback when all popups are closed
  on_stack_empty = function()
    -- Your custom logic here
  end,
})
```

## Usage

### Essential keybindings

```lua
vim.keymap.set("n", "<leader>pd", require("overlook.api").peek_definition, { desc = "Peek definition" })
vim.keymap.set("n", "<leader>pp", require("overlook.api").peek_cursor, { desc = "Peek cursor" })
vim.keymap.set("n", "<leader>pu", require("overlook.api").restore_popup, { desc = "Restore last popup" })
vim.keymap.set("n", "<leader>pU", require("overlook.api").restore_all_popups, { desc = "Restore all popups" })
vim.keymap.set("n", "<leader>pc", require("overlook.api").close_all, { desc = "Close all popups" })
vim.keymap.set("n", "<leader>pf", require("overlook.api").switch_focus, { desc = "Switch focus" })
vim.keymap.set("n", "<leader>ps", require("overlook.api").open_in_split, { desc = "Open popup in split" })
vim.keymap.set("n", "<leader>pv", require("overlook.api").open_in_vsplit, { desc = "Open popup in vsplit" })
vim.keymap.set("n", "<leader>pt", require("overlook.api").open_in_tab, { desc = "Open popup in tab" })
vim.keymap.set("n", "<leader>po", require("overlook.api").open_in_original_window, { desc = "Open popup in current window" })
```

### API Functions

Check `:h overlook-api` for more details.

- `peek_definition()` - Peek at the LSP definition under cursor
- `peek_cursor()` - Create a popup at current cursor position
- `peek_mark()` - Prompt for a mark and peek at its location
- `restore_popup()` - Restore the last closed popup
- `restore_all_popups()` - Restore all closed popups
- `close_all()` - Close all overlook popups
- `switch_focus()` - Switch focus between popups and root window
- `open_in_split()` - Promote popup to horizontal split
- `open_in_vsplit()` - Promote popup to vertical split
- `open_in_tab()` - Promote popup to new tab
- `open_in_original_window()` - Replace current window with popup content

## Acknowledgments

Special thanks to the [lspsaga.nvim](https://github.com/nvimdev/lspsaga.nvim) project for the original `peek_definition` implementation that inspired this plugin.
