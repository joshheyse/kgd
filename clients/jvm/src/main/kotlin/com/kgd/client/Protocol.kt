package com.kgd.client

import org.msgpack.core.MessagePack
import org.msgpack.core.MessagePacker
import org.msgpack.core.MessageUnpacker
import org.msgpack.value.Value
import org.msgpack.value.ValueFactory
import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * msgpack-RPC message types.
 */
internal object MsgType {
    const val REQUEST = 0
    const val RESPONSE = 1
    const val NOTIFICATION = 2
}

/**
 * RPC method names.
 */
internal object Method {
    const val HELLO = "hello"
    const val UPLOAD = "upload"
    const val PLACE = "place"
    const val UNPLACE = "unplace"
    const val UNPLACE_ALL = "unplace_all"
    const val FREE = "free"
    const val REGISTER_WIN = "register_win"
    const val UPDATE_SCROLL = "update_scroll"
    const val UNREGISTER_WIN = "unregister_win"
    const val LIST = "list"
    const val STATUS = "status"
    const val STOP = "stop"
}

/**
 * Server-to-client notification names.
 */
internal object Notify {
    const val EVICTED = "evicted"
    const val TOPOLOGY_CHANGED = "topology_changed"
    const val VISIBILITY_CHANGED = "visibility_changed"
    const val THEME_CHANGED = "theme_changed"
}

/**
 * Represents a decoded msgpack-RPC message.
 */
internal sealed class RpcMessage {
    data class Response(val msgId: Int, val error: Value?, val result: Value?) : RpcMessage()
    data class Notification(val method: String, val params: List<Value>) : RpcMessage()
}

/**
 * Encodes msgpack-RPC request and notification messages.
 */
internal object Encoder {

    /**
     * Encode a request: `[0, msgid, method, [params]]`
     */
    fun encodeRequest(msgId: Int, method: String, params: Map<String, Any>?): ByteArray {
        val out = ByteArrayOutputStream()
        val packer = MessagePack.newDefaultPacker(out)
        packer.packArrayHeader(4)
        packer.packInt(MsgType.REQUEST)
        packer.packInt(msgId)
        packer.packString(method)
        if (params != null) {
            packer.packArrayHeader(1)
            packMap(packer, params)
        } else {
            packer.packArrayHeader(0)
        }
        packer.flush()
        return out.toByteArray()
    }

    /**
     * Encode a notification: `[2, method, [params]]`
     */
    fun encodeNotification(method: String, params: Map<String, Any>?): ByteArray {
        val out = ByteArrayOutputStream()
        val packer = MessagePack.newDefaultPacker(out)
        packer.packArrayHeader(3)
        packer.packInt(MsgType.NOTIFICATION)
        packer.packString(method)
        if (params != null) {
            packer.packArrayHeader(1)
            packMap(packer, params)
        } else {
            packer.packArrayHeader(0)
        }
        packer.flush()
        return out.toByteArray()
    }

    @Suppress("UNCHECKED_CAST")
    private fun packMap(packer: MessagePacker, map: Map<String, Any>) {
        packer.packMapHeader(map.size)
        for ((key, value) in map) {
            packer.packString(key)
            packValue(packer, value)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun packValue(packer: MessagePacker, value: Any) {
        when (value) {
            is Int -> packer.packInt(value)
            is Long -> packer.packLong(value)
            is Boolean -> packer.packBoolean(value)
            is String -> packer.packString(value)
            is ByteArray -> {
                packer.packBinaryHeader(value.size)
                packer.writePayload(value)
            }
            is Map<*, *> -> packMap(packer, value as Map<String, Any>)
            is List<*> -> {
                packer.packArrayHeader(value.size)
                for (item in value) {
                    if (item != null) packValue(packer, item)
                    else packer.packNil()
                }
            }
            else -> packer.packNil()
        }
    }
}

/**
 * Streaming decoder for msgpack-RPC messages from an [InputStream].
 *
 * Call [readMessage] in a loop to receive parsed [RpcMessage] objects.
 */
internal class Decoder(input: InputStream) {
    private val unpacker: MessageUnpacker = MessagePack.newDefaultUnpacker(input)

    /**
     * Read and decode the next msgpack-RPC message.
     * Returns null on EOF or if the message cannot be parsed.
     * Throws [java.io.IOException] on read errors.
     */
    fun readMessage(): RpcMessage? {
        if (!unpacker.hasNext()) return null

        val msg = unpacker.unpackValue()
        if (!msg.isArrayValue) return null
        val arr = msg.asArrayValue().list()
        if (arr.size < 3) return null

        return when (arr[0].asIntegerValue().toInt()) {
            MsgType.RESPONSE -> {
                if (arr.size < 4) return null
                val msgId = arr[1].asIntegerValue().toInt()
                val error = if (arr[2].isNilValue) null else arr[2]
                val result = if (arr[3].isNilValue) null else arr[3]
                RpcMessage.Response(msgId, error, result)
            }
            MsgType.NOTIFICATION -> {
                val method = arr[1].asStringValue().toString()
                val paramsVal = arr[2]
                val params = if (paramsVal.isArrayValue) paramsVal.asArrayValue().list() else emptyList()
                RpcMessage.Notification(method, params)
            }
            else -> null
        }
    }

    fun close() {
        unpacker.close()
    }
}

/**
 * Helpers to convert msgpack [Value] objects into Kotlin types.
 */
internal object ValueHelper {

    fun asMap(value: Value?): Map<String, Value> {
        if (value == null || !value.isMapValue) return emptyMap()
        return value.asMapValue().entrySet().associate { (k, v) ->
            k.asStringValue().toString() to v
        }
    }

    fun asString(value: Value?, default: String = ""): String {
        if (value == null || value.isNilValue) return default
        return value.asStringValue().toString()
    }

    fun asInt(value: Value?, default: Int = 0): Int {
        if (value == null || value.isNilValue) return default
        return value.asIntegerValue().toInt()
    }

    fun asLong(value: Value?, default: Long = 0L): Long {
        if (value == null || value.isNilValue) return default
        return value.asIntegerValue().toLong()
    }

    fun asBool(value: Value?, default: Boolean = false): Boolean {
        if (value == null || value.isNilValue) return default
        return value.asBooleanValue().boolean
    }

    fun asList(value: Value?): List<Value> {
        if (value == null || !value.isArrayValue) return emptyList()
        return value.asArrayValue().list()
    }

    fun colorFromMap(map: Map<String, Value>): Color {
        return Color(
            r = asInt(map["r"]),
            g = asInt(map["g"]),
            b = asInt(map["b"]),
        )
    }
}
