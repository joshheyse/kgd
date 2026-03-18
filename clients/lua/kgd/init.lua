--- kgd client library for Lua.
--
-- Provides a single-threaded, poll-based client for the kgd (Kitty Graphics
-- Daemon) over Unix domain sockets with msgpack-RPC encoding.
--
-- Usage:
--   local kgd = require("kgd")
--   local client = kgd.Client.connect({ client_type = "myapp" })
--   local handle = client:upload(image_data, "png", width, height)
--   local pid = client:place(handle, kgd.Anchor.absolute(5, 10), 20, 15)
--   client:unplace(pid)
--   client:free(handle)
--   client:close()

local protocol = require("kgd.protocol")
local Socket = require("kgd.socket")

local M = {}

---------------------------------------------------------------------------
-- RPC method names
---------------------------------------------------------------------------

M.METHOD_HELLO = "hello"
M.METHOD_UPLOAD = "upload"
M.METHOD_PLACE = "place"
M.METHOD_UNPLACE = "unplace"
M.METHOD_UNPLACE_ALL = "unplace_all"
M.METHOD_FREE = "free"
M.METHOD_REGISTER_WIN = "register_win"
M.METHOD_UPDATE_SCROLL = "update_scroll"
M.METHOD_UNREGISTER_WIN = "unregister_win"
M.METHOD_LIST = "list"
M.METHOD_STATUS = "status"
M.METHOD_STOP = "stop"

-- Notification names
M.NOTIFY_EVICTED = "evicted"
M.NOTIFY_TOPOLOGY_CHANGED = "topology_changed"
M.NOTIFY_VISIBILITY_CHANGED = "visibility_changed"
M.NOTIFY_THEME_CHANGED = "theme_changed"

---------------------------------------------------------------------------
-- Color
---------------------------------------------------------------------------

--- Create a Color table with r, g, b fields.
-- @param r integer  Red (0-65535).
-- @param g integer  Green (0-65535).
-- @param b integer  Blue (0-65535).
-- @return table
function M.Color(r, g, b)
    return { r = r or 0, g = g or 0, b = b or 0 }
end

---------------------------------------------------------------------------
-- Anchor constructors
---------------------------------------------------------------------------

M.Anchor = {}

--- Create an absolute-position anchor.
-- @param row integer  Terminal row.
-- @param col integer  Terminal column.
-- @return table
function M.Anchor.absolute(row, col)
    local a = { type = "absolute" }
    if row and row ~= 0 then a.row = row end
    if col and col ~= 0 then a.col = col end
    return a
end

--- Create a tmux-pane-relative anchor.
-- @param pane_id string  Tmux pane identifier (e.g. "%0").
-- @param row integer  Row within the pane.
-- @param col integer  Column within the pane.
-- @return table
function M.Anchor.pane(pane_id, row, col)
    local a = { type = "pane" }
    if pane_id and pane_id ~= "" then a.pane_id = pane_id end
    if row and row ~= 0 then a.row = row end
    if col and col ~= 0 then a.col = col end
    return a
end

--- Create a neovim-window-relative anchor.
-- @param win_id integer  Neovim window ID.
-- @param buf_line integer  Buffer line number.
-- @param col integer  Column within the window.
-- @return table
function M.Anchor.win(win_id, buf_line, col)
    local a = { type = "win" }
    if win_id and win_id ~= 0 then a.win_id = win_id end
    if buf_line and buf_line ~= 0 then a.buf_line = buf_line end
    if col and col ~= 0 then a.col = col end
    return a
end

--- Create an anchor from a raw table, omitting zero-valued fields.
-- @param tbl table  Table with type, pane_id, win_id, buf_line, row, col.
-- @return table
function M.Anchor.from_table(tbl)
    local a = { type = tbl.type or "absolute" }
    if tbl.pane_id and tbl.pane_id ~= "" then a.pane_id = tbl.pane_id end
    if tbl.win_id and tbl.win_id ~= 0 then a.win_id = tbl.win_id end
    if tbl.buf_line and tbl.buf_line ~= 0 then a.buf_line = tbl.buf_line end
    if tbl.row and tbl.row ~= 0 then a.row = tbl.row end
    if tbl.col and tbl.col ~= 0 then a.col = tbl.col end
    return a
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

--- Default options for connecting to kgd.
-- @field socket_path string  Override socket path ("" = auto-detect).
-- @field session_id  string  Session identifier (optional).
-- @field client_type string  Client type string sent in hello.
-- @field label       string  Human-readable label.
-- @field auto_launch boolean Start daemon if not running (default true).
function M.Options(tbl)
    tbl = tbl or {}
    return {
        socket_path = tbl.socket_path or "",
        session_id = tbl.session_id or "",
        client_type = tbl.client_type or "",
        label = tbl.label or "",
        auto_launch = tbl.auto_launch == nil and true or tbl.auto_launch,
    }
end

---------------------------------------------------------------------------
-- Socket path resolution
---------------------------------------------------------------------------

local function default_socket_path()
    local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
    if not runtime_dir or runtime_dir == "" then
        runtime_dir = os.getenv("TMPDIR") or "/tmp"
    end
    local kitty_id = os.getenv("KITTY_WINDOW_ID") or "default"
    return runtime_dir .. "/kgd-" .. kitty_id .. ".sock"
end

local function resolve_socket_path(opts)
    if opts.socket_path ~= "" then
        return opts.socket_path
    end
    local env_path = os.getenv("KGD_SOCKET")
    if env_path and env_path ~= "" then
        return env_path
    end
    return default_socket_path()
end

---------------------------------------------------------------------------
-- PID helper
---------------------------------------------------------------------------

--- Get the current process ID (best effort).
-- Uses /proc on Linux, sysctl on macOS, falls back to shell.
-- @return integer
function M._getpid()
    -- Try reading /proc/self (Linux).
    local f = io.open("/proc/self/stat", "r")
    if f then
        local line = f:read("*l")
        f:close()
        if line then
            local pid = line:match("^(%d+)")
            if pid then return tonumber(pid) end
        end
    end

    -- Fallback: shell.
    local h = io.popen("echo $$")
    if h then
        local out = h:read("*l")
        h:close()
        if out then return tonumber(out) or 0 end
    end

    return 0
end

---------------------------------------------------------------------------
-- Daemon auto-launch
---------------------------------------------------------------------------

local function try_connect(path)
    local s = Socket.new()
    local ok = s:connect(path)
    if ok then
        s:close()
        return true
    end
    return false
end

local function ensure_daemon(socket_path)
    if try_connect(socket_path) then
        return true, nil
    end

    -- Try to find kgd in PATH and launch it.
    -- Use 'command -v' which is POSIX and works in both bash and zsh.
    local handle = io.popen("command -v kgd 2>/dev/null")
    if not handle then
        return false, "kgd not found in PATH"
    end
    local kgd_path = handle:read("*l")
    handle:close()

    if not kgd_path or kgd_path == "" then
        return false, "kgd not found in PATH"
    end

    -- Launch daemon in the background.
    os.execute(
        kgd_path .. " serve --socket " .. socket_path
        .. " >/dev/null 2>&1 &"
    )

    -- Wait up to 5 seconds for the daemon to start.
    local socket_mod = require("socket")
    for _ = 1, 50 do
        socket_mod.sleep(0.1)
        if try_connect(socket_path) then
            return true, nil
        end
    end

    return false, "timed out waiting for kgd to start"
end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------

local Client = {}
Client.__index = Client
M.Client = Client

--- Connect to the kgd daemon and perform the hello handshake.
-- @param opts table|nil  Options table (see M.Options).
-- @return Client
function Client.connect(opts)
    opts = M.Options(opts)
    local socket_path = resolve_socket_path(opts)

    if opts.auto_launch then
        local ok, err = ensure_daemon(socket_path)
        if not ok then
            error("kgd: " .. tostring(err))
        end
    end

    local sock = Socket.new()
    local ok, err = sock:connect(socket_path)
    if not ok then
        error("kgd: " .. tostring(err))
    end

    local self = setmetatable({}, Client)
    self._sock = sock
    self._buf = ""
    self._next_id = 0
    self._pending = {}   -- msgid -> { err=, result=, done=bool }
    self._closed = false

    -- Hello result fields.
    self.client_id = ""
    self.cols = 0
    self.rows = 0
    self.cell_width = 0
    self.cell_height = 0
    self.in_tmux = false
    self.fg = M.Color(0, 0, 0)
    self.bg = M.Color(0, 0, 0)

    -- Notification callbacks.
    -- Set these to functions to receive server notifications:
    --   client.on_evicted = function(handle) end
    --   client.on_topology_changed = function(cols, rows, cell_width, cell_height) end
    --   client.on_visibility_changed = function(placement_id, visible) end
    --   client.on_theme_changed = function(fg, bg) end
    self.on_evicted = nil
    self.on_topology_changed = nil
    self.on_visibility_changed = nil
    self.on_theme_changed = nil

    -- Perform hello handshake.
    local hello_params = {
        client_type = opts.client_type,
        pid = M._getpid(),
        label = opts.label,
    }
    if opts.session_id ~= "" then
        hello_params.session_id = opts.session_id
    end

    local result = self:_call(M.METHOD_HELLO, hello_params)
    if type(result) == "table" then
        self.client_id = result.client_id or ""
        self.cols = result.cols or 0
        self.rows = result.rows or 0
        self.cell_width = result.cell_width or 0
        self.cell_height = result.cell_height or 0
        self.in_tmux = result.in_tmux or false
        if type(result.fg) == "table" then
            self.fg = M.Color(result.fg.r, result.fg.g, result.fg.b)
        end
        if type(result.bg) == "table" then
            self.bg = M.Color(result.bg.r, result.bg.g, result.bg.b)
        end
    end

    return self
end

---------------------------------------------------------------------------
-- Public RPC methods
---------------------------------------------------------------------------

--- Upload image data and return a handle.
-- @param data string  Raw image bytes.
-- @param fmt string  Image format ("png", "rgb", "rgba").
-- @param width integer  Image width in pixels.
-- @param height integer  Image height in pixels.
-- @return integer  Image handle for subsequent place/free calls.
function Client:upload(data, fmt, width, height)
    local result = self:_call(M.METHOD_UPLOAD, {
        data = data,
        format = fmt,
        width = width,
        height = height,
    })
    if type(result) == "table" then
        return result.handle or 0
    end
    error("kgd: unexpected upload result: " .. tostring(result))
end

--- Place an image and return a placement ID.
-- @param handle integer  Image handle from upload().
-- @param anchor table  Anchor table (use Anchor constructors).
-- @param width integer  Display width in cells.
-- @param height integer  Display height in cells.
-- @param opts table|nil  Optional: src_x, src_y, src_w, src_h, z_index.
-- @return integer  Placement ID.
function Client:place(handle, anchor, width, height, opts)
    opts = opts or {}
    local params = {
        handle = handle,
        anchor = anchor,
        width = width,
        height = height,
    }
    if opts.src_x and opts.src_x ~= 0 then params.src_x = opts.src_x end
    if opts.src_y and opts.src_y ~= 0 then params.src_y = opts.src_y end
    if opts.src_w and opts.src_w ~= 0 then params.src_w = opts.src_w end
    if opts.src_h and opts.src_h ~= 0 then params.src_h = opts.src_h end
    if opts.z_index and opts.z_index ~= 0 then params.z_index = opts.z_index end

    local result = self:_call(M.METHOD_PLACE, params)
    if type(result) == "table" then
        return result.placement_id or 0
    end
    error("kgd: unexpected place result: " .. tostring(result))
end

--- Remove a placement.
-- @param placement_id integer  Placement ID from place().
function Client:unplace(placement_id)
    self:_call(M.METHOD_UNPLACE, { placement_id = placement_id })
end

--- Remove all placements for this client (notification, no response).
function Client:unplace_all()
    self:_notify(M.METHOD_UNPLACE_ALL, nil)
end

--- Release an uploaded image handle.
-- @param handle integer  Image handle from upload().
function Client:free(handle)
    self:_call(M.METHOD_FREE, { handle = handle })
end

--- Register a neovim window geometry (notification, no response).
-- @param win_id integer  Neovim window ID.
-- @param opts table|nil  Optional: pane_id, top, left, width, height, scroll_top.
function Client:register_win(win_id, opts)
    opts = opts or {}
    self:_notify(M.METHOD_REGISTER_WIN, {
        win_id = win_id,
        pane_id = opts.pane_id or "",
        top = opts.top or 0,
        left = opts.left or 0,
        width = opts.width or 0,
        height = opts.height or 0,
        scroll_top = opts.scroll_top or 0,
    })
end

--- Update scroll position for a registered window (notification, no response).
-- @param win_id integer  Neovim window ID.
-- @param scroll_top integer  New scroll position.
function Client:update_scroll(win_id, scroll_top)
    self:_notify(M.METHOD_UPDATE_SCROLL, {
        win_id = win_id,
        scroll_top = scroll_top,
    })
end

--- Unregister a neovim window (notification, no response).
-- @param win_id integer  Neovim window ID.
function Client:unregister_win(win_id)
    self:_notify(M.METHOD_UNREGISTER_WIN, { win_id = win_id })
end

--- Return all active placements.
-- @return table  List of placement info tables with fields:
--   placement_id, client_id, handle, visible, row, col.
function Client:list()
    local result = self:_call(M.METHOD_LIST, nil)
    if type(result) ~= "table" then
        return {}
    end
    local placements = {}
    local raw = result.placements or {}
    for i = 1, #raw do
        local p = raw[i]
        if type(p) == "table" then
            placements[#placements + 1] = {
                placement_id = p.placement_id or 0,
                client_id = p.client_id or "",
                handle = p.handle or 0,
                visible = p.visible or false,
                row = p.row or 0,
                col = p.col or 0,
            }
        end
    end
    return placements
end

--- Return daemon status information.
-- @return table  Status table with fields: clients, placements, images, cols, rows.
function Client:status()
    local result = self:_call(M.METHOD_STATUS, nil)
    if type(result) == "table" then
        return {
            clients = result.clients or 0,
            placements = result.placements or 0,
            images = result.images or 0,
            cols = result.cols or 0,
            rows = result.rows or 0,
        }
    end
    return { clients = 0, placements = 0, images = 0, cols = 0, rows = 0 }
end

--- Request the daemon to shut down (notification, no response).
function Client:stop()
    self:_notify(M.METHOD_STOP, nil)
end

--- Close the connection.
function Client:close()
    self._closed = true
    self._sock:close()
end

---------------------------------------------------------------------------
-- Polling
---------------------------------------------------------------------------

--- Poll for incoming messages and dispatch notifications.
--
-- Call this periodically to process server notifications. Also called
-- internally by _call() while waiting for a response.
--
-- @param timeout number|nil  Seconds to wait for data (default 0, non-blocking).
-- @return boolean  true if any messages were processed.
function Client:poll(timeout)
    if self._closed then
        return false
    end

    timeout = timeout or 0
    local processed = false

    if self._sock:poll(timeout) then
        local data, err = self._sock:receive()
        if data then
            self._buf = self._buf .. data
            processed = true
        elseif err == "closed" then
            self._closed = true
            -- Wake all pending calls.
            for _, entry in pairs(self._pending) do
                entry.err = "connection closed"
                entry.done = true
            end
            return false
        end
    end

    -- Decode any complete messages from the buffer.
    if #self._buf > 0 then
        local messages, remainder = protocol.decode(self._buf)
        self._buf = remainder
        for i = 1, #messages do
            self:_dispatch(messages[i])
            processed = true
        end
    end

    return processed
end

---------------------------------------------------------------------------
-- Internal
---------------------------------------------------------------------------

function Client:_call(method, params, timeout)
    timeout = timeout or 10.0

    local msgid = self._next_id
    self._next_id = self._next_id + 1

    self._pending[msgid] = { err = nil, result = nil, done = false }

    local encoded = protocol.encode_request(msgid, method, params)
    local ok, err = self._sock:send(encoded)
    if not ok then
        self._pending[msgid] = nil
        error("kgd: send failed: " .. tostring(err))
    end

    -- Poll until we get our response or time out.
    local socket_mod = require("socket")
    local deadline = socket_mod.gettime() + timeout

    while not self._pending[msgid].done do
        if self._closed then
            self._pending[msgid] = nil
            error("kgd: connection closed")
        end

        local remaining = deadline - socket_mod.gettime()
        if remaining <= 0 then
            self._pending[msgid] = nil
            error("kgd: RPC call " .. method .. " timed out")
        end

        local poll_time = remaining < 0.1 and remaining or 0.1
        self:poll(poll_time)
    end

    local entry = self._pending[msgid]
    self._pending[msgid] = nil

    if entry.err ~= nil then
        local errmsg
        if type(entry.err) == "table" and entry.err.message then
            errmsg = entry.err.message
        elseif type(entry.err) == "string" then
            errmsg = entry.err
        else
            errmsg = "RPC error: " .. tostring(entry.err)
        end
        error("kgd: " .. errmsg)
    end

    return entry.result
end

function Client:_notify(method, params)
    local encoded = protocol.encode_notification(method, params)
    local ok, err = self._sock:send(encoded)
    if not ok then
        error("kgd: send failed: " .. tostring(err))
    end
end

function Client:_dispatch(msg)
    local mtype = protocol.msg_type(msg)

    if mtype == "response" then
        local msgid, rpc_err, result = protocol.parse_response(msg)
        if msgid ~= nil and self._pending[msgid] then
            self._pending[msgid].err = rpc_err
            self._pending[msgid].result = result
            self._pending[msgid].done = true
        end

    elseif mtype == "notification" then
        local method, params = protocol.parse_notification(msg)
        if not method or type(params) ~= "table" then
            return
        end
        self:_handle_notification(method, params)
    end
end

function Client:_handle_notification(method, params)
    if method == M.NOTIFY_EVICTED and self.on_evicted then
        self.on_evicted(params.handle or 0)

    elseif method == M.NOTIFY_TOPOLOGY_CHANGED and self.on_topology_changed then
        self.on_topology_changed(
            params.cols or 0,
            params.rows or 0,
            params.cell_width or 0,
            params.cell_height or 0
        )

    elseif method == M.NOTIFY_VISIBILITY_CHANGED and self.on_visibility_changed then
        self.on_visibility_changed(
            params.placement_id or 0,
            params.visible or false
        )

    elseif method == M.NOTIFY_THEME_CHANGED and self.on_theme_changed then
        local fg = M.Color(0, 0, 0)
        local bg = M.Color(0, 0, 0)
        if type(params.fg) == "table" then
            fg = M.Color(params.fg.r, params.fg.g, params.fg.b)
        end
        if type(params.bg) == "table" then
            bg = M.Color(params.bg.r, params.bg.g, params.bg.b)
        end
        self.on_theme_changed(fg, bg)
    end
end

return M
