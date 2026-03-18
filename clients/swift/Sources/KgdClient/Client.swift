/// kgd client implementation using msgpack-RPC over Unix sockets.
///
/// Usage:
///
///     let client = try await KgdClient.connect(Options(clientType: "myapp"))
///     let handle = try await client.upload(data: imageData, format: "png", width: 800, height: 600)
///     let pid = try await client.place(handle: handle, anchor: Anchor(type: "absolute", row: 5, col: 10), width: 20, height: 15)
///     try await client.unplace(placementID: pid)
///     try await client.free(handle: handle)
///     client.close()

import Foundation
import MessagePack

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

/// Errors that can occur during kgd client operations.
public enum KgdError: Error, CustomStringConvertible {
    case socketNotFound(String)
    case connectionFailed(String)
    case daemonNotFound
    case launchTimeout
    case timeout(String)
    case connectionClosed
    case rpcError(String)
    case unexpectedResult(String)

    public var description: String {
        switch self {
        case .socketNotFound(let path): return "socket not found: \(path)"
        case .connectionFailed(let detail): return "connection failed: \(detail)"
        case .daemonNotFound: return "kgd not found in PATH"
        case .launchTimeout: return "timed out waiting for kgd to start"
        case .timeout(let method): return "RPC call \(method) timed out"
        case .connectionClosed: return "connection closed"
        case .rpcError(let msg): return "RPC error: \(msg)"
        case .unexpectedResult(let detail): return "unexpected result: \(detail)"
        }
    }
}

// MARK: - Notification callbacks

/// Callbacks for server-initiated notifications.
public struct NotificationCallbacks: Sendable {
    /// Called when an uploaded image is evicted from the cache. Parameter: handle.
    public var onEvicted: (@Sendable (Int) -> Void)?
    /// Called when the terminal topology changes. Parameters: cols, rows, cellWidth, cellHeight.
    public var onTopologyChanged: (@Sendable (Int, Int, Int, Int) -> Void)?
    /// Called when a placement's visibility changes. Parameters: placementID, visible.
    public var onVisibilityChanged: (@Sendable (Int, Bool) -> Void)?
    /// Called when the terminal theme changes. Parameters: fg, bg.
    public var onThemeChanged: (@Sendable (Color, Color) -> Void)?

    public init(
        onEvicted: (@Sendable (Int) -> Void)? = nil,
        onTopologyChanged: (@Sendable (Int, Int, Int, Int) -> Void)? = nil,
        onVisibilityChanged: (@Sendable (Int, Bool) -> Void)? = nil,
        onThemeChanged: (@Sendable (Color, Color) -> Void)? = nil
    ) {
        self.onEvicted = onEvicted
        self.onTopologyChanged = onTopologyChanged
        self.onVisibilityChanged = onVisibilityChanged
        self.onThemeChanged = onThemeChanged
    }
}

// MARK: - Connection state actor

/// Manages write serialization and pending response tracking.
private actor ConnectionState {
    private let fd: Int32
    private var nextID: UInt32 = 0
    private var pending: [UInt32: CheckedContinuation<MessagePackValue, Error>] = [:]
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Allocate the next message ID.
    func nextMsgID() -> UInt32 {
        let id = nextID
        nextID &+= 1
        return id
    }

    /// Register a pending continuation for a request.
    func registerPending(msgID: UInt32, continuation: CheckedContinuation<MessagePackValue, Error>) {
        pending[msgID] = continuation
    }

    /// Remove and return a pending continuation (used to prevent double-resume).
    func removePending(msgID: UInt32) -> CheckedContinuation<MessagePackValue, Error>? {
        return pending.removeValue(forKey: msgID)
    }

    /// Send raw bytes to the socket (serialized writes).
    func send(_ data: Data) throws {
        guard !closed else { throw KgdError.connectionClosed }
        try data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var totalSent = 0
            let count = buffer.count
            while totalSent < count {
                let sent = Darwin.write(fd, ptr.advanced(by: totalSent), count - totalSent)
                if sent < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw KgdError.connectionFailed("write failed: errno \(err)")
                }
                totalSent += sent
            }
        }
    }

    /// Resolve a pending request with a response.
    func resolveResponse(_ response: RPCResponse) {
        guard let continuation = pending.removeValue(forKey: response.msgID) else { return }
        if response.error != .nil {
            if let dict = response.error.dictionaryValue,
               let msg = dict[.string("message")]?.stringValue {
                continuation.resume(throwing: KgdError.rpcError(msg))
            } else if let msg = response.error.stringValue {
                continuation.resume(throwing: KgdError.rpcError(msg))
            } else {
                continuation.resume(throwing: KgdError.rpcError("\(response.error)"))
            }
        } else {
            continuation.resume(returning: response.result)
        }
    }

    /// Mark the connection as closed, failing all pending continuations.
    func markClosed() {
        closed = true
        let continuations = pending
        pending.removeAll()
        for (_, cont) in continuations {
            cont.resume(throwing: KgdError.connectionClosed)
        }
    }

    var isClosed: Bool { closed }
}

// MARK: - KgdClient

/// Async client for the kgd (Kitty Graphics Daemon).
///
/// All RPC methods use Swift structured concurrency (`async/await`).
/// Write serialization is handled by an internal actor.
/// A background `Task` runs the reader loop to dispatch responses and notifications.
public final class KgdClient: Sendable {
    private let fd: Int32
    private let state: ConnectionState
    private let readerTask: Task<Void, Never>
    private nonisolated(unsafe) var _callbacks = NotificationCallbacks()

    /// Hello result fields, populated after connect.
    public let hello: HelloResult

    /// Set notification callbacks. Must be set before any notifications arrive.
    public var callbacks: NotificationCallbacks {
        get { _callbacks }
        set { _callbacks = newValue }
    }

    private init(fd: Int32, state: ConnectionState, readerTask: Task<Void, Never>, hello: HelloResult) {
        self.fd = fd
        self.state = state
        self.readerTask = readerTask
        self.hello = hello
    }

    deinit {
        readerTask.cancel()
        Darwin.close(fd)
    }

    // MARK: - Connect

    /// Connect to the kgd daemon and perform the hello handshake.
    ///
    /// - Parameter opts: Connection options. Defaults to auto-launch with empty strings.
    /// - Returns: A connected `KgdClient` ready for use.
    public static func connect(_ opts: Options = Options()) async throws -> KgdClient {
        let socketPath = resolveSocketPath(opts.socketPath)

        if opts.autoLaunch {
            try ensureDaemon(socketPath: socketPath)
        }

        let fd = try connectUnixSocket(path: socketPath)
        let connState = ConnectionState(fd: fd)

        // Start the reader loop
        let decoder = StreamDecoder()
        // We need a holder for the callbacks reference since we don't have the client yet.
        // We'll use a class wrapper that the reader captures.
        let callbackHolder = CallbackHolder()

        let reader = Task {
            await readerLoop(fd: fd, state: connState, decoder: decoder, callbacks: callbackHolder)
        }

        // Perform hello handshake
        var helloParams: [MessagePackValue: MessagePackValue] = [
            .string("client_type"): .string(opts.clientType),
            .string("pid"): .int(Int64(ProcessInfo.processInfo.processIdentifier)),
            .string("label"): .string(opts.label),
        ]
        if !opts.sessionID.isEmpty {
            helloParams[.string("session_id")] = .string(opts.sessionID)
        }

        let result = try await call(
            state: connState,
            method: Method.hello,
            params: .map(helloParams),
            timeout: 10.0
        )

        let helloResult = HelloResult.from(msgpack: result)

        let client = KgdClient(fd: fd, state: connState, readerTask: reader, hello: helloResult)
        callbackHolder.client = client
        return client
    }

    // MARK: - RPC Methods (request/response)

    /// Upload image data and return a handle.
    ///
    /// - Parameters:
    ///   - data: Raw image bytes.
    ///   - format: Image format string (e.g. "png", "rgb", "rgba").
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: An opaque handle for the uploaded image.
    public func upload(data: Data, format: String, width: Int, height: Int) async throws -> Int {
        let params: MessagePackValue = .map([
            .string("data"): .binary(data),
            .string("format"): .string(format),
            .string("width"): .int(Int64(width)),
            .string("height"): .int(Int64(height)),
        ])
        let result = try await rpcCall(Method.upload, params: params)
        guard let dict = result.dictionaryValue,
              let handle = dict[.string("handle")]?.int64Value ?? dict[.string("handle")]?.uint64Value.map({ Int64($0) }) else {
            throw KgdError.unexpectedResult("upload: missing handle in result")
        }
        return Int(handle)
    }

    /// Place an image and return a placement ID.
    ///
    /// - Parameters:
    ///   - handle: Handle from a prior `upload` call.
    ///   - anchor: Logical placement position.
    ///   - width: Placement width in terminal cells.
    ///   - height: Placement height in terminal cells.
    ///   - options: Optional source-crop and z-index parameters.
    /// - Returns: A placement ID.
    public func place(
        handle: Int,
        anchor: Anchor,
        width: Int,
        height: Int,
        options: PlaceOptions = PlaceOptions()
    ) async throws -> Int {
        var dict: [MessagePackValue: MessagePackValue] = [
            .string("handle"): .int(Int64(handle)),
            .string("anchor"): anchor.toMsgpack(),
            .string("width"): .int(Int64(width)),
            .string("height"): .int(Int64(height)),
        ]
        if options.srcX != 0 { dict[.string("src_x")] = .int(Int64(options.srcX)) }
        if options.srcY != 0 { dict[.string("src_y")] = .int(Int64(options.srcY)) }
        if options.srcW != 0 { dict[.string("src_w")] = .int(Int64(options.srcW)) }
        if options.srcH != 0 { dict[.string("src_h")] = .int(Int64(options.srcH)) }
        if options.zIndex != 0 { dict[.string("z_index")] = .int(Int64(options.zIndex)) }

        let result = try await rpcCall(Method.place, params: .map(dict))
        guard let resultDict = result.dictionaryValue,
              let pid = resultDict[.string("placement_id")]?.int64Value ?? resultDict[.string("placement_id")]?.uint64Value.map({ Int64($0) }) else {
            throw KgdError.unexpectedResult("place: missing placement_id in result")
        }
        return Int(pid)
    }

    /// Remove a placement.
    ///
    /// - Parameter placementID: The placement ID to remove.
    public func unplace(placementID: Int) async throws {
        _ = try await rpcCall(Method.unplace, params: .map([
            .string("placement_id"): .int(Int64(placementID)),
        ]))
    }

    /// Release an uploaded image handle.
    ///
    /// - Parameter handle: The handle to free.
    public func free(handle: Int) async throws {
        _ = try await rpcCall(Method.free, params: .map([
            .string("handle"): .int(Int64(handle)),
        ]))
    }

    /// Return all active placements.
    public func list() async throws -> [PlacementInfo] {
        let result = try await rpcCall(Method.list, params: nil)
        guard let dict = result.dictionaryValue,
              let placements = dict[.string("placements")]?.arrayValue else {
            return []
        }
        return placements.compactMap { PlacementInfo.from(msgpack: $0) }
    }

    /// Return daemon status information.
    public func status() async throws -> StatusResult {
        let result = try await rpcCall(Method.status, params: nil)
        return StatusResult.from(msgpack: result)
    }

    // MARK: - RPC Methods (notifications / fire-and-forget)

    /// Remove all placements for this client.
    public func unplaceAll() async throws {
        try await rpcNotify(Method.unplaceAll, params: nil)
    }

    /// Register a neovim window geometry.
    public func registerWin(
        winID: Int,
        paneID: String = "",
        top: Int = 0,
        left: Int = 0,
        width: Int = 0,
        height: Int = 0,
        scrollTop: Int = 0
    ) async throws {
        try await rpcNotify(Method.registerWin, params: .map([
            .string("win_id"): .int(Int64(winID)),
            .string("pane_id"): .string(paneID),
            .string("top"): .int(Int64(top)),
            .string("left"): .int(Int64(left)),
            .string("width"): .int(Int64(width)),
            .string("height"): .int(Int64(height)),
            .string("scroll_top"): .int(Int64(scrollTop)),
        ]))
    }

    /// Update scroll position for a registered window.
    public func updateScroll(winID: Int, scrollTop: Int) async throws {
        try await rpcNotify(Method.updateScroll, params: .map([
            .string("win_id"): .int(Int64(winID)),
            .string("scroll_top"): .int(Int64(scrollTop)),
        ]))
    }

    /// Unregister a neovim window.
    public func unregisterWin(winID: Int) async throws {
        try await rpcNotify(Method.unregisterWin, params: .map([
            .string("win_id"): .int(Int64(winID)),
        ]))
    }

    /// Request the daemon to shut down.
    public func stop() async throws {
        try await rpcNotify(Method.stop, params: nil)
    }

    /// Close the connection.
    public func close() {
        readerTask.cancel()
        Darwin.close(fd)
        Task {
            await state.markClosed()
        }
    }

    // MARK: - Internal RPC helpers

    private func rpcCall(_ method: String, params: MessagePackValue?, timeout: TimeInterval = 10.0) async throws -> MessagePackValue {
        try await Self.call(state: state, method: method, params: params, timeout: timeout)
    }

    private static func call(
        state: ConnectionState,
        method: String,
        params: MessagePackValue?,
        timeout: TimeInterval
    ) async throws -> MessagePackValue {
        let msgID = await state.nextMsgID()
        let data = encodeRequest(msgID: msgID, method: method, params: params)

        return try await withThrowingTaskGroup(of: MessagePackValue.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await state.registerPending(msgID: msgID, continuation: continuation)
                        do {
                            try await state.send(data)
                        } catch {
                            // Remove from pending to prevent double-resume from markClosed().
                            if let cont = await state.removePending(msgID: msgID) {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw KgdError.timeout(method)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func rpcNotify(_ method: String, params: MessagePackValue?) async throws {
        let data = encodeNotification(method: method, params: params)
        try await state.send(data)
    }
}

// MARK: - Callback holder

/// Weak reference to the client for the reader loop to dispatch notifications.
/// This avoids a retain cycle between the reader Task and the client.
private final class CallbackHolder: @unchecked Sendable {
    weak var client: KgdClient?
}

// MARK: - Reader loop

/// Runs the reader loop, reading from the socket and dispatching responses/notifications.
private func readerLoop(
    fd: Int32,
    state: ConnectionState,
    decoder: StreamDecoder,
    callbacks: CallbackHolder
) async {
    let bufferSize = 65536
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
    defer { buffer.deallocate() }

    while !Task.isCancelled {
        let bytesRead = Darwin.read(fd, buffer, bufferSize)
        if bytesRead <= 0 {
            break
        }

        let data = Data(bytes: buffer, count: bytesRead)
        decoder.append(data)

        while let value = decoder.nextValue() {
            do {
                let msg = try parseMessage(value)
                switch msg {
                case .response(let response):
                    await state.resolveResponse(response)

                case .notification(let notification):
                    dispatchNotification(notification, callbacks: callbacks)
                }
            } catch {
                // Malformed message, skip it.
                continue
            }
        }
    }

    await state.markClosed()
}

// MARK: - Notification dispatch

private func dispatchNotification(_ notification: RPCNotification, callbacks: CallbackHolder) {
    guard let client = callbacks.client else { return }
    guard let dict = notification.params.dictionaryValue else { return }

    switch notification.method {
    case Notification.evicted:
        if let cb = client.callbacks.onEvicted,
           let handle = dict[.string("handle")]?.int64Value ?? dict[.string("handle")]?.uint64Value.map({ Int64($0) }) {
            cb(Int(handle))
        }

    case Notification.topologyChanged:
        if let cb = client.callbacks.onTopologyChanged {
            let cols = Int(dict[.string("cols")]?.int64Value ?? 0)
            let rows = Int(dict[.string("rows")]?.int64Value ?? 0)
            let cellWidth = Int(dict[.string("cell_width")]?.int64Value ?? 0)
            let cellHeight = Int(dict[.string("cell_height")]?.int64Value ?? 0)
            cb(cols, rows, cellWidth, cellHeight)
        }

    case Notification.visibilityChanged:
        if let cb = client.callbacks.onVisibilityChanged {
            let placementID = Int(dict[.string("placement_id")]?.int64Value ?? 0)
            let visible = dict[.string("visible")]?.boolValue ?? false
            cb(placementID, visible)
        }

    case Notification.themeChanged:
        if let cb = client.callbacks.onThemeChanged {
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
            cb(fg, bg)
        }

    default:
        break
    }
}

// MARK: - Socket path resolution

/// Resolve the socket path from options, environment, or default.
func resolveSocketPath(_ override: String) -> String {
    if !override.isEmpty { return override }

    if let envPath = ProcessInfo.processInfo.environment["KGD_SOCKET"], !envPath.isEmpty {
        return envPath
    }

    let runtimeDir: String
    if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdg.isEmpty {
        runtimeDir = xdg
    } else {
        runtimeDir = NSTemporaryDirectory()
    }

    let kittyID = ProcessInfo.processInfo.environment["KITTY_WINDOW_ID"] ?? "default"
    return (runtimeDir as NSString).appendingPathComponent("kgd-\(kittyID).sock")
}

// MARK: - Unix socket connection

/// Connect to a Unix domain socket at the given path.
func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw KgdError.connectionFailed("socket() failed: errno \(errno)")
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = path.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxLen else {
        Darwin.close(fd)
        throw KgdError.connectionFailed("socket path too long: \(path)")
    }

    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
            for i in 0..<pathBytes.count {
                dst[i] = pathBytes[i]
            }
        }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, addrLen)
        }
    }

    guard result == 0 else {
        let err = errno
        Darwin.close(fd)
        throw KgdError.connectionFailed("connect() failed for \(path): errno \(err)")
    }

    return fd
}

// MARK: - Daemon auto-launch

/// Ensure the daemon is running, launching it if necessary.
func ensureDaemon(socketPath: String) throws {
    // Try connecting to see if it's already running.
    let testFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard testFd >= 0 else { return }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
            for i in 0..<min(pathBytes.count, maxLen) {
                dst[i] = pathBytes[i]
            }
        }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(testFd, sockaddrPtr, addrLen)
        }
    }
    Darwin.close(testFd)

    if connected == 0 {
        // Already running.
        return
    }

    // Find kgd in PATH.
    guard let kgdPath = findInPath("kgd") else {
        throw KgdError.daemonNotFound
    }

    // Launch the daemon.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: kgdPath)
    process.arguments = ["serve", "--socket", socketPath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    // Start in a new session so it survives our exit.
    process.qualityOfService = .utility
    try process.run()

    // Wait for the socket to appear (up to 5 seconds).
    for _ in 0..<50 {
        Thread.sleep(forTimeInterval: 0.1)
        let checkFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard checkFd >= 0 else { continue }

        var checkAddr = sockaddr_un()
        checkAddr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &checkAddr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for i in 0..<min(pathBytes.count, maxLen) {
                    dst[i] = pathBytes[i]
                }
            }
        }

        let ok = withUnsafePointer(to: &checkAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(checkFd, sockaddrPtr, addrLen)
            }
        }
        Darwin.close(checkFd)

        if ok == 0 { return }
    }

    throw KgdError.launchTimeout
}

/// Search PATH for an executable.
private func findInPath(_ name: String) -> String? {
    guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for dir in pathEnv.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}
