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
