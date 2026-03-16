--- kgd.nvim — Neovim integration for the Kitty Graphics Daemon.
---
--- High-level Lua library providing a declarative image API:
--- - Automatic window/scroll tracking via autocmds
--- - Image placement tied to buffer lines
--- - Lazy upload: images transmitted only when visible
--- - Lifecycle management: place/unplace/free handled automatically
---
--- Usage:
---   local kgd = require("kgd")
---   kgd.setup()
---   local handle = kgd.upload(image_data, "png", width, height)
---   kgd.place(handle, { buf = 0, line = 5, col = 0, width = 20, height = 10 })
---
--- For lower-level access:
---   local client = require("kgd.client")
---   client.connect()

local M = {}
local client = require("kgd.client")
local tracker = require("kgd.tracker")

--- Setup kgd.nvim. Call once during init.
---@param opts? { socket_path?: string, auto_launch?: boolean, client_type?: string }
function M.setup(opts)
  opts = opts or {}
  client.setup({
    socket_path = opts.socket_path,
    auto_launch = opts.auto_launch ~= false,
    client_type = opts.client_type or "kgd.nvim",
  })
  tracker.setup()
end

--- Upload image data to the daemon.
---@param data string Raw image data (PNG, RGB, or RGBA)
---@param format string "png" | "rgb" | "rgba"
---@param width integer Pixel width
---@param height integer Pixel height
---@param callback? fun(handle: integer, err?: string)
function M.upload(data, format, width, height, callback)
  client.upload(data, format, width, height, callback)
end

--- Place an image at a buffer line.
---
--- The placement is tied to the buffer line and will automatically track
--- scroll position and window geometry changes. The image is shown when
--- visible and hidden when scrolled off-screen.
---
---@param handle integer Upload handle from kgd.upload()
---@param opts { buf?: integer, line: integer, col?: integer, width: integer, height: integer, src_x?: integer, src_y?: integer, src_w?: integer, src_h?: integer, z_index?: integer }
---@param callback? fun(placement_id: integer, err?: string)
function M.place(handle, opts, callback)
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local line = opts.line
  local col = opts.col or 0

  -- Find a window displaying this buffer
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    if callback then callback(0, "no window displays this buffer") end
    return
  end

  local win = wins[1]

  client.place(handle, {
    type = "nvim_win",
    win_id = win,
    buf_line = line,
    col = col,
  }, opts.width, opts.height, {
    src_x = opts.src_x,
    src_y = opts.src_y,
    src_w = opts.src_w,
    src_h = opts.src_h,
    z_index = opts.z_index,
  }, callback)
end

--- Remove a placement.
---@param placement_id integer
function M.unplace(placement_id)
  client.unplace(placement_id)
end

--- Remove all placements for this client.
function M.unplace_all()
  client.unplace_all()
end

--- Free an uploaded image handle.
---@param handle integer
function M.free(handle)
  client.free(handle)
end

--- Get daemon status.
---@param callback fun(status: table, err?: string)
function M.status(callback)
  client.status(callback)
end

--- Check if connected to the daemon.
---@return boolean
function M.is_connected()
  return client.is_connected()
end

--- Disconnect from the daemon.
function M.disconnect()
  tracker.teardown()
  client.disconnect()
end

return M
