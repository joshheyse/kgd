/// Msgpack-RPC protocol encoding and decoding for kgd.
///
/// Wire format:
/// - Request:      [0, msgid, method, [params]]
/// - Response:     [1, msgid, error, result]
/// - Notification: [2, method, [params]]

import Foundation
import MessagePack

// MARK: - Message types

/// Msgpack-RPC message type tags.
enum MsgType: Int {
    case request = 0
    case response = 1
    case notification = 2
}

// MARK: - RPC method names

enum Method {
    static let hello = "hello"
    static let upload = "upload"
    static let place = "place"
    static let unplace = "unplace"
    static let unplaceAll = "unplace_all"
    static let free = "free"
    static let registerWin = "register_win"
    static let updateScroll = "update_scroll"
    static let unregisterWin = "unregister_win"
    static let list = "list"
    static let status = "status"
    static let stop = "stop"
}

// MARK: - Server notification names

enum Notification {
    static let evicted = "evicted"
    static let topologyChanged = "topology_changed"
    static let visibilityChanged = "visibility_changed"
    static let themeChanged = "theme_changed"
}

// MARK: - Parsed messages

/// A parsed response from the server.
struct RPCResponse {
    let msgID: UInt32
    let error: MessagePackValue
    let result: MessagePackValue
}

/// A parsed notification from the server.
struct RPCNotification {
    let method: String
    let params: MessagePackValue
}

/// A parsed incoming message.
enum IncomingMessage {
    case response(RPCResponse)
    case notification(RPCNotification)
}

// MARK: - Encoding

/// Encode a request message: [0, msgid, method, [params]]
func encodeRequest(msgID: UInt32, method: String, params: MessagePackValue?) -> Data {
    let paramsArray: MessagePackValue
    if let p = params {
        paramsArray = .array([p])
    } else {
        paramsArray = .array([])
    }
    let msg: MessagePackValue = .array([
        .uint(UInt64(MsgType.request.rawValue)),
        .uint(UInt64(msgID)),
        .string(method),
        paramsArray,
    ])
    return pack(msg)
}

/// Encode a notification message: [2, method, [params]]
func encodeNotification(method: String, params: MessagePackValue?) -> Data {
    let paramsArray: MessagePackValue
    if let p = params {
        paramsArray = .array([p])
    } else {
        paramsArray = .array([])
    }
    let msg: MessagePackValue = .array([
        .uint(UInt64(MsgType.notification.rawValue)),
        .string(method),
        paramsArray,
    ])
    return pack(msg)
}

// MARK: - Decoding

/// Errors during message parsing.
enum ProtocolError: Error, CustomStringConvertible {
    case malformedMessage(String)
    case unknownMessageType(Int)

    var description: String {
        switch self {
        case .malformedMessage(let detail):
            return "malformed message: \(detail)"
        case .unknownMessageType(let t):
            return "unknown message type: \(t)"
        }
    }
}

/// Parse a single msgpack value into an IncomingMessage.
func parseMessage(_ value: MessagePackValue) throws -> IncomingMessage {
    guard let arr = value.arrayValue, arr.count >= 3 else {
        throw ProtocolError.malformedMessage("expected array with at least 3 elements")
    }

    guard let typeVal = arr[0].int64Value ?? arr[0].uint64Value.map({ Int64($0) }) else {
        throw ProtocolError.malformedMessage("message type is not an integer")
    }

    let msgType = Int(typeVal)

    switch msgType {
    case MsgType.response.rawValue:
        guard arr.count >= 4 else {
            throw ProtocolError.malformedMessage("response needs 4 elements")
        }
        guard let msgID = arr[1].uint64Value ?? arr[1].int64Value.map({ UInt64($0) }) else {
            throw ProtocolError.malformedMessage("response msgid is not an integer")
        }
        return .response(RPCResponse(
            msgID: UInt32(msgID),
            error: arr[2],
            result: arr[3]
        ))

    case MsgType.notification.rawValue:
        guard let method = arr[1].stringValue else {
            throw ProtocolError.malformedMessage("notification method is not a string")
        }
        let params: MessagePackValue
        if arr.count >= 3, let paramsArr = arr[2].arrayValue, !paramsArr.isEmpty {
            params = paramsArr[0]
        } else {
            params = .nil
        }
        return .notification(RPCNotification(method: method, params: params))

    default:
        throw ProtocolError.unknownMessageType(msgType)
    }
}

// MARK: - Streaming decoder

/// Incrementally decodes msgpack values from a byte stream.
///
/// Feed data with `append(_:)`, then extract decoded values with `nextValue()`.
final class StreamDecoder {
    private var buffer = Data()

    /// Append received bytes.
    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Try to decode the next value from the buffer.
    /// Returns nil if there is not enough data yet.
    func nextValue() -> MessagePackValue? {
        guard !buffer.isEmpty else { return nil }
        do {
            let (value, remainder) = try unpack(buffer)
            buffer = Data(remainder)
            return value
        } catch {
            // Not enough data yet, or malformed -- wait for more.
            return nil
        }
    }
}
