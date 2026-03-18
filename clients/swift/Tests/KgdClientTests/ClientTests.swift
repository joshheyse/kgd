/// Tests for kgdclient types and protocol encoding.

import XCTest
import MessagePack
@testable import KgdClient

final class ClientTests: XCTestCase {

    // MARK: - Anchor tests

    func testAnchorAbsolute() {
        let a = Anchor(type: "absolute", row: 5, col: 10)
        let d = a.toDictionary()
        XCTAssertEqual(d["type"] as? String, "absolute")
        XCTAssertEqual(d["row"] as? Int, 5)
        XCTAssertEqual(d["col"] as? Int, 10)
        XCTAssertNil(d["pane_id"])
        XCTAssertNil(d["win_id"])
        XCTAssertNil(d["buf_line"])
    }

    func testAnchorPane() {
        let a = Anchor(type: "pane", paneID: "%0", row: 2, col: 3)
        let d = a.toDictionary()
        XCTAssertEqual(d["type"] as? String, "pane")
        XCTAssertEqual(d["pane_id"] as? String, "%0")
        XCTAssertEqual(d["row"] as? Int, 2)
        XCTAssertEqual(d["col"] as? Int, 3)
    }

    func testAnchorNvimWin() {
        let a = Anchor(type: "nvim_win", winID: 1000, bufLine: 5, col: 0)
        let d = a.toDictionary()
        XCTAssertEqual(d["type"] as? String, "nvim_win")
        XCTAssertEqual(d["win_id"] as? Int, 1000)
        XCTAssertEqual(d["buf_line"] as? Int, 5)
        // col=0 should be omitted
        XCTAssertNil(d["col"])
    }

    func testAnchorOmitsZeroFields() {
        let a = Anchor(type: "absolute")
        let d = a.toDictionary()
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d["type"] as? String, "absolute")
    }

    func testAnchorMsgpackRoundtrip() {
        let a = Anchor(type: "pane", paneID: "%1", row: 10, col: 20)
        let packed = a.toMsgpack()
        guard let dict = packed.dictionaryValue else {
            XCTFail("expected map")
            return
        }
        XCTAssertEqual(dict[.string("type")]?.stringValue, "pane")
        XCTAssertEqual(dict[.string("pane_id")]?.stringValue, "%1")
        XCTAssertEqual(dict[.string("row")]?.int64Value, 10)
        XCTAssertEqual(dict[.string("col")]?.int64Value, 20)
        // Zero fields should not be present
        XCTAssertNil(dict[.string("win_id")])
        XCTAssertNil(dict[.string("buf_line")])
    }

    // MARK: - Color tests

    func testColorDefaults() {
        let c = Color()
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
    }

    func testColorValues() {
        let c = Color(r: 65535, g: 32768, b: 0)
        XCTAssertEqual(c.r, 65535)
        XCTAssertEqual(c.g, 32768)
        XCTAssertEqual(c.b, 0)
    }

    func testColorFromMsgpack() {
        let value: MessagePackValue = .map([
            .string("r"): .int(255),
            .string("g"): .int(128),
            .string("b"): .int(64),
        ])
        let c = Color.from(msgpack: value)
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 128)
        XCTAssertEqual(c.b, 64)
    }

    func testColorFromMsgpackMissingFields() {
        let value: MessagePackValue = .map([:])
        let c = Color.from(msgpack: value)
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
    }

    // MARK: - PlacementInfo tests

    func testPlacementInfoFromMsgpack() {
        let value: MessagePackValue = .map([
            .string("placement_id"): .int(42),
            .string("client_id"): .string("abc-123"),
            .string("handle"): .int(7),
            .string("visible"): .bool(true),
            .string("row"): .int(5),
            .string("col"): .int(10),
        ])
        let p = PlacementInfo.from(msgpack: value)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.placementID, 42)
        XCTAssertEqual(p?.clientID, "abc-123")
        XCTAssertEqual(p?.handle, 7)
        XCTAssertEqual(p?.visible, true)
        XCTAssertEqual(p?.row, 5)
        XCTAssertEqual(p?.col, 10)
    }

    func testPlacementInfoFromInvalidMsgpack() {
        let value: MessagePackValue = .string("not a map")
        XCTAssertNil(PlacementInfo.from(msgpack: value))
    }

    // MARK: - StatusResult tests

    func testStatusResultFromMsgpack() {
        let value: MessagePackValue = .map([
            .string("clients"): .int(3),
            .string("placements"): .int(10),
            .string("images"): .int(5),
            .string("cols"): .int(80),
            .string("rows"): .int(24),
        ])
        let s = StatusResult.from(msgpack: value)
        XCTAssertEqual(s.clients, 3)
        XCTAssertEqual(s.placements, 10)
        XCTAssertEqual(s.images, 5)
        XCTAssertEqual(s.cols, 80)
        XCTAssertEqual(s.rows, 24)
    }

    func testStatusResultDefaults() {
        let s = StatusResult()
        XCTAssertEqual(s.clients, 0)
        XCTAssertEqual(s.placements, 0)
        XCTAssertEqual(s.images, 0)
        XCTAssertEqual(s.cols, 0)
        XCTAssertEqual(s.rows, 0)
    }

    // MARK: - HelloResult tests

    func testHelloResultFromMsgpack() {
        let value: MessagePackValue = .map([
            .string("client_id"): .string("uuid-here"),
            .string("cols"): .int(120),
            .string("rows"): .int(40),
            .string("cell_width"): .int(8),
            .string("cell_height"): .int(16),
            .string("in_tmux"): .bool(true),
            .string("fg"): .map([
                .string("r"): .int(65535),
                .string("g"): .int(65535),
                .string("b"): .int(65535),
            ]),
            .string("bg"): .map([
                .string("r"): .int(0),
                .string("g"): .int(0),
                .string("b"): .int(0),
            ]),
        ])
        let h = HelloResult.from(msgpack: value)
        XCTAssertEqual(h.clientID, "uuid-here")
        XCTAssertEqual(h.cols, 120)
        XCTAssertEqual(h.rows, 40)
        XCTAssertEqual(h.cellWidth, 8)
        XCTAssertEqual(h.cellHeight, 16)
        XCTAssertTrue(h.inTmux)
        XCTAssertEqual(h.fg, Color(r: 65535, g: 65535, b: 65535))
        XCTAssertEqual(h.bg, Color(r: 0, g: 0, b: 0))
    }

    // MARK: - Protocol encoding tests

    func testEncodeRequestWithParams() {
        let params: MessagePackValue = .map([
            .string("client_type"): .string("test"),
            .string("pid"): .int(1234),
        ])
        let data = encodeRequest(msgID: 1, method: "hello", params: params)
        // Decode and verify structure
        let value = try! unpackFirst(data)
        guard let arr = value.arrayValue else {
            XCTFail("expected array")
            return
        }
        XCTAssertEqual(arr.count, 4)
        XCTAssertEqual(arr[0].uint64Value, 0) // request type
        XCTAssertEqual(arr[1].uint64Value, 1) // msgid
        XCTAssertEqual(arr[2].stringValue, "hello") // method
        // params should be an array with one element (the map)
        guard let paramsArr = arr[3].arrayValue else {
            XCTFail("expected params array")
            return
        }
        XCTAssertEqual(paramsArr.count, 1)
        XCTAssertNotNil(paramsArr[0].dictionaryValue)
    }

    func testEncodeRequestWithoutParams() {
        let data = encodeRequest(msgID: 5, method: "status", params: nil)
        let value = try! unpackFirst(data)
        guard let arr = value.arrayValue else {
            XCTFail("expected array")
            return
        }
        XCTAssertEqual(arr.count, 4)
        XCTAssertEqual(arr[0].uint64Value, 0)
        XCTAssertEqual(arr[1].uint64Value, 5)
        XCTAssertEqual(arr[2].stringValue, "status")
        guard let paramsArr = arr[3].arrayValue else {
            XCTFail("expected params array")
            return
        }
        XCTAssertEqual(paramsArr.count, 0) // empty params
    }

    func testEncodeNotificationWithParams() {
        let params: MessagePackValue = .map([
            .string("win_id"): .int(42),
        ])
        let data = encodeNotification(method: "unregister_win", params: params)
        let value = try! unpackFirst(data)
        guard let arr = value.arrayValue else {
            XCTFail("expected array")
            return
        }
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0].uint64Value, 2) // notification type
        XCTAssertEqual(arr[1].stringValue, "unregister_win")
        guard let paramsArr = arr[2].arrayValue else {
            XCTFail("expected params array")
            return
        }
        XCTAssertEqual(paramsArr.count, 1)
    }

    func testEncodeNotificationWithoutParams() {
        let data = encodeNotification(method: "stop", params: nil)
        let value = try! unpackFirst(data)
        guard let arr = value.arrayValue else {
            XCTFail("expected array")
            return
        }
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0].uint64Value, 2)
        XCTAssertEqual(arr[1].stringValue, "stop")
        guard let paramsArr = arr[2].arrayValue else {
            XCTFail("expected params array")
            return
        }
        XCTAssertEqual(paramsArr.count, 0)
    }

    // MARK: - Protocol parsing tests

    func testParseResponseOk() throws {
        let msg: MessagePackValue = .array([
            .int(1), // response
            .uint(3), // msgid
            .nil, // no error
            .map([.string("handle"): .int(42)]), // result
        ])
        let parsed = try parseMessage(msg)
        guard case .response(let resp) = parsed else {
            XCTFail("expected response")
            return
        }
        XCTAssertEqual(resp.msgID, 3)
        XCTAssertTrue(resp.error.isNil)
        XCTAssertEqual(resp.result.dictionaryValue?[.string("handle")]?.int64Value, 42)
    }

    func testParseResponseError() throws {
        let msg: MessagePackValue = .array([
            .int(1),
            .uint(7),
            .map([.string("message"): .string("not found")]),
            .nil,
        ])
        let parsed = try parseMessage(msg)
        guard case .response(let resp) = parsed else {
            XCTFail("expected response")
            return
        }
        XCTAssertEqual(resp.msgID, 7)
        XCTAssertFalse(resp.error.isNil)
        XCTAssertEqual(resp.error.dictionaryValue?[.string("message")]?.stringValue, "not found")
    }

    func testParseNotification() throws {
        let msg: MessagePackValue = .array([
            .int(2), // notification
            .string("evicted"),
            .array([.map([.string("handle"): .int(99)])]),
        ])
        let parsed = try parseMessage(msg)
        guard case .notification(let notif) = parsed else {
            XCTFail("expected notification")
            return
        }
        XCTAssertEqual(notif.method, "evicted")
        XCTAssertEqual(notif.params.dictionaryValue?[.string("handle")]?.int64Value, 99)
    }

    func testParseInvalidMessage() {
        let msg: MessagePackValue = .string("not an array")
        XCTAssertThrowsError(try parseMessage(msg))
    }

    func testParseUnknownType() {
        let msg: MessagePackValue = .array([.int(9), .string("x"), .array([])])
        XCTAssertThrowsError(try parseMessage(msg))
    }

    // MARK: - StreamDecoder tests

    func testStreamDecoderSingleMessage() {
        let decoder = StreamDecoder()
        let value: MessagePackValue = .array([.int(1), .uint(0), .nil, .string("ok")])
        let data = pack(value)
        decoder.append(data)
        let decoded = decoder.nextValue()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.arrayValue?.count, 4)
        // No more values
        XCTAssertNil(decoder.nextValue())
    }

    func testStreamDecoderMultipleMessages() {
        let decoder = StreamDecoder()
        let v1: MessagePackValue = .array([.int(1), .uint(0), .nil, .int(1)])
        let v2: MessagePackValue = .array([.int(1), .uint(1), .nil, .int(2)])
        var data = pack(v1)
        data.append(pack(v2))
        decoder.append(data)

        let d1 = decoder.nextValue()
        XCTAssertNotNil(d1)
        XCTAssertEqual(d1?.arrayValue?[1].uint64Value, 0)

        let d2 = decoder.nextValue()
        XCTAssertNotNil(d2)
        XCTAssertEqual(d2?.arrayValue?[1].uint64Value, 1)

        XCTAssertNil(decoder.nextValue())
    }

    func testStreamDecoderPartialData() {
        let decoder = StreamDecoder()
        let value: MessagePackValue = .array([.int(1), .uint(0), .nil, .string("hello")])
        let data = pack(value)

        // Feed only half the data
        let half = data.count / 2
        decoder.append(data.prefix(half))
        XCTAssertNil(decoder.nextValue()) // not enough data

        // Feed the rest
        decoder.append(data.suffix(from: half))
        let decoded = decoder.nextValue()
        XCTAssertNotNil(decoded)
    }

    // MARK: - Socket path resolution tests

    func testResolveSocketPathOverride() {
        let path = resolveSocketPath("/custom/path.sock")
        XCTAssertEqual(path, "/custom/path.sock")
    }

    // MARK: - Options tests

    func testOptionsDefaults() {
        let opts = Options()
        XCTAssertEqual(opts.socketPath, "")
        XCTAssertEqual(opts.sessionID, "")
        XCTAssertEqual(opts.clientType, "")
        XCTAssertEqual(opts.label, "")
        XCTAssertTrue(opts.autoLaunch)
    }

    func testOptionsCustom() {
        let opts = Options(
            socketPath: "/tmp/test.sock",
            sessionID: "sess-1",
            clientType: "test",
            label: "my-label",
            autoLaunch: false
        )
        XCTAssertEqual(opts.socketPath, "/tmp/test.sock")
        XCTAssertEqual(opts.sessionID, "sess-1")
        XCTAssertEqual(opts.clientType, "test")
        XCTAssertEqual(opts.label, "my-label")
        XCTAssertFalse(opts.autoLaunch)
    }

    // MARK: - PlaceOptions tests

    func testPlaceOptionsDefaults() {
        let opts = PlaceOptions()
        XCTAssertEqual(opts.srcX, 0)
        XCTAssertEqual(opts.srcY, 0)
        XCTAssertEqual(opts.srcW, 0)
        XCTAssertEqual(opts.srcH, 0)
        XCTAssertEqual(opts.zIndex, 0)
    }
}
