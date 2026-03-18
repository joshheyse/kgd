/// client.zig -- kgd (Kitty Graphics Daemon) Zig client.
///
/// Usage:
///   var client = try Client.connect(allocator, .{ .client_type = "myapp" });
///   defer client.close();
///   const handle = try client.upload(image_data, "png", 100, 80);
///   const pid = try client.place(handle, .{ .type = .absolute, .row = 5, .col = 10 }, 20, 15, null);
///   try client.unplace(pid);
///   try client.free(handle);
const std = @import("std");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

pub const Encoder = protocol.Encoder;
pub const Decoder = protocol.Decoder;
pub const Value = protocol.Value;

pub const Color = types.Color;
pub const AnchorType = types.AnchorType;
pub const Anchor = types.Anchor;
pub const PlaceOpts = types.PlaceOpts;
pub const PlacementInfo = types.PlacementInfo;
pub const StatusResult = types.StatusResult;
pub const HelloResult = types.HelloResult;
pub const Options = types.Options;
pub const EvictedCallback = types.EvictedCallback;
pub const TopologyCallback = types.TopologyCallback;
pub const VisibilityCallback = types.VisibilityCallback;
pub const ThemeCallback = types.ThemeCallback;

// msgpack-rpc message types
const MSG_REQUEST: u64 = 0;
const MSG_RESPONSE: u64 = 1;
const MSG_NOTIFICATION: u64 = 2;

pub const Error = error{
    ConnectFailed,
    HelloFailed,
    SendFailed,
    RecvFailed,
    DecodeFailed,
    RpcError,
    Timeout,
    ConnectionClosed,
    InvalidResponse,
    OutOfMemory,
    SocketPathNotFound,
};

/// Pending RPC call slot.
const PendingCall = struct {
    active: bool = false,
    done: bool = false,
    has_error: bool = false,
    err_msg: ?[]const u8 = null,
    result_data: ?[]const u8 = null,
    event: std.Thread.ResetEvent = .{},
};

const MAX_PENDING = 64;
const RECV_BUF_SIZE = 65536;

pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: std.posix.socket_t,
    write_mutex: std.Thread.Mutex = .{},
    next_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pending: [MAX_PENDING]PendingCall = [_]PendingCall{.{}} ** MAX_PENDING,
    pending_mutex: std.Thread.Mutex = .{},

    reader_thread: ?std.Thread = null,

    /// Hello result fields.
    hello: HelloResult = .{},

    /// Owned copy of the client_id string (allocated).
    client_id_buf: ?[]u8 = null,

    /// Notification callbacks.
    on_evicted: ?EvictedCallback = null,
    on_evicted_userdata: ?*anyopaque = null,
    on_topology: ?TopologyCallback = null,
    on_topology_userdata: ?*anyopaque = null,
    on_visibility: ?VisibilityCallback = null,
    on_visibility_userdata: ?*anyopaque = null,
    on_theme: ?ThemeCallback = null,
    on_theme_userdata: ?*anyopaque = null,

    /// Connect to the kgd daemon and perform the hello handshake.
    pub fn connect(allocator: std.mem.Allocator, opts: Options) Error!*Client {
        const resolved = resolveSocketPath(allocator, opts.socket_path) catch return Error.SocketPathNotFound;
        defer if (resolved.allocated) allocator.free(resolved.path);
        const socket_path = resolved.path;

        const fd = connectUnix(socket_path) catch return Error.ConnectFailed;
        errdefer std.posix.close(fd);

        const client = allocator.create(Client) catch return Error.OutOfMemory;
        client.* = .{
            .allocator = allocator,
            .fd = fd,
        };

        // Start reader thread.
        client.reader_thread = std.Thread.spawn(.{}, readLoop, .{client}) catch {
            allocator.destroy(client);
            return Error.ConnectFailed;
        };

        // Send hello.
        const hello_result = client.doHello(opts) catch |err| {
            client.close();
            return err;
        };
        _ = hello_result;

        return client;
    }

    /// Close the connection and release resources.
    pub fn close(self: *Client) void {
        self.closed.store(true, .release);

        // Shut down the socket to unblock the reader.
        std.posix.shutdown(self.fd, .both) catch {};
        std.posix.close(self.fd);

        // Join reader thread.
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }

        // Wake any pending calls.
        self.pending_mutex.lock();
        for (&self.pending) |*p| {
            if (p.active) {
                p.done = true;
                p.event.set();
            }
            if (p.result_data) |d| {
                self.allocator.free(d);
                p.result_data = null;
            }
            if (p.err_msg) |e| {
                self.allocator.free(e);
                p.err_msg = null;
            }
        }
        self.pending_mutex.unlock();

        if (self.client_id_buf) |buf| {
            self.allocator.free(buf);
        }

        self.allocator.destroy(self);
    }

    /// Set the evicted notification callback.
    pub fn setEvictedCallback(self: *Client, cb: ?EvictedCallback, userdata: ?*anyopaque) void {
        self.on_evicted = cb;
        self.on_evicted_userdata = userdata;
    }

    /// Set the topology_changed notification callback.
    pub fn setTopologyCallback(self: *Client, cb: ?TopologyCallback, userdata: ?*anyopaque) void {
        self.on_topology = cb;
        self.on_topology_userdata = userdata;
    }

    /// Set the visibility_changed notification callback.
    pub fn setVisibilityCallback(self: *Client, cb: ?VisibilityCallback, userdata: ?*anyopaque) void {
        self.on_visibility = cb;
        self.on_visibility_userdata = userdata;
    }

    /// Set the theme_changed notification callback.
    pub fn setThemeCallback(self: *Client, cb: ?ThemeCallback, userdata: ?*anyopaque) void {
        self.on_theme = cb;
        self.on_theme_userdata = userdata;
    }

    // ---------- RPC methods ----------

    /// Upload image data. Returns the server-assigned handle.
    pub fn upload(self: *Client, data: []const u8, format: []const u8, width: i32, height: i32) Error!u32 {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        const msgid = self.nextMsgId();
        encodeRequestHeader(&enc, msgid, "upload") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;
        enc.writeMapHeader(4) catch return Error.OutOfMemory;
        enc.writeStr("data") catch return Error.OutOfMemory;
        enc.writeBin(data) catch return Error.OutOfMemory;
        enc.writeStr("format") catch return Error.OutOfMemory;
        enc.writeStr(format) catch return Error.OutOfMemory;
        enc.writeStr("width") catch return Error.OutOfMemory;
        enc.writeInt(width) catch return Error.OutOfMemory;
        enc.writeStr("height") catch return Error.OutOfMemory;
        enc.writeInt(height) catch return Error.OutOfMemory;

        const result_data = try self.doCall(enc.getWritten(), msgid);
        defer self.allocator.free(result_data);

        // Parse: {"handle": uint32}
        var dec = Decoder.init(result_data);
        const nkeys = dec.readMap() catch return Error.DecodeFailed;
        var handle: u32 = 0;
        for (0..nkeys) |_| {
            const key = dec.readStr() catch return Error.DecodeFailed;
            if (std.mem.eql(u8, key, "handle")) {
                handle = @intCast(dec.readUint() catch return Error.DecodeFailed);
            } else {
                dec.skip() catch return Error.DecodeFailed;
            }
        }
        return handle;
    }

    /// Place an image. Returns the placement ID.
    pub fn place(
        self: *Client,
        handle: u32,
        anchor: Anchor,
        width: i32,
        height: i32,
        opts: ?PlaceOpts,
    ) Error!u32 {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        const msgid = self.nextMsgId();
        encodeRequestHeader(&enc, msgid, "place") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;

        // Count map entries.
        var map_count: u32 = 4; // handle, anchor, width, height
        if (opts) |o| {
            if (o.src_x != 0) map_count += 1;
            if (o.src_y != 0) map_count += 1;
            if (o.src_w != 0) map_count += 1;
            if (o.src_h != 0) map_count += 1;
            if (o.z_index != 0) map_count += 1;
        }
        enc.writeMapHeader(map_count) catch return Error.OutOfMemory;

        enc.writeStr("handle") catch return Error.OutOfMemory;
        enc.writeUint(handle) catch return Error.OutOfMemory;

        enc.writeStr("anchor") catch return Error.OutOfMemory;
        encodeAnchor(&enc, anchor) catch return Error.OutOfMemory;

        enc.writeStr("width") catch return Error.OutOfMemory;
        enc.writeInt(width) catch return Error.OutOfMemory;
        enc.writeStr("height") catch return Error.OutOfMemory;
        enc.writeInt(height) catch return Error.OutOfMemory;

        if (opts) |o| {
            if (o.src_x != 0) {
                enc.writeStr("src_x") catch return Error.OutOfMemory;
                enc.writeInt(o.src_x) catch return Error.OutOfMemory;
            }
            if (o.src_y != 0) {
                enc.writeStr("src_y") catch return Error.OutOfMemory;
                enc.writeInt(o.src_y) catch return Error.OutOfMemory;
            }
            if (o.src_w != 0) {
                enc.writeStr("src_w") catch return Error.OutOfMemory;
                enc.writeInt(o.src_w) catch return Error.OutOfMemory;
            }
            if (o.src_h != 0) {
                enc.writeStr("src_h") catch return Error.OutOfMemory;
                enc.writeInt(o.src_h) catch return Error.OutOfMemory;
            }
            if (o.z_index != 0) {
                enc.writeStr("z_index") catch return Error.OutOfMemory;
                enc.writeInt(o.z_index) catch return Error.OutOfMemory;
            }
        }

        const result_data = try self.doCall(enc.getWritten(), msgid);
        defer self.allocator.free(result_data);

        // Parse: {"placement_id": uint32}
        var dec = Decoder.init(result_data);
        const nkeys = dec.readMap() catch return Error.DecodeFailed;
        var placement_id: u32 = 0;
        for (0..nkeys) |_| {
            const key = dec.readStr() catch return Error.DecodeFailed;
            if (std.mem.eql(u8, key, "placement_id")) {
                placement_id = @intCast(dec.readUint() catch return Error.DecodeFailed);
            } else {
                dec.skip() catch return Error.DecodeFailed;
            }
        }
        return placement_id;
    }

    /// Remove a placement (request/response).
    pub fn unplace(self: *Client, placement_id: u32) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        const msgid = self.nextMsgId();
        encodeRequestHeader(&enc, msgid, "unplace") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;
        enc.writeMapHeader(1) catch return Error.OutOfMemory;
        enc.writeStr("placement_id") catch return Error.OutOfMemory;
        enc.writeUint(placement_id) catch return Error.OutOfMemory;

        const result_data = try self.doCall(enc.getWritten(), msgid);
        self.allocator.free(result_data);
    }

    /// Remove all placements for this client (notification, fire-and-forget).
    pub fn unplaceAll(self: *Client) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        encodeNotificationHeader(&enc, "unplace_all") catch return Error.OutOfMemory;
        enc.writeArrayHeader(0) catch return Error.OutOfMemory;

        try self.sendRaw(enc.getWritten());
    }

    /// Release an uploaded image handle (request/response).
    pub fn free(self: *Client, handle: u32) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        const msgid = self.nextMsgId();
        encodeRequestHeader(&enc, msgid, "free") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;
        enc.writeMapHeader(1) catch return Error.OutOfMemory;
        enc.writeStr("handle") catch return Error.OutOfMemory;
        enc.writeUint(handle) catch return Error.OutOfMemory;

        const result_data = try self.doCall(enc.getWritten(), msgid);
        self.allocator.free(result_data);
    }

    /// Register a neovim window geometry (notification).
    pub fn registerWin(
        self: *Client,
        win_id: i32,
        pane_id: []const u8,
        top: i32,
        left: i32,
        width: i32,
        height: i32,
        scroll_top: i32,
    ) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        encodeNotificationHeader(&enc, "register_win") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;
        enc.writeMapHeader(7) catch return Error.OutOfMemory;
        enc.writeStr("win_id") catch return Error.OutOfMemory;
        enc.writeInt(win_id) catch return Error.OutOfMemory;
        enc.writeStr("pane_id") catch return Error.OutOfMemory;
        enc.writeStr(pane_id) catch return Error.OutOfMemory;
        enc.writeStr("top") catch return Error.OutOfMemory;
        enc.writeInt(top) catch return Error.OutOfMemory;
        enc.writeStr("left") catch return Error.OutOfMemory;
        enc.writeInt(left) catch return Error.OutOfMemory;
        enc.writeStr("width") catch return Error.OutOfMemory;
        enc.writeInt(width) catch return Error.OutOfMemory;
        enc.writeStr("height") catch return Error.OutOfMemory;
        enc.writeInt(height) catch return Error.OutOfMemory;
        enc.writeStr("scroll_top") catch return Error.OutOfMemory;
        enc.writeInt(scroll_top) catch return Error.OutOfMemory;

        try self.sendRaw(enc.getWritten());
    }

    /// Update scroll position for a registered window (notification).
    pub fn updateScroll(self: *Client, win_id: i32, scroll_top: i32) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        encodeNotificationHeader(&enc, "update_scroll") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;
        enc.writeMapHeader(2) catch return Error.OutOfMemory;
        enc.writeStr("win_id") catch return Error.OutOfMemory;
        enc.writeInt(win_id) catch return Error.OutOfMemory;
        enc.writeStr("scroll_top") catch return Error.OutOfMemory;
        enc.writeInt(scroll_top) catch return Error.OutOfMemory;

        try self.sendRaw(enc.getWritten());
    }

    /// Unregister a neovim window (notification).
    pub fn unregisterWin(self: *Client, win_id: i32) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        encodeNotificationHeader(&enc, "unregister_win") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;
        enc.writeMapHeader(1) catch return Error.OutOfMemory;
        enc.writeStr("win_id") catch return Error.OutOfMemory;
        enc.writeInt(win_id) catch return Error.OutOfMemory;

        try self.sendRaw(enc.getWritten());
    }

    /// Return all active placements. Caller owns the returned slice.
    pub fn list(self: *Client) Error![]PlacementInfo {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        const msgid = self.nextMsgId();
        encodeRequestHeader(&enc, msgid, "list") catch return Error.OutOfMemory;
        enc.writeArrayHeader(0) catch return Error.OutOfMemory;

        const result_data = try self.doCall(enc.getWritten(), msgid);
        defer self.allocator.free(result_data);

        // Parse: {"placements": [{...}, ...]}
        var dec = Decoder.init(result_data);
        const nkeys = dec.readMap() catch return Error.DecodeFailed;
        var placements: []PlacementInfo = &.{};
        var client_id_bufs = std.ArrayList([]u8).init(self.allocator);
        defer client_id_bufs.deinit();

        for (0..nkeys) |_| {
            const key = dec.readStr() catch return Error.DecodeFailed;
            if (std.mem.eql(u8, key, "placements")) {
                const arr_count = dec.readArray() catch return Error.DecodeFailed;
                placements = self.allocator.alloc(PlacementInfo, arr_count) catch return Error.OutOfMemory;
                for (placements) |*p| {
                    p.* = .{};
                    const mkeys = dec.readMap() catch return Error.DecodeFailed;
                    for (0..mkeys) |_| {
                        const mkey = dec.readStr() catch return Error.DecodeFailed;
                        if (std.mem.eql(u8, mkey, "placement_id")) {
                            p.placement_id = @intCast(dec.readUint() catch return Error.DecodeFailed);
                        } else if (std.mem.eql(u8, mkey, "client_id")) {
                            const cid = dec.readStr() catch return Error.DecodeFailed;
                            const owned = self.allocator.dupe(u8, cid) catch return Error.OutOfMemory;
                            client_id_bufs.append(owned) catch return Error.OutOfMemory;
                            p.client_id = owned;
                        } else if (std.mem.eql(u8, mkey, "handle")) {
                            p.handle = @intCast(dec.readUint() catch return Error.DecodeFailed);
                        } else if (std.mem.eql(u8, mkey, "visible")) {
                            p.visible = dec.readBool() catch return Error.DecodeFailed;
                        } else if (std.mem.eql(u8, mkey, "row")) {
                            p.row = @intCast(dec.readInt() catch return Error.DecodeFailed);
                        } else if (std.mem.eql(u8, mkey, "col")) {
                            p.col = @intCast(dec.readInt() catch return Error.DecodeFailed);
                        } else {
                            dec.skip() catch return Error.DecodeFailed;
                        }
                    }
                }
            } else {
                dec.skip() catch return Error.DecodeFailed;
            }
        }
        return placements;
    }

    /// Free a placement list returned by `list()`.
    pub fn freeList(self: *Client, placements: []PlacementInfo) void {
        for (placements) |p| {
            if (p.client_id.len > 0) {
                self.allocator.free(@constCast(p.client_id));
            }
        }
        self.allocator.free(placements);
    }

    /// Return daemon status information.
    pub fn status(self: *Client) Error!StatusResult {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        const msgid = self.nextMsgId();
        encodeRequestHeader(&enc, msgid, "status") catch return Error.OutOfMemory;
        enc.writeArrayHeader(0) catch return Error.OutOfMemory;

        const result_data = try self.doCall(enc.getWritten(), msgid);
        defer self.allocator.free(result_data);

        var result = StatusResult{};
        var dec = Decoder.init(result_data);
        const nkeys = dec.readMap() catch return Error.DecodeFailed;
        for (0..nkeys) |_| {
            const key = dec.readStr() catch return Error.DecodeFailed;
            if (std.mem.eql(u8, key, "clients")) {
                result.clients = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "placements")) {
                result.placements = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "images")) {
                result.images = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "cols")) {
                result.cols = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "rows")) {
                result.rows = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else {
                dec.skip() catch return Error.DecodeFailed;
            }
        }
        return result;
    }

    /// Request the daemon to shut down (notification).
    pub fn stop(self: *Client) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        encodeNotificationHeader(&enc, "stop") catch return Error.OutOfMemory;
        enc.writeArrayHeader(0) catch return Error.OutOfMemory;

        try self.sendRaw(enc.getWritten());
    }

    // ---------- Internal ----------

    fn doHello(self: *Client, opts: Options) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();

        const msgid = self.nextMsgId();
        encodeRequestHeader(&enc, msgid, "hello") catch return Error.OutOfMemory;
        enc.writeArrayHeader(1) catch return Error.OutOfMemory;

        var map_count: u32 = 3; // client_type, pid, label
        if (opts.session_id.len > 0) map_count += 1;
        enc.writeMapHeader(map_count) catch return Error.OutOfMemory;

        enc.writeStr("client_type") catch return Error.OutOfMemory;
        enc.writeStr(opts.client_type) catch return Error.OutOfMemory;
        enc.writeStr("pid") catch return Error.OutOfMemory;
        const pid: i32 = if (opts.pid != 0) opts.pid else getPid();
        enc.writeInt(pid) catch return Error.OutOfMemory;
        enc.writeStr("label") catch return Error.OutOfMemory;
        enc.writeStr(opts.label) catch return Error.OutOfMemory;
        if (opts.session_id.len > 0) {
            enc.writeStr("session_id") catch return Error.OutOfMemory;
            enc.writeStr(opts.session_id) catch return Error.OutOfMemory;
        }

        const result_data = self.doCall(enc.getWritten(), msgid) catch return Error.HelloFailed;
        defer self.allocator.free(result_data);

        // Parse hello result.
        var dec = Decoder.init(result_data);
        const nkeys = dec.readMap() catch return Error.DecodeFailed;
        for (0..nkeys) |_| {
            const key = dec.readStr() catch return Error.DecodeFailed;
            if (std.mem.eql(u8, key, "client_id")) {
                const cid = dec.readStr() catch return Error.DecodeFailed;
                self.client_id_buf = self.allocator.dupe(u8, cid) catch return Error.OutOfMemory;
                self.hello.client_id = self.client_id_buf.?;
            } else if (std.mem.eql(u8, key, "cols")) {
                self.hello.cols = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "rows")) {
                self.hello.rows = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "cell_width")) {
                self.hello.cell_width = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "cell_height")) {
                self.hello.cell_height = @intCast(dec.readInt() catch return Error.DecodeFailed);
            } else if (std.mem.eql(u8, key, "in_tmux")) {
                self.hello.in_tmux = dec.readBool() catch return Error.DecodeFailed;
            } else if (std.mem.eql(u8, key, "fg")) {
                self.hello.fg = decodeColor(&dec) catch return Error.DecodeFailed;
            } else if (std.mem.eql(u8, key, "bg")) {
                self.hello.bg = decodeColor(&dec) catch return Error.DecodeFailed;
            } else {
                dec.skip() catch return Error.DecodeFailed;
            }
        }
    }

    fn nextMsgId(self: *Client) u32 {
        return self.next_id.fetchAdd(1, .monotonic);
    }

    /// Send a request and wait for the matching response. Returns owned result bytes.
    fn doCall(self: *Client, data: []const u8, msgid: u32) Error![]const u8 {
        const slot = msgid % MAX_PENDING;

        // Prepare the pending slot.
        self.pending_mutex.lock();
        var pe = &self.pending[slot];
        if (pe.active) {
            self.pending_mutex.unlock();
            return Error.SendFailed;
        }
        pe.active = true;
        pe.done = false;
        pe.has_error = false;
        if (pe.result_data) |d| {
            self.allocator.free(d);
            pe.result_data = null;
        }
        if (pe.err_msg) |e| {
            self.allocator.free(e);
            pe.err_msg = null;
        }
        pe.event.reset();
        self.pending_mutex.unlock();

        // Send the request.
        self.sendRaw(data) catch {
            self.pending_mutex.lock();
            pe.active = false;
            self.pending_mutex.unlock();
            return Error.SendFailed;
        };

        // Wait for response (10s timeout).
        pe.event.timedWait(10 * std.time.ns_per_s) catch {
            self.pending_mutex.lock();
            pe.active = false;
            self.pending_mutex.unlock();
            return Error.Timeout;
        };

        if (self.closed.load(.acquire)) {
            self.pending_mutex.lock();
            pe.active = false;
            self.pending_mutex.unlock();
            return Error.ConnectionClosed;
        }

        self.pending_mutex.lock();
        defer {
            pe.active = false;
            self.pending_mutex.unlock();
        }

        if (pe.has_error) {
            if (pe.err_msg) |e| {
                self.allocator.free(e);
                pe.err_msg = null;
            }
            return Error.RpcError;
        }

        if (pe.result_data) |d| {
            pe.result_data = null;
            return d;
        }

        // No result data (nil result) -- return an empty owned slice.
        return self.allocator.alloc(u8, 0) catch return Error.OutOfMemory;
    }

    /// Send raw bytes under the write lock.
    fn sendRaw(self: *Client, data: []const u8) Error!void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var sent: usize = 0;
        while (sent < data.len) {
            const n = std.posix.write(self.fd, data[sent..]) catch return Error.SendFailed;
            if (n == 0) return Error.SendFailed;
            sent += n;
        }
    }

    /// Background reader thread.
    fn readLoop(self: *Client) void {
        var recv_buf = std.ArrayList(u8).init(self.allocator);
        defer recv_buf.deinit();

        var tmp: [RECV_BUF_SIZE]u8 = undefined;

        while (!self.closed.load(.acquire)) {
            const n = std.posix.read(self.fd, &tmp) catch break;
            if (n == 0) break;

            recv_buf.appendSlice(tmp[0..n]) catch break;

            // Process complete messages.
            while (recv_buf.items.len > 0) {
                const msg_len = Decoder.tryMeasure(recv_buf.items) orelse break;
                self.processMessage(recv_buf.items[0..msg_len]);
                // Remove processed bytes.
                const remaining = recv_buf.items.len - msg_len;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, recv_buf.items[0..remaining], recv_buf.items[msg_len..]);
                }
                recv_buf.shrinkRetainingCapacity(remaining);
            }
        }

        // Wake pending calls on disconnect.
        self.pending_mutex.lock();
        for (&self.pending) |*p| {
            if (p.active) {
                p.done = true;
                p.event.set();
            }
        }
        self.pending_mutex.unlock();
    }

    /// Process one complete msgpack message.
    fn processMessage(self: *Client, data: []const u8) void {
        var dec = Decoder.init(data);
        const arr_count = dec.readArray() catch return;
        if (arr_count < 3) return;

        const msgtype = dec.readUint() catch return;

        if (msgtype == MSG_RESPONSE) {
            self.handleResponse(&dec);
        } else if (msgtype == MSG_NOTIFICATION) {
            self.handleNotification(&dec);
        }
    }

    fn handleResponse(self: *Client, dec: *Decoder) void {
        const msgid_u = dec.readUint() catch return;
        const msgid: u32 = @intCast(msgid_u);

        // Read error field.
        const err_val = dec.read() catch return;
        const has_rpc_error = (std.meta.activeTag(err_val) != .nil);

        var err_msg_owned: ?[]u8 = null;
        if (has_rpc_error) {
            // Try to extract error message from map.
            // The error field was already consumed by dec.read() above.
            // For map types, only the header was consumed; we need to read the entries.
            // For all other types (str, int, etc.), the value is fully consumed.
            switch (err_val) {
                .map => |nkeys| {
                    for (0..nkeys) |_| {
                        const key = dec.readStr() catch break;
                        if (std.mem.eql(u8, key, "message")) {
                            const msg = dec.readStr() catch break;
                            err_msg_owned = self.allocator.dupe(u8, msg) catch null;
                        } else {
                            dec.skip() catch break;
                        }
                    }
                },
                .array => |n| {
                    // Unlikely, but consume array elements.
                    for (0..n) |_| dec.skip() catch break;
                },
                else => {
                    // Scalar types (str, int, bool, bin) are already fully consumed.
                },
            }
        }

        // Capture result bytes: measure the result value's encoded size.
        const result_start = dec.pos;
        dec.skip() catch return;
        const result_end = dec.pos;

        const slot = msgid % MAX_PENDING;
        self.pending_mutex.lock();
        var pe = &self.pending[slot];
        if (pe.active) {
            pe.has_error = has_rpc_error;
            pe.err_msg = err_msg_owned;
            if (!has_rpc_error and result_end > result_start) {
                pe.result_data = self.allocator.dupe(u8, data_slice(dec, result_start, result_end)) catch null;
            }
            pe.done = true;
            pe.event.set();
        } else {
            // No one waiting; free err_msg if allocated.
            if (err_msg_owned) |e| self.allocator.free(e);
        }
        self.pending_mutex.unlock();
    }

    fn handleNotification(self: *Client, dec: *Decoder) void {
        const method = dec.readStr() catch return;
        const params_count = dec.readArray() catch return;
        if (params_count == 0) return;

        // The first param should be a map.
        const nkeys = dec.readMap() catch return;

        if (std.mem.eql(u8, method, "evicted")) {
            if (self.on_evicted) |cb| {
                var handle: u32 = 0;
                for (0..nkeys) |_| {
                    const key = dec.readStr() catch return;
                    if (std.mem.eql(u8, key, "handle")) {
                        handle = @intCast(dec.readUint() catch return);
                    } else {
                        dec.skip() catch return;
                    }
                }
                cb(handle, self.on_evicted_userdata);
            } else {
                skipMapEntries(dec, nkeys);
            }
        } else if (std.mem.eql(u8, method, "topology_changed")) {
            if (self.on_topology) |cb| {
                var cols: i32 = 0;
                var rows: i32 = 0;
                var cw: i32 = 0;
                var ch: i32 = 0;
                for (0..nkeys) |_| {
                    const key = dec.readStr() catch return;
                    if (std.mem.eql(u8, key, "cols")) {
                        cols = @intCast(dec.readInt() catch return);
                    } else if (std.mem.eql(u8, key, "rows")) {
                        rows = @intCast(dec.readInt() catch return);
                    } else if (std.mem.eql(u8, key, "cell_width")) {
                        cw = @intCast(dec.readInt() catch return);
                    } else if (std.mem.eql(u8, key, "cell_height")) {
                        ch = @intCast(dec.readInt() catch return);
                    } else {
                        dec.skip() catch return;
                    }
                }
                cb(cols, rows, cw, ch, self.on_topology_userdata);
            } else {
                skipMapEntries(dec, nkeys);
            }
        } else if (std.mem.eql(u8, method, "visibility_changed")) {
            if (self.on_visibility) |cb| {
                var placement_id: u32 = 0;
                var visible: bool = false;
                for (0..nkeys) |_| {
                    const key = dec.readStr() catch return;
                    if (std.mem.eql(u8, key, "placement_id")) {
                        placement_id = @intCast(dec.readUint() catch return);
                    } else if (std.mem.eql(u8, key, "visible")) {
                        visible = dec.readBool() catch return;
                    } else {
                        dec.skip() catch return;
                    }
                }
                cb(placement_id, visible, self.on_visibility_userdata);
            } else {
                skipMapEntries(dec, nkeys);
            }
        } else if (std.mem.eql(u8, method, "theme_changed")) {
            if (self.on_theme) |cb| {
                var fg = Color{};
                var bg = Color{};
                for (0..nkeys) |_| {
                    const key = dec.readStr() catch return;
                    if (std.mem.eql(u8, key, "fg")) {
                        fg = decodeColor(dec) catch return;
                    } else if (std.mem.eql(u8, key, "bg")) {
                        bg = decodeColor(dec) catch return;
                    } else {
                        dec.skip() catch return;
                    }
                }
                cb(fg, bg, self.on_theme_userdata);
            } else {
                skipMapEntries(dec, nkeys);
            }
        } else {
            // Unknown notification -- skip.
            skipMapEntries(dec, nkeys);
        }
    }
};

// ---------- Encoding helpers ----------

fn encodeRequestHeader(enc: *Encoder, msgid: u32, method: []const u8) protocol.EncodeError!void {
    try enc.writeArrayHeader(4);
    try enc.writeUint(MSG_REQUEST);
    try enc.writeUint(msgid);
    try enc.writeStr(method);
}

fn encodeNotificationHeader(enc: *Encoder, method: []const u8) protocol.EncodeError!void {
    try enc.writeArrayHeader(3);
    try enc.writeUint(MSG_NOTIFICATION);
    try enc.writeStr(method);
}

fn encodeAnchor(enc: *Encoder, anchor: Anchor) protocol.EncodeError!void {
    try enc.writeMapHeader(anchor.mapCount());
    try enc.writeStr("type");
    try enc.writeStr(anchor.type.toString());
    if (anchor.pane_id.len > 0) {
        try enc.writeStr("pane_id");
        try enc.writeStr(anchor.pane_id);
    }
    if (anchor.win_id != 0) {
        try enc.writeStr("win_id");
        try enc.writeInt(anchor.win_id);
    }
    if (anchor.buf_line != 0) {
        try enc.writeStr("buf_line");
        try enc.writeInt(anchor.buf_line);
    }
    if (anchor.row != 0) {
        try enc.writeStr("row");
        try enc.writeInt(anchor.row);
    }
    if (anchor.col != 0) {
        try enc.writeStr("col");
        try enc.writeInt(anchor.col);
    }
}

// ---------- Decoding helpers ----------

fn decodeColor(dec: *Decoder) protocol.DecodeError!Color {
    var color = Color{};
    const nkeys = try dec.readMap();
    for (0..nkeys) |_| {
        const key = try dec.readStr();
        if (std.mem.eql(u8, key, "r")) {
            color.r = @intCast(try dec.readUint());
        } else if (std.mem.eql(u8, key, "g")) {
            color.g = @intCast(try dec.readUint());
        } else if (std.mem.eql(u8, key, "b")) {
            color.b = @intCast(try dec.readUint());
        } else {
            try dec.skip();
        }
    }
    return color;
}

fn skipMapEntries(dec: *Decoder, count: u32) void {
    for (0..count) |_| {
        dec.skip() catch return; // key
        dec.skip() catch return; // value
    }
}

/// Helper to get a slice from decoder's underlying data given start/end positions.
fn data_slice(dec: *const Decoder, start: usize, end: usize) []const u8 {
    return dec.data[start..end];
}

// ---------- Process helpers ----------

/// Cross-platform process ID retrieval.
/// Falls back to 0 if the platform does not expose getpid through std.posix.system.
fn getPid() i32 {
    return std.posix.system.getpid();
}

// ---------- Socket helpers ----------

const ResolvedPath = struct {
    path: []const u8,
    allocated: bool,
};

fn resolveSocketPath(allocator: std.mem.Allocator, explicit: []const u8) !ResolvedPath {
    if (explicit.len > 0) return .{ .path = explicit, .allocated = false };

    // Try $KGD_SOCKET
    if (std.posix.getenv("KGD_SOCKET")) |p| {
        if (p.len > 0) return .{ .path = p, .allocated = false };
    }

    // Build from $XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const kitty_id = std.posix.getenv("KITTY_WINDOW_ID") orelse "default";

    const path = try std.fmt.allocPrint(allocator, "{s}/kgd-{s}.sock", .{ runtime_dir, kitty_id });
    return .{ .path = path, .allocated = true };
}

fn connectUnix(path: []const u8) !std.posix.socket_t {
    const stream = try std.net.connectUnixSocket(path);
    return stream.handle;
}

// ---------- Tests ----------

test "resolveSocketPath explicit" {
    const resolved = try resolveSocketPath(std.testing.allocator, "/tmp/test.sock");
    try std.testing.expectEqualStrings("/tmp/test.sock", resolved.path);
    try std.testing.expectEqual(false, resolved.allocated);
}

test "anchor mapCount" {
    const a1 = Anchor{ .type = .absolute, .row = 5, .col = 10 };
    try std.testing.expectEqual(@as(u32, 3), a1.mapCount());

    const a2 = Anchor{ .type = .absolute };
    try std.testing.expectEqual(@as(u32, 1), a2.mapCount());

    const a3 = Anchor{ .type = .pane, .pane_id = "%0", .row = 2 };
    try std.testing.expectEqual(@as(u32, 3), a3.mapCount());
}

test "encodeAnchor absolute" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try encodeAnchor(&enc, .{ .type = .absolute, .row = 5, .col = 10 });

    var dec = Decoder.init(enc.getWritten());
    const nkeys = try dec.readMap();
    try std.testing.expectEqual(@as(u32, 3), nkeys);

    // Read all key-value pairs.
    var found_type = false;
    var found_row = false;
    var found_col = false;
    for (0..nkeys) |_| {
        const key = try dec.readStr();
        if (std.mem.eql(u8, key, "type")) {
            try std.testing.expectEqualStrings("absolute", try dec.readStr());
            found_type = true;
        } else if (std.mem.eql(u8, key, "row")) {
            try std.testing.expectEqual(@as(i64, 5), try dec.readInt());
            found_row = true;
        } else if (std.mem.eql(u8, key, "col")) {
            try std.testing.expectEqual(@as(i64, 10), try dec.readInt());
            found_col = true;
        }
    }
    try std.testing.expect(found_type);
    try std.testing.expect(found_row);
    try std.testing.expect(found_col);
}

test "encodeAnchor omits zero fields" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try encodeAnchor(&enc, .{ .type = .absolute });

    var dec = Decoder.init(enc.getWritten());
    const nkeys = try dec.readMap();
    try std.testing.expectEqual(@as(u32, 1), nkeys);
    try std.testing.expectEqualStrings("type", try dec.readStr());
    try std.testing.expectEqualStrings("absolute", try dec.readStr());
}

test "encodeAnchor pane" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try encodeAnchor(&enc, .{ .type = .pane, .pane_id = "%0", .row = 2, .col = 3 });

    var dec = Decoder.init(enc.getWritten());
    const nkeys = try dec.readMap();
    try std.testing.expectEqual(@as(u32, 4), nkeys);
}

test "encodeAnchor nvim_win" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try encodeAnchor(&enc, .{ .type = .nvim_win, .win_id = 1000, .buf_line = 5 });

    var dec = Decoder.init(enc.getWritten());
    const nkeys = try dec.readMap();
    try std.testing.expectEqual(@as(u32, 3), nkeys);
}

test "request encoding round-trip" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();

    try encodeRequestHeader(&enc, 42, "upload");
    try enc.writeArrayHeader(1);
    try enc.writeMapHeader(2);
    try enc.writeStr("format");
    try enc.writeStr("png");
    try enc.writeStr("width");
    try enc.writeInt(100);

    var dec = Decoder.init(enc.getWritten());
    const arr = try dec.readArray();
    try std.testing.expectEqual(@as(u32, 4), arr);

    const msgtype = try dec.readUint();
    try std.testing.expectEqual(MSG_REQUEST, msgtype);

    const msgid = try dec.readUint();
    try std.testing.expectEqual(@as(u64, 42), msgid);

    const method = try dec.readStr();
    try std.testing.expectEqualStrings("upload", method);

    const params_arr = try dec.readArray();
    try std.testing.expectEqual(@as(u32, 1), params_arr);

    const map_count = try dec.readMap();
    try std.testing.expectEqual(@as(u32, 2), map_count);
}

test "notification encoding round-trip" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();

    try encodeNotificationHeader(&enc, "stop");
    try enc.writeArrayHeader(0);

    var dec = Decoder.init(enc.getWritten());
    const arr = try dec.readArray();
    try std.testing.expectEqual(@as(u32, 3), arr);

    const msgtype = try dec.readUint();
    try std.testing.expectEqual(MSG_NOTIFICATION, msgtype);

    const method = try dec.readStr();
    try std.testing.expectEqualStrings("stop", method);

    const params = try dec.readArray();
    try std.testing.expectEqual(@as(u32, 0), params);
}

test "decodeColor" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();

    try enc.writeMapHeader(3);
    try enc.writeStr("r");
    try enc.writeUint(65535);
    try enc.writeStr("g");
    try enc.writeUint(32768);
    try enc.writeStr("b");
    try enc.writeUint(0);

    var dec = Decoder.init(enc.getWritten());
    const color = try decodeColor(&dec);
    try std.testing.expectEqual(@as(u16, 65535), color.r);
    try std.testing.expectEqual(@as(u16, 32768), color.g);
    try std.testing.expectEqual(@as(u16, 0), color.b);
}
