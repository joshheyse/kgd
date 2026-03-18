--- Tests for the kgd Lua client library.
--
-- Run with: busted spec/client_spec.lua
-- (from the clients/lua/ directory)

-- Add our module path.
package.path = package.path .. ";./?.lua;./?/init.lua"

local protocol = require("kgd.protocol")
local kgd = require("kgd")

describe("kgd.protocol", function()

    describe("message type constants", function()
        it("has correct values", function()
            assert.equal(0, protocol.MSG_REQUEST)
            assert.equal(1, protocol.MSG_RESPONSE)
            assert.equal(2, protocol.MSG_NOTIFICATION)
        end)
    end)

    describe("encode_request", function()
        it("encodes a request with params", function()
            local encoded = protocol.encode_request(1, "hello", { client_type = "test" })
            assert.is_string(encoded)
            assert.truthy(#encoded > 0)

            -- Decode and verify structure.
            local mp = require("MessagePack")
            local msg = mp.unpack(encoded)
            assert.is_table(msg)
            assert.equal(protocol.MSG_REQUEST, msg[1])
            assert.equal(1, msg[2])
            assert.equal("hello", msg[3])
            assert.is_table(msg[4])
            assert.equal(1, #msg[4])
            assert.equal("test", msg[4][1].client_type)
        end)

        it("encodes a request without params", function()
            local encoded = protocol.encode_request(5, "status", nil)
            local mp = require("MessagePack")
            local msg = mp.unpack(encoded)
            assert.equal(protocol.MSG_REQUEST, msg[1])
            assert.equal(5, msg[2])
            assert.equal("status", msg[3])
            assert.is_table(msg[4])
            assert.equal(0, #msg[4])
        end)
    end)

    describe("encode_notification", function()
        it("encodes a notification with params", function()
            local encoded = protocol.encode_notification("stop", { reason = "shutdown" })
            local mp = require("MessagePack")
            local msg = mp.unpack(encoded)
            assert.equal(protocol.MSG_NOTIFICATION, msg[1])
            assert.equal("stop", msg[2])
            assert.is_table(msg[3])
            assert.equal(1, #msg[3])
            assert.equal("shutdown", msg[3][1].reason)
        end)

        it("encodes a notification without params", function()
            local encoded = protocol.encode_notification("unplace_all", nil)
            local mp = require("MessagePack")
            local msg = mp.unpack(encoded)
            assert.equal(protocol.MSG_NOTIFICATION, msg[1])
            assert.equal("unplace_all", msg[2])
            assert.is_table(msg[3])
            assert.equal(0, #msg[3])
        end)
    end)

    describe("decode", function()
        it("decodes a single message", function()
            local mp = require("MessagePack")
            local raw = mp.pack({ 1, 42, nil, { result = true } })
            local messages, remainder = protocol.decode(raw)
            assert.equal(1, #messages)
            assert.equal("", remainder)
            assert.equal(1, messages[1][1])
            assert.equal(42, messages[1][2])
        end)

        it("decodes multiple concatenated messages", function()
            local mp = require("MessagePack")
            local raw = mp.pack({ 1, 1, nil, "ok" })
                     .. mp.pack({ 2, "evicted", { { handle = 7 } } })
            local messages, remainder = protocol.decode(raw)
            assert.equal(2, #messages)
            assert.equal("", remainder)
            assert.equal(1, messages[1][1])
            assert.equal(2, messages[2][1])
        end)

        it("handles incomplete data gracefully", function()
            local mp = require("MessagePack")
            local full = mp.pack({ 1, 1, nil, "ok" })
            -- Chop off last byte to make it incomplete.
            local partial = full:sub(1, #full - 1)
            local messages, remainder = protocol.decode(partial)
            assert.equal(0, #messages)
            assert.equal(partial, remainder)
        end)

        it("handles empty buffer", function()
            local messages, remainder = protocol.decode("")
            assert.equal(0, #messages)
            assert.equal("", remainder)
        end)
    end)

    describe("msg_type", function()
        it("classifies request", function()
            assert.equal("request", protocol.msg_type({ 0, 1, "hello", {} }))
        end)

        it("classifies response", function()
            assert.equal("response", protocol.msg_type({ 1, 1, nil, "ok" }))
        end)

        it("classifies notification", function()
            assert.equal("notification", protocol.msg_type({ 2, "evicted", {} }))
        end)

        it("returns nil for invalid messages", function()
            assert.is_nil(protocol.msg_type({}))
            assert.is_nil(protocol.msg_type({ 5, 1, "x", {} }))
            assert.is_nil(protocol.msg_type("not a table"))
        end)
    end)

    describe("parse_response", function()
        it("extracts fields from a valid response", function()
            local msgid, err, result = protocol.parse_response({ 1, 42, nil, { handle = 3 } })
            assert.equal(42, msgid)
            assert.is_nil(err)
            assert.is_table(result)
            assert.equal(3, result.handle)
        end)

        it("extracts error from error response", function()
            local msgid, err, result = protocol.parse_response(
                { 1, 7, { message = "not found" }, nil }
            )
            assert.equal(7, msgid)
            assert.is_table(err)
            assert.equal("not found", err.message)
            assert.is_nil(result)
        end)
    end)

    describe("parse_notification", function()
        it("extracts method and params", function()
            local method, params = protocol.parse_notification(
                { 2, "evicted", { { handle = 99 } } }
            )
            assert.equal("evicted", method)
            assert.is_table(params)
            assert.equal(99, params.handle)
        end)

        it("handles notification with empty params", function()
            local method, params = protocol.parse_notification(
                { 2, "unplace_all", {} }
            )
            assert.equal("unplace_all", method)
            assert.is_nil(params)
        end)
    end)

    describe("round-trip encode/decode", function()
        it("request round-trips correctly", function()
            local encoded = protocol.encode_request(10, "upload", {
                data = "abc",
                format = "png",
                width = 100,
                height = 200,
            })
            local msgs, rem = protocol.decode(encoded)
            assert.equal(1, #msgs)
            assert.equal("", rem)
            local msg = msgs[1]
            assert.equal(protocol.MSG_REQUEST, msg[1])
            assert.equal(10, msg[2])
            assert.equal("upload", msg[3])
            assert.equal("png", msg[4][1].format)
            assert.equal(100, msg[4][1].width)
        end)

        it("notification round-trips correctly", function()
            local encoded = protocol.encode_notification("register_win", {
                win_id = 5,
                scroll_top = 42,
            })
            local msgs, rem = protocol.decode(encoded)
            assert.equal(1, #msgs)
            local method, params = protocol.parse_notification(msgs[1])
            assert.equal("register_win", method)
            assert.equal(5, params.win_id)
            assert.equal(42, params.scroll_top)
        end)
    end)
end)

describe("kgd types", function()

    describe("Color", function()
        it("creates with defaults", function()
            local c = kgd.Color()
            assert.equal(0, c.r)
            assert.equal(0, c.g)
            assert.equal(0, c.b)
        end)

        it("creates with values", function()
            local c = kgd.Color(255, 128, 64)
            assert.equal(255, c.r)
            assert.equal(128, c.g)
            assert.equal(64, c.b)
        end)
    end)

    describe("Anchor", function()
        it("creates absolute anchor", function()
            local a = kgd.Anchor.absolute(5, 10)
            assert.equal("absolute", a.type)
            assert.equal(5, a.row)
            assert.equal(10, a.col)
        end)

        it("absolute anchor omits zero fields", function()
            local a = kgd.Anchor.absolute(0, 0)
            assert.equal("absolute", a.type)
            assert.is_nil(a.row)
            assert.is_nil(a.col)
        end)

        it("creates pane anchor", function()
            local a = kgd.Anchor.pane("%3", 2, 4)
            assert.equal("pane", a.type)
            assert.equal("%3", a.pane_id)
            assert.equal(2, a.row)
            assert.equal(4, a.col)
        end)

        it("creates win anchor", function()
            local a = kgd.Anchor.win(1001, 50, 3)
            assert.equal("win", a.type)
            assert.equal(1001, a.win_id)
            assert.equal(50, a.buf_line)
            assert.equal(3, a.col)
        end)

        it("from_table omits zero fields", function()
            local a = kgd.Anchor.from_table({
                type = "pane",
                pane_id = "%0",
                win_id = 0,
                buf_line = 0,
                row = 3,
                col = 0,
            })
            assert.equal("pane", a.type)
            assert.equal("%0", a.pane_id)
            assert.is_nil(a.win_id)
            assert.is_nil(a.buf_line)
            assert.equal(3, a.row)
            assert.is_nil(a.col)
        end)
    end)

    describe("Options", function()
        it("creates with defaults", function()
            local o = kgd.Options()
            assert.equal("", o.socket_path)
            assert.equal("", o.session_id)
            assert.equal("", o.client_type)
            assert.equal("", o.label)
            assert.is_true(o.auto_launch)
        end)

        it("creates with overrides", function()
            local o = kgd.Options({
                socket_path = "/tmp/test.sock",
                client_type = "myapp",
                auto_launch = false,
            })
            assert.equal("/tmp/test.sock", o.socket_path)
            assert.equal("myapp", o.client_type)
            assert.is_false(o.auto_launch)
        end)
    end)

    describe("method constants", function()
        it("has all 12 methods", function()
            assert.equal("hello", kgd.METHOD_HELLO)
            assert.equal("upload", kgd.METHOD_UPLOAD)
            assert.equal("place", kgd.METHOD_PLACE)
            assert.equal("unplace", kgd.METHOD_UNPLACE)
            assert.equal("unplace_all", kgd.METHOD_UNPLACE_ALL)
            assert.equal("free", kgd.METHOD_FREE)
            assert.equal("register_win", kgd.METHOD_REGISTER_WIN)
            assert.equal("update_scroll", kgd.METHOD_UPDATE_SCROLL)
            assert.equal("unregister_win", kgd.METHOD_UNREGISTER_WIN)
            assert.equal("list", kgd.METHOD_LIST)
            assert.equal("status", kgd.METHOD_STATUS)
            assert.equal("stop", kgd.METHOD_STOP)
        end)

        it("has all 4 notification names", function()
            assert.equal("evicted", kgd.NOTIFY_EVICTED)
            assert.equal("topology_changed", kgd.NOTIFY_TOPOLOGY_CHANGED)
            assert.equal("visibility_changed", kgd.NOTIFY_VISIBILITY_CHANGED)
            assert.equal("theme_changed", kgd.NOTIFY_THEME_CHANGED)
        end)
    end)
end)
