--- kgd.client — Low-level msgpack-RPC client for kgd.
---
--- Uses neovim's built-in vim.uv (libuv) for Unix socket I/O
--- and vim.mpack for encoding/decoding.

local M = {}

local uv = vim.uv or vim.loop
local mpack_encode = vim.mpack.encode
local mpack_decode = vim.mpack.decode

-- msgpack-rpc types
local MSG_REQUEST = 0
local MSG_RESPONSE = 1
local MSG_NOTIFICATION = 2

-- State
local pipe = nil
local next_id = 0
local pending = {} -- msgid -> { callback }
local recv_buf = ""
local connected = false

-- Hello result
M.client_id = nil
M.cols = 0
M.rows = 0
M.cell_width = 0
M.cell_height = 0
M.in_tmux = false
M.fg = { r = 0, g = 0, b = 0 }
M.bg = { r = 0, g = 0, b = 0 }

-- Notification callbacks
M.on_evicted = nil
M.on_topology_changed = nil
M.on_visibility_changed = nil
M.on_theme_changed = nil

local function get_socket_path(opts)
  if opts.socket_path and opts.socket_path ~= "" then
    return opts.socket_path
  end
  local env = vim.env.KGD_SOCKET
  if env and env ~= "" then
    return env
  end
  -- Compute default — must match daemon's sessionKey()
  local runtime = vim.env.XDG_RUNTIME_DIR or vim.fn.tempname():match("(.*/)")
  local key
  if vim.env.KITTY_WINDOW_ID and vim.env.KITTY_WINDOW_ID ~= "" then
    key = "kitty-" .. vim.env.KITTY_WINDOW_ID
  elseif vim.env.WEZTERM_PANE and vim.env.WEZTERM_PANE ~= "" then
    key = "wezterm-" .. vim.env.WEZTERM_PANE
  else
    key = "default"
  end
  return runtime .. "/kgd-" .. key .. ".sock"
end

local function process_message(msg)
  if type(msg) ~= "table" or #msg < 3 then return end
  local msg_type = msg[1]

  if msg_type == MSG_RESPONSE then
    local msgid = msg[2]
    local err = msg[3]
    local result = msg[4]
    local cb = pending[msgid]
    pending[msgid] = nil
    if cb then
      if err ~= nil and err ~= vim.NIL then
        local errmsg = type(err) == "table" and err.message or tostring(err)
        vim.schedule(function() cb(nil, errmsg) end)
      else
        vim.schedule(function() cb(result, nil) end)
      end
    end

  elseif msg_type == MSG_NOTIFICATION then
    local method = msg[2]
    local params_arr = msg[3]
    local params = type(params_arr) == "table" and params_arr[1] or nil
    if type(params) ~= "table" then return end

    vim.schedule(function()
      if method == "evicted" and M.on_evicted then
        M.on_evicted(params.handle)
      elseif method == "topology_changed" and M.on_topology_changed then
        M.on_topology_changed(params.cols, params.rows, params.cell_width, params.cell_height)
      elseif method == "visibility_changed" and M.on_visibility_changed then
        M.on_visibility_changed(params.placement_id, params.visible)
      elseif method == "theme_changed" and M.on_theme_changed then
        M.on_theme_changed(params.fg, params.bg)
      end
    end)
  end
end

local function close_pipe()
  connected = false
  if pipe then
    pipe:read_stop()
    if not pipe:is_closing() then
      pipe:close()
    end
    pipe = nil
  end
  -- Fail all pending callbacks
  for msgid, cb in pairs(pending) do
    vim.schedule(function() cb(nil, "connection lost") end)
  end
  pending = {}
  recv_buf = ""
end

local function on_read(err, data)
  if err or not data then
    close_pipe()
    return
  end

  recv_buf = recv_buf .. data

  -- Try to decode complete messages
  while #recv_buf > 0 do
    local ok, result, pos = pcall(mpack_decode, recv_buf)
    if not ok then
      break -- partial message or decode error
    end
    recv_buf = recv_buf:sub(pos)
    process_message(result)
  end
end

local function write_to_pipe(data)
  if not pipe then return end
  pipe:write(data, function(err)
    if err then close_pipe() end
  end)
end

local function send_request(method, params, callback)
  if not connected or not pipe then
    if callback then callback(nil, "not connected") end
    return
  end

  next_id = next_id + 1
  local msgid = next_id
  pending[msgid] = callback

  local msg
  if params ~= nil then
    msg = { MSG_REQUEST, msgid, method, { params } }
  else
    msg = { MSG_REQUEST, msgid, method, {} }
  end

  write_to_pipe(mpack_encode(msg))
end

local function send_notification(method, params)
  if not connected or not pipe then return end

  local msg
  if params ~= nil then
    msg = { MSG_NOTIFICATION, method, { params } }
  else
    msg = { MSG_NOTIFICATION, method, {} }
  end

  write_to_pipe(mpack_encode(msg))
end

--- Setup and connect to the daemon.
---@param opts { socket_path?: string, auto_launch?: boolean, client_type?: string, session_id?: string }
function M.setup(opts)
  if connected then return end

  local socket_path = get_socket_path(opts)

  -- Auto-launch daemon if needed
  if opts.auto_launch then
    local stat = uv.fs_stat(socket_path)
    if not stat then
      local kgd = vim.fn.exepath("kgd")
      if kgd ~= "" then
        vim.fn.jobstart({ kgd, "serve", "--socket", socket_path }, { detach = true })
        -- Wait for socket to appear (up to 3s)
        vim.wait(3000, function()
          return uv.fs_stat(socket_path) ~= nil
        end, 100)
      end
    end
  end

  pipe = uv.new_pipe()
  pipe:connect(socket_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("[kgd] failed to connect: " .. err, vim.log.levels.WARN)
      end)
      if not pipe:is_closing() then pipe:close() end
      pipe = nil
      return
    end

    connected = true
    recv_buf = ""
    pipe:read_start(on_read)

    -- Send hello
    local hello_params = {
      client_type = opts.client_type or "kgd.nvim",
      pid = vim.fn.getpid(),
      label = "neovim",
    }
    if opts.session_id and opts.session_id ~= "" then
      hello_params.session_id = opts.session_id
    end
    send_request("hello", hello_params, function(result, hello_err)
      if hello_err then
        vim.notify("[kgd] hello failed: " .. hello_err, vim.log.levels.WARN)
        return
      end
      if type(result) == "table" then
        M.client_id = result.client_id
        M.cols = result.cols or 0
        M.rows = result.rows or 0
        M.cell_width = result.cell_width or 0
        M.cell_height = result.cell_height or 0
        M.in_tmux = result.in_tmux or false
        M.fg = result.fg or { r = 0, g = 0, b = 0 }
        M.bg = result.bg or { r = 0, g = 0, b = 0 }
      end
    end)
  end)
end

--- Upload image data.
---@param data string
---@param format string
---@param width integer
---@param height integer
---@param callback? fun(handle: integer, err?: string)
function M.upload(data, format, width, height, callback)
  send_request("upload", {
    data = data,
    format = format,
    width = width,
    height = height,
  }, function(result, err)
    if callback then
      if err then
        callback(0, err)
      elseif type(result) == "table" then
        callback(result.handle or 0, nil)
      else
        callback(0, "unexpected result")
      end
    end
  end)
end

--- Place an image.
---@param handle integer
---@param anchor table
---@param width integer
---@param height integer
---@param opts? { src_x?: integer, src_y?: integer, src_w?: integer, src_h?: integer, z_index?: integer }
---@param callback? fun(placement_id: integer, err?: string)
function M.place(handle, anchor, width, height, opts, callback)
  local params = {
    handle = handle,
    anchor = anchor,
    width = width,
    height = height,
  }
  if opts then
    if opts.src_x then params.src_x = opts.src_x end
    if opts.src_y then params.src_y = opts.src_y end
    if opts.src_w then params.src_w = opts.src_w end
    if opts.src_h then params.src_h = opts.src_h end
    if opts.z_index then params.z_index = opts.z_index end
  end

  send_request("place", params, function(result, err)
    if callback then
      if err then
        callback(0, err)
      elseif type(result) == "table" then
        callback(result.placement_id or 0, nil)
      else
        callback(0, "unexpected result")
      end
    end
  end)
end

--- Remove a placement.
---@param placement_id integer
function M.unplace(placement_id)
  send_request("unplace", { placement_id = placement_id })
end

--- Remove all placements.
function M.unplace_all()
  send_notification("unplace_all")
end

--- Free an upload handle.
---@param handle integer
function M.free(handle)
  send_request("free", { handle = handle })
end

--- Register a window geometry.
---@param win_id integer
---@param pane_id? string
---@param top integer
---@param left integer
---@param width integer
---@param height integer
---@param scroll_top integer
function M.register_win(win_id, pane_id, top, left, width, height, scroll_top)
  send_notification("register_win", {
    win_id = win_id,
    pane_id = pane_id or "",
    top = top,
    left = left,
    width = width,
    height = height,
    scroll_top = scroll_top,
  })
end

--- Update scroll position.
---@param win_id integer
---@param scroll_top integer
function M.update_scroll(win_id, scroll_top)
  send_notification("update_scroll", {
    win_id = win_id,
    scroll_top = scroll_top,
  })
end

--- Unregister a window.
---@param win_id integer
function M.unregister_win(win_id)
  send_notification("unregister_win", { win_id = win_id })
end

--- Get active placements.
---@param callback fun(placements: table[], err?: string)
function M.list(callback)
  send_request("list", nil, function(result, err)
    if callback then
      if err then
        callback({}, err)
      elseif type(result) == "table" then
        callback(result.placements or {}, nil)
      else
        callback({}, nil)
      end
    end
  end)
end

--- Get daemon status.
---@param callback fun(status: table, err?: string)
function M.status(callback)
  send_request("status", nil, function(result, err)
    if callback then callback(result or {}, err) end
  end)
end

--- Request daemon shutdown.
function M.stop()
  send_notification("stop")
end

--- Check connection status.
---@return boolean
function M.is_connected()
  return connected
end

--- Disconnect from daemon.
function M.disconnect()
  connected = false
  if pipe then
    pipe:read_stop()
    if not pipe:is_closing() then
      pipe:close()
    end
    pipe = nil
  end
  recv_buf = ""
  pending = {}
end

return M
