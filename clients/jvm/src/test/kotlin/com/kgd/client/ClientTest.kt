package com.kgd.client

import org.msgpack.core.MessagePack
import org.msgpack.value.ValueFactory
import java.io.ByteArrayInputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AnchorTest {

    @Test
    fun `absolute anchor with row and col`() {
        val a = Anchor.absolute(row = 5, col = 10)
        assertEquals(mapOf("type" to "absolute", "row" to 5, "col" to 10), a.toMap())
    }

    @Test
    fun `pane anchor`() {
        val a = Anchor.pane(paneId = "%0", row = 2, col = 3)
        assertEquals(
            mapOf("type" to "pane", "pane_id" to "%0", "row" to 2, "col" to 3),
            a.toMap(),
        )
    }

    @Test
    fun `nvim win anchor`() {
        val a = Anchor.nvimWin(winId = 1000, bufLine = 5, col = 0)
        assertEquals(
            mapOf("type" to "nvim_win", "win_id" to 1000, "buf_line" to 5),
            a.toMap(),
        )
    }

    @Test
    fun `absolute anchor omits zero fields`() {
        val a = Anchor.absolute()
        assertEquals(mapOf<String, Any>("type" to "absolute"), a.toMap())
    }

    @Test
    fun `sealed class variants are distinct`() {
        val abs = Anchor.absolute(row = 1)
        val pane = Anchor.pane(paneId = "%0")
        val nvim = Anchor.nvimWin(winId = 1)
        assertTrue(abs is Anchor.Absolute)
        assertTrue(pane is Anchor.Pane)
        assertTrue(nvim is Anchor.NvimWin)
    }
}

class ColorTest {

    @Test
    fun `default color is all zeros`() {
        val c = Color()
        assertEquals(0, c.r)
        assertEquals(0, c.g)
        assertEquals(0, c.b)
    }

    @Test
    fun `color with values`() {
        val c = Color(r = 65535, g = 32768, b = 0)
        assertEquals(65535, c.r)
        assertEquals(32768, c.g)
        assertEquals(0, c.b)
    }
}

class TypesTest {

    @Test
    fun `placement info defaults`() {
        val p = PlacementInfo()
        assertEquals(0L, p.placementId)
        assertEquals("", p.clientId)
        assertEquals(0L, p.handle)
        assertEquals(false, p.visible)
        assertEquals(0, p.row)
        assertEquals(0, p.col)
    }

    @Test
    fun `status result defaults`() {
        val s = StatusResult()
        assertEquals(0, s.clients)
        assertEquals(0, s.placements)
        assertEquals(0, s.images)
        assertEquals(0, s.cols)
        assertEquals(0, s.rows)
    }

    @Test
    fun `options defaults`() {
        val o = Options()
        assertEquals("", o.socketPath)
        assertEquals("", o.sessionId)
        assertEquals("", o.clientType)
        assertEquals("", o.label)
        assertEquals(true, o.autoLaunch)
    }

    @Test
    fun `place opts defaults`() {
        val o = PlaceOpts()
        assertEquals(0, o.srcX)
        assertEquals(0, o.srcY)
        assertEquals(0, o.srcW)
        assertEquals(0, o.srcH)
        assertEquals(0, o.zIndex)
    }
}

class ProtocolTest {

    @Test
    fun `encode request with params`() {
        val data = Encoder.encodeRequest(1, "hello", mapOf("client_type" to "test", "pid" to 42))
        val unpacker = MessagePack.newDefaultUnpacker(data)
        val msg = unpacker.unpackValue().asArrayValue().list()

        assertEquals(4, msg.size)
        assertEquals(0, msg[0].asIntegerValue().toInt()) // REQUEST type
        assertEquals(1, msg[1].asIntegerValue().toInt()) // msgid
        assertEquals("hello", msg[2].asStringValue().toString()) // method

        val paramsArr = msg[3].asArrayValue().list()
        assertEquals(1, paramsArr.size)
        val paramsMap = paramsArr[0].asMapValue().entrySet().associate {
            it.key.asStringValue().toString() to it.value
        }
        assertEquals("test", paramsMap["client_type"]!!.asStringValue().toString())
        assertEquals(42, paramsMap["pid"]!!.asIntegerValue().toInt())
    }

    @Test
    fun `encode request without params`() {
        val data = Encoder.encodeRequest(0, "list", null)
        val unpacker = MessagePack.newDefaultUnpacker(data)
        val msg = unpacker.unpackValue().asArrayValue().list()

        assertEquals(4, msg.size)
        assertEquals(0, msg[0].asIntegerValue().toInt())
        assertEquals("list", msg[2].asStringValue().toString())
        assertEquals(0, msg[3].asArrayValue().list().size) // empty params array
    }

    @Test
    fun `encode notification with params`() {
        val data = Encoder.encodeNotification("stop", null)
        val unpacker = MessagePack.newDefaultUnpacker(data)
        val msg = unpacker.unpackValue().asArrayValue().list()

        assertEquals(3, msg.size)
        assertEquals(2, msg[0].asIntegerValue().toInt()) // NOTIFICATION type
        assertEquals("stop", msg[1].asStringValue().toString())
        assertEquals(0, msg[2].asArrayValue().list().size)
    }

    @Test
    fun `encode notification with dict params`() {
        val data = Encoder.encodeNotification("update_scroll", mapOf("win_id" to 5, "scroll_top" to 100))
        val unpacker = MessagePack.newDefaultUnpacker(data)
        val msg = unpacker.unpackValue().asArrayValue().list()

        assertEquals(3, msg.size)
        assertEquals(2, msg[0].asIntegerValue().toInt())
        val paramsArr = msg[2].asArrayValue().list()
        assertEquals(1, paramsArr.size)
        val m = paramsArr[0].asMapValue().entrySet().associate {
            it.key.asStringValue().toString() to it.value.asIntegerValue().toInt()
        }
        assertEquals(5, m["win_id"])
        assertEquals(100, m["scroll_top"])
    }

    @Test
    fun `encode request with binary data`() {
        val imageData = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47)
        val data = Encoder.encodeRequest(0, "upload", mapOf(
            "data" to imageData,
            "format" to "png",
            "width" to 100,
            "height" to 200,
        ))
        val unpacker = MessagePack.newDefaultUnpacker(data)
        val msg = unpacker.unpackValue().asArrayValue().list()
        val paramsMap = msg[3].asArrayValue().list()[0].asMapValue().entrySet().associate {
            it.key.asStringValue().toString() to it.value
        }
        val decoded = paramsMap["data"]!!.asBinaryValue().asByteArray()
        assertTrue(imageData.contentEquals(decoded))
    }

    @Test
    fun `encode request with nested map (anchor)`() {
        val anchor = mapOf("type" to "absolute", "row" to 5, "col" to 10)
        val data = Encoder.encodeRequest(0, "place", mapOf(
            "handle" to 1L,
            "anchor" to anchor,
            "width" to 20,
            "height" to 15,
        ))
        val unpacker = MessagePack.newDefaultUnpacker(data)
        val msg = unpacker.unpackValue().asArrayValue().list()
        val paramsMap = msg[3].asArrayValue().list()[0].asMapValue().entrySet().associate {
            it.key.asStringValue().toString() to it.value
        }
        val anchorMap = paramsMap["anchor"]!!.asMapValue().entrySet().associate {
            it.key.asStringValue().toString() to it.value
        }
        assertEquals("absolute", anchorMap["type"]!!.asStringValue().toString())
        assertEquals(5, anchorMap["row"]!!.asIntegerValue().toInt())
        assertEquals(10, anchorMap["col"]!!.asIntegerValue().toInt())
    }

    @Test
    fun `decode response message`() {
        // Manually encode a response: [1, 42, nil, {"handle": 7}]
        val out = java.io.ByteArrayOutputStream()
        val packer = MessagePack.newDefaultPacker(out)
        packer.packArrayHeader(4)
        packer.packInt(MsgType.RESPONSE)
        packer.packInt(42)
        packer.packNil()
        packer.packMapHeader(1)
        packer.packString("handle")
        packer.packInt(7)
        packer.flush()

        val decoder = Decoder(ByteArrayInputStream(out.toByteArray()))
        val msg = decoder.readMessage()
        assertTrue(msg is RpcMessage.Response)
        assertEquals(42, msg.msgId)
        assertNull(msg.error)
        val result = ValueHelper.asMap(msg.result)
        assertEquals(7, ValueHelper.asInt(result["handle"]))
    }

    @Test
    fun `decode response with error`() {
        val out = java.io.ByteArrayOutputStream()
        val packer = MessagePack.newDefaultPacker(out)
        packer.packArrayHeader(4)
        packer.packInt(MsgType.RESPONSE)
        packer.packInt(1)
        packer.packMapHeader(1)
        packer.packString("message")
        packer.packString("not found")
        packer.packNil()
        packer.flush()

        val decoder = Decoder(ByteArrayInputStream(out.toByteArray()))
        val msg = decoder.readMessage()
        assertTrue(msg is RpcMessage.Response)
        assertEquals(1, msg.msgId)
        val errMap = ValueHelper.asMap(msg.error)
        assertEquals("not found", ValueHelper.asString(errMap["message"]))
    }

    @Test
    fun `decode notification message`() {
        val out = java.io.ByteArrayOutputStream()
        val packer = MessagePack.newDefaultPacker(out)
        packer.packArrayHeader(3)
        packer.packInt(MsgType.NOTIFICATION)
        packer.packString("evicted")
        packer.packArrayHeader(1)
        packer.packMapHeader(1)
        packer.packString("handle")
        packer.packInt(99)
        packer.flush()

        val decoder = Decoder(ByteArrayInputStream(out.toByteArray()))
        val msg = decoder.readMessage()
        assertTrue(msg is RpcMessage.Notification)
        assertEquals("evicted", msg.method)
        assertEquals(1, msg.params.size)
        val p = ValueHelper.asMap(msg.params[0])
        assertEquals(99, ValueHelper.asInt(p["handle"]))
    }

    @Test
    fun `decode returns null on EOF`() {
        val decoder = Decoder(ByteArrayInputStream(byteArrayOf()))
        assertNull(decoder.readMessage())
    }

    @Test
    fun `decode multiple messages from stream`() {
        val out = java.io.ByteArrayOutputStream()
        val packer = MessagePack.newDefaultPacker(out)

        // First message: response
        packer.packArrayHeader(4)
        packer.packInt(MsgType.RESPONSE)
        packer.packInt(0)
        packer.packNil()
        packer.packMapHeader(1)
        packer.packString("ok")
        packer.packBoolean(true)

        // Second message: notification
        packer.packArrayHeader(3)
        packer.packInt(MsgType.NOTIFICATION)
        packer.packString("evicted")
        packer.packArrayHeader(1)
        packer.packMapHeader(1)
        packer.packString("handle")
        packer.packInt(5)

        packer.flush()

        val decoder = Decoder(ByteArrayInputStream(out.toByteArray()))

        val msg1 = decoder.readMessage()
        assertTrue(msg1 is RpcMessage.Response)
        assertEquals(0, msg1.msgId)

        val msg2 = decoder.readMessage()
        assertTrue(msg2 is RpcMessage.Notification)
        assertEquals("evicted", msg2.method)

        assertNull(decoder.readMessage())
    }
}

class ValueHelperTest {

    @Test
    fun `asMap handles nil`() {
        assertEquals(emptyMap(), ValueHelper.asMap(null))
    }

    @Test
    fun `asString handles nil`() {
        assertEquals("", ValueHelper.asString(null))
        assertEquals("fallback", ValueHelper.asString(null, "fallback"))
    }

    @Test
    fun `asInt handles nil`() {
        assertEquals(0, ValueHelper.asInt(null))
        assertEquals(42, ValueHelper.asInt(null, 42))
    }

    @Test
    fun `asBool handles nil`() {
        assertEquals(false, ValueHelper.asBool(null))
    }

    @Test
    fun `colorFromMap`() {
        val map = mapOf(
            "r" to ValueFactory.newInteger(65535),
            "g" to ValueFactory.newInteger(32768),
            "b" to ValueFactory.newInteger(0),
        )
        val c = ValueHelper.colorFromMap(map)
        assertEquals(65535, c.r)
        assertEquals(32768, c.g)
        assertEquals(0, c.b)
    }

    @Test
    fun `colorFromMap with missing keys`() {
        val c = ValueHelper.colorFromMap(emptyMap())
        assertEquals(Color(), c)
    }
}

class SocketPathTest {

    @Test
    fun `explicit path takes precedence`() {
        assertEquals("/my/path.sock", KgdClient.resolveSocketPath("/my/path.sock"))
    }

    @Test
    fun `empty explicit falls through`() {
        // This will use env vars, just verify it doesn't crash
        val path = KgdClient.resolveSocketPath("")
        assertTrue(path.isNotEmpty())
    }
}
