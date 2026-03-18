/// Types for the kgd (Kitty Graphics Daemon) client protocol.

import Foundation
import MessagePack

// MARK: - Color

/// RGB color with 16-bit per channel precision.
public struct Color: Sendable, Equatable {
    public var r: UInt16
    public var g: UInt16
    public var b: UInt16

    public init(r: UInt16 = 0, g: UInt16 = 0, b: UInt16 = 0) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Decode from a msgpack map value.
    static func from(msgpack value: MessagePackValue) -> Color {
        guard let dict = value.dictionaryValue else { return Color() }
        return Color(
            r: UInt16(dict[.string("r")]?.uint16Value ?? 0),
            g: UInt16(dict[.string("g")]?.uint16Value ?? 0),
            b: UInt16(dict[.string("b")]?.uint16Value ?? 0)
        )
    }
}

// MARK: - Anchor

/// Describes a logical position for a placement.
public struct Anchor: Sendable, Equatable {
    public var type: String
    public var paneID: String
    public var winID: Int
    public var bufLine: Int
    public var row: Int
    public var col: Int

    public init(
        type: String = "absolute",
        paneID: String = "",
        winID: Int = 0,
        bufLine: Int = 0,
        row: Int = 0,
        col: Int = 0
    ) {
        self.type = type
        self.paneID = paneID
        self.winID = winID
        self.bufLine = bufLine
        self.row = row
        self.col = col
    }

    /// Serialize to a msgpack map, omitting zero-valued fields.
    func toMsgpack() -> MessagePackValue {
        var dict: [MessagePackValue: MessagePackValue] = [
            .string("type"): .string(type),
        ]
        if !paneID.isEmpty {
            dict[.string("pane_id")] = .string(paneID)
        }
        if winID != 0 {
            dict[.string("win_id")] = .int(Int64(winID))
        }
        if bufLine != 0 {
            dict[.string("buf_line")] = .int(Int64(bufLine))
        }
        if row != 0 {
            dict[.string("row")] = .int(Int64(row))
        }
        if col != 0 {
            dict[.string("col")] = .int(Int64(col))
        }
        return .map(dict)
    }

    /// Convert to a dictionary representation (for testing/inspection).
    public func toDictionary() -> [String: Any] {
        var d: [String: Any] = ["type": type]
        if !paneID.isEmpty { d["pane_id"] = paneID }
        if winID != 0 { d["win_id"] = winID }
        if bufLine != 0 { d["buf_line"] = bufLine }
        if row != 0 { d["row"] = row }
        if col != 0 { d["col"] = col }
        return d
    }
}

// MARK: - PlacementInfo

/// Describes a single active placement.
public struct PlacementInfo: Sendable, Equatable {
    public var placementID: Int
    public var clientID: String
    public var handle: Int
    public var visible: Bool
    public var row: Int
    public var col: Int

    public init(
        placementID: Int = 0,
        clientID: String = "",
        handle: Int = 0,
        visible: Bool = false,
        row: Int = 0,
        col: Int = 0
    ) {
        self.placementID = placementID
        self.clientID = clientID
        self.handle = handle
        self.visible = visible
        self.row = row
        self.col = col
    }

    /// Decode from a msgpack map value.
    static func from(msgpack value: MessagePackValue) -> PlacementInfo? {
        guard let dict = value.dictionaryValue else { return nil }
        return PlacementInfo(
            placementID: Int(dict[.string("placement_id")]?.int64Value ?? 0),
            clientID: dict[.string("client_id")]?.stringValue ?? "",
            handle: Int(dict[.string("handle")]?.int64Value ?? 0),
            visible: dict[.string("visible")]?.boolValue ?? false,
            row: Int(dict[.string("row")]?.int64Value ?? 0),
            col: Int(dict[.string("col")]?.int64Value ?? 0)
        )
    }
}

// MARK: - StatusResult

/// Daemon status information.
public struct StatusResult: Sendable, Equatable {
    public var clients: Int
    public var placements: Int
    public var images: Int
    public var cols: Int
    public var rows: Int

    public init(
        clients: Int = 0,
        placements: Int = 0,
        images: Int = 0,
        cols: Int = 0,
        rows: Int = 0
    ) {
        self.clients = clients
        self.placements = placements
        self.images = images
        self.cols = cols
        self.rows = rows
    }

    /// Decode from a msgpack map value.
    static func from(msgpack value: MessagePackValue) -> StatusResult {
        guard let dict = value.dictionaryValue else { return StatusResult() }
        return StatusResult(
            clients: Int(dict[.string("clients")]?.int64Value ?? 0),
            placements: Int(dict[.string("placements")]?.int64Value ?? 0),
            images: Int(dict[.string("images")]?.int64Value ?? 0),
            cols: Int(dict[.string("cols")]?.int64Value ?? 0),
            rows: Int(dict[.string("rows")]?.int64Value ?? 0)
        )
    }
}

// MARK: - Options

/// Options for connecting to the kgd daemon.
public struct Options: Sendable {
    public var socketPath: String
    public var sessionID: String
    public var clientType: String
    public var label: String
    public var autoLaunch: Bool

    public init(
        socketPath: String = "",
        sessionID: String = "",
        clientType: String = "",
        label: String = "",
        autoLaunch: Bool = true
    ) {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.clientType = clientType
        self.label = label
        self.autoLaunch = autoLaunch
    }
}

// MARK: - PlaceOptions

/// Optional source-crop and z-index parameters for the place method.
public struct PlaceOptions: Sendable {
    public var srcX: Int
    public var srcY: Int
    public var srcW: Int
    public var srcH: Int
    public var zIndex: Int

    public init(
        srcX: Int = 0,
        srcY: Int = 0,
        srcW: Int = 0,
        srcH: Int = 0,
        zIndex: Int = 0
    ) {
        self.srcX = srcX
        self.srcY = srcY
        self.srcW = srcW
        self.srcH = srcH
        self.zIndex = zIndex
    }
}

// MARK: - HelloResult

/// Result from the hello handshake.
public struct HelloResult: Sendable, Equatable {
    public var clientID: String
    public var cols: Int
    public var rows: Int
    public var cellWidth: Int
    public var cellHeight: Int
    public var inTmux: Bool
    public var fg: Color
    public var bg: Color

    public init(
        clientID: String = "",
        cols: Int = 0,
        rows: Int = 0,
        cellWidth: Int = 0,
        cellHeight: Int = 0,
        inTmux: Bool = false,
        fg: Color = Color(),
        bg: Color = Color()
    ) {
        self.clientID = clientID
        self.cols = cols
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.inTmux = inTmux
        self.fg = fg
        self.bg = bg
    }

    /// Decode from a msgpack map value.
    static func from(msgpack value: MessagePackValue) -> HelloResult {
        guard let dict = value.dictionaryValue else { return HelloResult() }
        let fg: Color
        if let fgVal = dict[.string("fg")] {
            fg = Color.from(msgpack: fgVal)
        } else {
            fg = Color()
        }
        let bg: Color
        if let bgVal = dict[.string("bg")] {
            bg = Color.from(msgpack: bgVal)
        } else {
            bg = Color()
        }
        return HelloResult(
            clientID: dict[.string("client_id")]?.stringValue ?? "",
            cols: Int(dict[.string("cols")]?.int64Value ?? 0),
            rows: Int(dict[.string("rows")]?.int64Value ?? 0),
            cellWidth: Int(dict[.string("cell_width")]?.int64Value ?? 0),
            cellHeight: Int(dict[.string("cell_height")]?.int64Value ?? 0),
            inTmux: dict[.string("in_tmux")]?.boolValue ?? false,
            fg: fg,
            bg: bg
        )
    }
}
