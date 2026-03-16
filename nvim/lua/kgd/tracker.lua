--- kgd.tracker — Automatic window/scroll tracking for neovim.
---
--- Sets up autocmds to keep the kgd daemon informed about window geometry
--- and scroll positions. This enables placement anchoring to buffer lines
--- with automatic visibility tracking.

local M = {}
local client = require("kgd.client")

local augroup = nil
local registered_wins = {} -- win_id -> true

local function get_pane_id()
  local tmux = vim.env.TMUX
  if not tmux or tmux == "" then return "" end
  -- Get pane ID from $TMUX_PANE
  return vim.env.TMUX_PANE or ""
end

local function get_win_geometry(win)
  local pos = vim.api.nvim_win_get_position(win)
  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  local view = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  return {
    top = pos[1],
    left = pos[2],
    width = width,
    height = height,
    scroll_top = view.topline - 1, -- convert to 0-based
  }
end

local function register_win(win)
  if not client.is_connected() then return end
  local ok, geom = pcall(get_win_geometry, win)
  if not ok then return end
  -- Use window handle as stable ID (not nvim_win_get_number which changes)
  client.register_win(win, get_pane_id(), geom.top, geom.left,
                      geom.width, geom.height, geom.scroll_top)
  registered_wins[win] = true
end

local function update_scroll(win)
  if not client.is_connected() then return end
  local ok, view = pcall(function()
    return vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview()
    end)
  end)
  if not ok then return end
  client.update_scroll(win, view.topline - 1)
end

local function unregister_win(win)
  if not client.is_connected() then return end
  if registered_wins[win] then
    client.unregister_win(win)
    registered_wins[win] = nil
  end
end

local function register_all_wins()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    register_win(win)
  end
end

--- Setup autocmds for window/scroll tracking.
function M.setup()
  if augroup then return end
  augroup = vim.api.nvim_create_augroup("kgd_tracker", { clear = true })

  -- Register windows on layout changes
  vim.api.nvim_create_autocmd({ "WinNew", "BufWinEnter", "WinResized" }, {
    group = augroup,
    callback = function()
      register_all_wins()
    end,
  })

  -- Track scroll changes
  vim.api.nvim_create_autocmd({ "WinScrolled" }, {
    group = augroup,
    callback = function(ev)
      -- WinScrolled provides the window ID in the match
      local win = tonumber(ev.match)
      if win and vim.api.nvim_win_is_valid(win) then
        -- Re-register to update both geometry and scroll
        register_win(win)
      end
    end,
  })

  -- Unregister on window close
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(ev)
      local win_id = tonumber(ev.match)
      if win_id then
        unregister_win(win_id)
      end
    end,
  })

  -- Initial registration
  register_all_wins()
end

--- Remove autocmds and unregister all windows.
function M.teardown()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  for win_id, _ in pairs(registered_wins) do
    if client.is_connected() then
      client.unregister_win(win_id)
    end
  end
  registered_wins = {}
end

return M
