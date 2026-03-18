--- msgpack-RPC encoding/decoding for the kgd protocol.
--
-- Message formats:
--   Request:      [0, msgid, method, [params]]
--   Response:     [1, msgid, error, result]
--   Notification: [2, method, [params]]

local mp = require("MessagePack")

local M = {}

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
        -- mp.unpack(buf, offset) returns (value, next_offset).
        -- It throws on incomplete/malformed data.
        local ok, msg, new_offset = pcall(mp.unpack, buf, offset)
        if not ok then
            -- Incomplete data or parse error; stop and return remainder.
            break
        end
        -- If unpack returned no new offset, we cannot advance.
        if type(new_offset) ~= "number" or new_offset <= offset then
            break
        end
        messages[#messages + 1] = msg
        offset = new_offset
    end

    local remainder
    if offset > buflen then
        remainder = ""
    else
        remainder = buf:sub(offset)
    end

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
    if #msg < 4 then
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
