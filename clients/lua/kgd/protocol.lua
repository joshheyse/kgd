--- msgpack-RPC encoding/decoding for the kgd protocol.
--
-- Message formats:
--   Request:      [0, msgid, method, [params]]
--   Response:     [1, msgid, error, result]
--   Notification: [2, method, [params]]

local mp = require("MessagePack")

local M = {}

--- Skip over one complete msgpack value at position i in buf.
-- Returns the position of the first byte after the value, or nil if incomplete.
local function msgpack_next(buf, i)
    if i > #buf then return nil end
    local b = buf:byte(i)
    -- positive fixint / negative fixint
    if b <= 0x7f or b >= 0xe0 then return i + 1 end
    -- fixmap (0x80-0x8f)
    if b >= 0x80 and b <= 0x8f then
        local pos = i + 1
        for _ = 1, (b - 0x80) * 2 do
            pos = msgpack_next(buf, pos)
            if not pos then return nil end
        end
        return pos
    end
    -- fixarray (0x90-0x9f)
    if b >= 0x90 and b <= 0x9f then
        local pos = i + 1
        for _ = 1, b - 0x90 do
            pos = msgpack_next(buf, pos)
            if not pos then return nil end
        end
        return pos
    end
    -- fixstr (0xa0-0xbf)
    if b >= 0xa0 and b <= 0xbf then
        local pos = i + 1 + (b - 0xa0)
        return pos <= #buf + 1 and pos or nil
    end
    -- nil, false, true
    if b == 0xc0 or b == 0xc2 or b == 0xc3 then return i + 1 end
    -- bin8 (0xc4), str8 (0xd9)
    if b == 0xc4 or b == 0xd9 then
        if i + 1 > #buf then return nil end
        return i + 2 + buf:byte(i + 1)
    end
    -- bin16 (0xc5), str16 (0xda)
    if b == 0xc5 or b == 0xda then
        if i + 2 > #buf then return nil end
        local len = string.unpack(">I2", buf, i + 1)
        return i + 3 + len
    end
    -- bin32 (0xc6), str32 (0xdb)
    if b == 0xc6 or b == 0xdb then
        if i + 4 > #buf then return nil end
        local len = string.unpack(">I4", buf, i + 1)
        return i + 5 + len
    end
    -- uint8 (0xcc), int8 (0xd0)
    if b == 0xcc or b == 0xd0 then return i + 1 < #buf and i + 2 or nil end
    -- uint16 (0xcd), int16 (0xd1)
    if b == 0xcd or b == 0xd1 then return i + 2 <= #buf and i + 3 or nil end
    -- uint32 (0xce), int32 (0xd2), float32 (0xca)
    if b == 0xce or b == 0xd2 or b == 0xca then return i + 4 <= #buf and i + 5 or nil end
    -- uint64 (0xcf), int64 (0xd3), float64 (0xcb)
    if b == 0xcf or b == 0xd3 or b == 0xcb then return i + 8 <= #buf and i + 9 or nil end
    -- array16 (0xdc)
    if b == 0xdc then
        if i + 2 > #buf then return nil end
        local n = string.unpack(">I2", buf, i + 1)
        local pos = i + 3
        for _ = 1, n do
            pos = msgpack_next(buf, pos)
            if not pos then return nil end
        end
        return pos
    end
    -- array32 (0xdd)
    if b == 0xdd then
        if i + 4 > #buf then return nil end
        local n = string.unpack(">I4", buf, i + 1)
        local pos = i + 5
        for _ = 1, n do
            pos = msgpack_next(buf, pos)
            if not pos then return nil end
        end
        return pos
    end
    -- map16 (0xde)
    if b == 0xde then
        if i + 2 > #buf then return nil end
        local n = string.unpack(">I2", buf, i + 1)
        local pos = i + 3
        for _ = 1, n * 2 do
            pos = msgpack_next(buf, pos)
            if not pos then return nil end
        end
        return pos
    end
    -- map32 (0xdf)
    if b == 0xdf then
        if i + 4 > #buf then return nil end
        local n = string.unpack(">I4", buf, i + 1)
        local pos = i + 5
        for _ = 1, n * 2 do
            pos = msgpack_next(buf, pos)
            if not pos then return nil end
        end
        return pos
    end
    -- Unknown/ext type — treat as incomplete
    return nil
end

-- Message type constants.
M.MSG_REQUEST = 0
M.MSG_RESPONSE = 1
M.MSG_NOTIFICATION = 2

--- Encode a request message into a msgpack byte string.
-- @param msgid  integer  Monotonically increasing request ID.
-- @param method string   RPC method name.
-- @param params table|nil  Parameters dict, or nil for no params.
-- @return string  Encoded bytes ready for socket write.
function M.encode_request(msgid, method, params)
    local args
    if params ~= nil then
        args = { params }
    else
        args = {}
    end
    return mp.pack({ M.MSG_REQUEST, msgid, method, args })
end

--- Encode a notification message into a msgpack byte string.
-- @param method string  Notification method name.
-- @param params table|nil  Parameters dict, or nil for no params.
-- @return string  Encoded bytes.
function M.encode_notification(method, params)
    local args
    if params ~= nil then
        args = { params }
    else
        args = {}
    end
    return mp.pack({ M.MSG_NOTIFICATION, method, args })
end

--- Decode messages from a buffer string.
--
-- Returns decoded messages and any remaining unconsumed bytes.
-- Each decoded message is a raw Lua table (the msgpack array).
--
-- @param buf string  Buffer of received bytes.
-- @return table  List of decoded messages (may be empty).
-- @return string  Remaining unconsumed bytes.
function M.decode(buf)
    local messages = {}
    local offset = 1
    local buflen = #buf

    while offset <= buflen do
        -- Use msgpack_next to find the end of the next value.
        local next_pos = msgpack_next(buf, offset)
        if not next_pos then
            break
        end
        -- Decode just this value's bytes.
        local chunk = buf:sub(offset, next_pos - 1)
        local ok, val = pcall(mp.unpack, chunk)
        if not ok then
            break
        end
        messages[#messages + 1] = val
        offset = next_pos
    end

    local remainder = (offset > buflen) and "" or buf:sub(offset)
    return messages, remainder
end

--- Classify a decoded message.
-- @param msg table  Decoded msgpack array.
-- @return string|nil  "request", "response", "notification", or nil if invalid.
function M.msg_type(msg)
    if type(msg) ~= "table" or #msg < 3 then
        return nil
    end
    local t = msg[1]
    if t == M.MSG_REQUEST then
        return "request"
    elseif t == M.MSG_RESPONSE then
        return "response"
    elseif t == M.MSG_NOTIFICATION then
        return "notification"
    end
    return nil
end

--- Extract fields from a response message.
-- @param msg table  Decoded response array [1, msgid, error, result].
-- @return integer  msgid
-- @return any  error (nil if no error)
-- @return any  result
function M.parse_response(msg)
    if type(msg) ~= "table" or msg[1] ~= M.MSG_RESPONSE or msg[2] == nil then
        return nil, "malformed response", nil
    end
    return msg[2], msg[3], msg[4]
end

--- Extract fields from a notification message.
-- @param msg table  Decoded notification array [2, method, [params]].
-- @return string  method name
-- @return table|nil  params dict (first element of params array)
function M.parse_notification(msg)
    if #msg < 3 then
        return nil, nil
    end
    local method = msg[2]
    local params_arr = msg[3]
    if type(params_arr) == "table" and #params_arr > 0 then
        return method, params_arr[1]
    end
    return method, nil
end

return M
