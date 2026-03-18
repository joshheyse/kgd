--- Unix domain socket wrapper for kgd.
--
-- Provides a non-blocking socket interface using luasocket's Unix domain
-- socket support and socket.select() for polling.

local socket = require("socket")
local unix = require("socket.unix")

local M = {}
M.__index = M

--- Create a new socket wrapper.
-- @return table  Socket instance (not yet connected).
function M.new()
    local self = setmetatable({}, M)
    self._sock = nil
    self._connected = false
    return self
end

--- Connect to a Unix domain socket path.
-- @param path string  Path to the Unix socket.
-- @return boolean  true on success.
-- @return string|nil  Error message on failure.
function M:connect(path)
    local sock, err = unix()
    if not sock then
        return false, "failed to create unix socket: " .. tostring(err)
    end

    local ok, cerr = sock:connect(path)
    if not ok then
        sock:close()
        return false, "failed to connect to " .. path .. ": " .. tostring(cerr)
    end

    -- Set non-blocking for poll-based reads.
    sock:settimeout(0)

    self._sock = sock
    self._connected = true
    return true, nil
end

--- Send data through the socket.
-- @param data string  Bytes to send.
-- @return boolean  true on success.
-- @return string|nil  Error message on failure.
function M:send(data)
    if not self._connected then
        return false, "not connected"
    end

    -- sendall: keep sending until all bytes are written.
    local total = #data
    local sent = 0
    while sent < total do
        -- Temporarily set blocking for reliable send.
        self._sock:settimeout(10)
        local bytes, err, partial = self._sock:send(data, sent + 1)
        self._sock:settimeout(0)

        if bytes then
            sent = bytes
        elseif err == "closed" then
            self._connected = false
            return false, "connection closed"
        else
            -- partial progress
            if partial and partial > 0 then
                sent = partial
            else
                return false, "send error: " .. tostring(err)
            end
        end
    end

    return true, nil
end

--- Receive available data without blocking.
-- Returns whatever is available in the socket buffer right now.
-- @return string|nil  Data received, or nil if nothing available.
-- @return string|nil  Error message, or "timeout" if no data, or "closed".
function M:receive()
    if not self._connected then
        return nil, "not connected"
    end

    local data, err, partial = self._sock:receive(65536)
    if data then
        return data, nil
    elseif err == "timeout" then
        -- No data available right now (non-blocking).
        if partial and #partial > 0 then
            return partial, nil
        end
        return nil, "timeout"
    elseif err == "closed" then
        self._connected = false
        return nil, "closed"
    else
        return nil, err
    end
end

--- Poll the socket for readable data with a timeout.
-- @param timeout number  Seconds to wait (0 for immediate check).
-- @return boolean  true if data is available.
function M:poll(timeout)
    if not self._connected or not self._sock then
        return false
    end
    local readable, _, err = socket.select({ self._sock }, nil, timeout or 0)
    if err then
        return false
    end
    return readable and #readable > 0
end

--- Check whether the socket is connected.
-- @return boolean
function M:is_connected()
    return self._connected
end

--- Close the socket.
function M:close()
    if self._sock then
        self._sock:close()
        self._sock = nil
    end
    self._connected = false
end

return M
