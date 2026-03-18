/// protocol.zig -- Minimal msgpack encoder/decoder for kgd RPC.
///
/// Supports the subset of msgpack types needed by the protocol:
///   fixint, uint8/16/32, int8/16/32, nil, bool,
///   bin8/16/32, str8/16/32, fixstr,
///   fixarray, array16, fixmap, map16.
const std = @import("std");

// ---------- msgpack format byte constants ----------

const FMT_NIL: u8 = 0xc0;
const FMT_FALSE: u8 = 0xc2;
const FMT_TRUE: u8 = 0xc3;
const FMT_BIN8: u8 = 0xc4;
const FMT_BIN16: u8 = 0xc5;
const FMT_BIN32: u8 = 0xc6;
const FMT_UINT8: u8 = 0xcc;
const FMT_UINT16: u8 = 0xcd;
const FMT_UINT32: u8 = 0xce;
const FMT_INT8: u8 = 0xd0;
const FMT_INT16: u8 = 0xd1;
const FMT_INT32: u8 = 0xd2;
const FMT_FIXSTR_MASK: u8 = 0xa0;
const FMT_STR8: u8 = 0xd9;
const FMT_STR16: u8 = 0xda;
const FMT_STR32: u8 = 0xdb;
const FMT_FIXARRAY_MASK: u8 = 0x90;
const FMT_ARRAY16: u8 = 0xdc;
const FMT_FIXMAP_MASK: u8 = 0x80;
const FMT_MAP16: u8 = 0xde;

pub const EncodeError = error{OutOfMemory};

pub const DecodeError = error{
    UnexpectedEof,
    InvalidFormat,
    Overflow,
};

// ---------- Encoder ----------

/// Growable byte buffer that encodes msgpack values.
pub const Encoder = struct {
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .buf = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *Encoder) void {
        self.buf.deinit();
    }

    /// Return the encoded bytes as a slice.  Caller does NOT own the memory
    /// (it belongs to the internal ArrayList).
    pub fn getWritten(self: *const Encoder) []const u8 {
        return self.buf.items;
    }

    /// Reset the buffer for reuse.
    pub fn reset(self: *Encoder) void {
        self.buf.clearRetainingCapacity();
    }

    // -- Primitive writers --

    pub fn writeNil(self: *Encoder) EncodeError!void {
        try self.buf.append(FMT_NIL);
    }

    pub fn writeBool(self: *Encoder, v: bool) EncodeError!void {
        try self.buf.append(if (v) FMT_TRUE else FMT_FALSE);
    }

    pub fn writeInt(self: *Encoder, v: i64) EncodeError!void {
        if (v >= 0) {
            try self.writeUint(@intCast(v));
        } else if (v >= -32) {
            // negative fixint: 111xxxxx
            try self.buf.append(@bitCast(@as(i8, @intCast(v))));
        } else if (v >= -128) {
            try self.buf.append(FMT_INT8);
            try self.buf.append(@bitCast(@as(i8, @intCast(v))));
        } else if (v >= -32768) {
            try self.buf.append(FMT_INT16);
            try self.appendBe16(@bitCast(@as(i16, @intCast(v))));
        } else {
            try self.buf.append(FMT_INT32);
            try self.appendBe32(@bitCast(@as(i32, @intCast(v))));
        }
    }

    pub fn writeUint(self: *Encoder, v: u64) EncodeError!void {
        if (v <= 0x7f) {
            // positive fixint
            try self.buf.append(@intCast(v));
        } else if (v <= 0xff) {
            try self.buf.append(FMT_UINT8);
            try self.buf.append(@intCast(v));
        } else if (v <= 0xffff) {
            try self.buf.append(FMT_UINT16);
            try self.appendBe16(@intCast(v));
        } else {
            try self.buf.append(FMT_UINT32);
            try self.appendBe32(@intCast(v));
        }
    }

    pub fn writeStr(self: *Encoder, s: []const u8) EncodeError!void {
        const len = s.len;
        if (len <= 31) {
            try self.buf.append(FMT_FIXSTR_MASK | @as(u8, @intCast(len)));
        } else if (len <= 0xff) {
            try self.buf.append(FMT_STR8);
            try self.buf.append(@intCast(len));
        } else if (len <= 0xffff) {
            try self.buf.append(FMT_STR16);
            try self.appendBe16(@intCast(len));
        } else {
            try self.buf.append(FMT_STR32);
            try self.appendBe32(@intCast(len));
        }
        try self.buf.appendSlice(s);
    }

    pub fn writeBin(self: *Encoder, data: []const u8) EncodeError!void {
        const len = data.len;
        if (len <= 0xff) {
            try self.buf.append(FMT_BIN8);
            try self.buf.append(@intCast(len));
        } else if (len <= 0xffff) {
            try self.buf.append(FMT_BIN16);
            try self.appendBe16(@intCast(len));
        } else {
            try self.buf.append(FMT_BIN32);
            try self.appendBe32(@intCast(len));
        }
        try self.buf.appendSlice(data);
    }

    pub fn writeArrayHeader(self: *Encoder, count: u32) EncodeError!void {
        if (count <= 15) {
            try self.buf.append(FMT_FIXARRAY_MASK | @as(u8, @intCast(count)));
        } else {
            try self.buf.append(FMT_ARRAY16);
            try self.appendBe16(@intCast(count));
        }
    }

    pub fn writeMapHeader(self: *Encoder, count: u32) EncodeError!void {
        if (count <= 15) {
            try self.buf.append(FMT_FIXMAP_MASK | @as(u8, @intCast(count)));
        } else {
            try self.buf.append(FMT_MAP16);
            try self.appendBe16(@intCast(count));
        }
    }

    // -- Helpers --

    fn appendBe16(self: *Encoder, v: u16) EncodeError!void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, v));
        try self.buf.appendSlice(&bytes);
    }

    fn appendBe32(self: *Encoder, v: u32) EncodeError!void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, v));
        try self.buf.appendSlice(&bytes);
    }
};

// ---------- Decoder ----------

/// A decoded msgpack value.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    uint: u64,
    int: i64,
    str: []const u8,
    bin: []const u8,
    array: u32, // element count -- caller reads elements one by one
    map: u32, // entry count -- caller reads key/value pairs
};

/// Streaming msgpack decoder over a byte slice.
pub const Decoder = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Decoder {
        return .{ .data = data, .pos = 0 };
    }

    /// Returns the number of bytes remaining.
    pub fn remaining(self: *const Decoder) usize {
        return self.data.len - self.pos;
    }

    /// Read the next value.
    pub fn read(self: *Decoder) DecodeError!Value {
        const b = try self.readByte();

        // positive fixint: 0xxxxxxx
        if (b <= 0x7f) return .{ .uint = b };

        // negative fixint: 111xxxxx
        if (b >= 0xe0) return .{ .int = @as(i8, @bitCast(b)) };

        // fixmap: 1000xxxx
        if (b & 0xf0 == 0x80) return .{ .map = b & 0x0f };

        // fixarray: 1001xxxx
        if (b & 0xf0 == 0x90) return .{ .array = b & 0x0f };

        // fixstr: 101xxxxx
        if (b & 0xe0 == 0xa0) {
            const len: usize = b & 0x1f;
            const s = try self.readSlice(len);
            return .{ .str = s };
        }

        return switch (b) {
            FMT_NIL => .nil,
            FMT_FALSE => .{ .boolean = false },
            FMT_TRUE => .{ .boolean = true },

            FMT_BIN8 => {
                const len: usize = try self.readByte();
                return .{ .bin = try self.readSlice(len) };
            },
            FMT_BIN16 => {
                const len: usize = try self.readU16();
                return .{ .bin = try self.readSlice(len) };
            },
            FMT_BIN32 => {
                const len: usize = try self.readU32();
                return .{ .bin = try self.readSlice(len) };
            },

            FMT_UINT8 => .{ .uint = try self.readByte() },
            FMT_UINT16 => .{ .uint = try self.readU16() },
            FMT_UINT32 => .{ .uint = try self.readU32() },

            FMT_INT8 => .{ .int = @as(i8, @bitCast(try self.readByte())) },
            FMT_INT16 => .{ .int = @as(i16, @bitCast(try self.readU16())) },
            FMT_INT32 => .{ .int = @as(i32, @bitCast(try self.readU32())) },

            FMT_STR8 => {
                const len: usize = try self.readByte();
                return .{ .str = try self.readSlice(len) };
            },
            FMT_STR16 => {
                const len: usize = try self.readU16();
                return .{ .str = try self.readSlice(len) };
            },
            FMT_STR32 => {
                const len: usize = try self.readU32();
                return .{ .str = try self.readSlice(len) };
            },

            FMT_ARRAY16 => .{ .array = try self.readU16() },
            0xdd => .{ .array = try self.readU32() }, // array32
            FMT_MAP16 => .{ .map = try self.readU16() },
            0xdf => .{ .map = try self.readU32() }, // map32

            else => DecodeError.InvalidFormat,
        };
    }

    /// Read a value and expect it to be an unsigned integer.
    pub fn readUint(self: *Decoder) DecodeError!u64 {
        const v = try self.read();
        return switch (v) {
            .uint => |u| u,
            .int => |i| if (i >= 0) @intCast(i) else DecodeError.InvalidFormat,
            else => DecodeError.InvalidFormat,
        };
    }

    /// Read a value and expect it to be a signed integer (accepts uint too).
    pub fn readInt(self: *Decoder) DecodeError!i64 {
        const v = try self.read();
        return switch (v) {
            .int => |i| i,
            .uint => |u| if (u <= @as(u64, @intCast(std.math.maxInt(i64)))) @intCast(u) else DecodeError.Overflow,
            else => DecodeError.InvalidFormat,
        };
    }

    /// Read a value and expect it to be a string.
    pub fn readStr(self: *Decoder) DecodeError![]const u8 {
        const v = try self.read();
        return switch (v) {
            .str => |s| s,
            else => DecodeError.InvalidFormat,
        };
    }

    /// Read a value and expect it to be a boolean.
    pub fn readBool(self: *Decoder) DecodeError!bool {
        const v = try self.read();
        return switch (v) {
            .boolean => |b| b,
            else => DecodeError.InvalidFormat,
        };
    }

    /// Read a value and expect it to be an array header. Returns element count.
    pub fn readArray(self: *Decoder) DecodeError!u32 {
        const v = try self.read();
        return switch (v) {
            .array => |n| n,
            else => DecodeError.InvalidFormat,
        };
    }

    /// Read a value and expect it to be a map header. Returns entry count.
    pub fn readMap(self: *Decoder) DecodeError!u32 {
        const v = try self.read();
        return switch (v) {
            .map => |n| n,
            else => DecodeError.InvalidFormat,
        };
    }

    /// Skip one complete value (including nested structures).
    pub fn skip(self: *Decoder) DecodeError!void {
        const v = try self.read();
        switch (v) {
            .array => |n| {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    try self.skip();
                }
            },
            .map => |n| {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    try self.skip(); // key
                    try self.skip(); // value
                }
            },
            else => {}, // scalars and str/bin already consumed
        }
    }

    /// Try to decode one complete top-level value starting at `pos`.
    /// Returns the byte length consumed, or null if the buffer is incomplete.
    pub fn tryMeasure(data: []const u8) ?usize {
        var d = Decoder.init(data);
        d.skip() catch return null;
        return d.pos;
    }

    // -- Internal byte reading --

    fn readByte(self: *Decoder) DecodeError!u8 {
        if (self.pos >= self.data.len) return DecodeError.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readSlice(self: *Decoder, len: usize) DecodeError![]const u8 {
        if (self.pos + len > self.data.len) return DecodeError.UnexpectedEof;
        const s = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }

    fn readU16(self: *Decoder) DecodeError!u16 {
        const s = try self.readSlice(2);
        return std.mem.bigToNative(u16, @bitCast(s[0..2].*));
    }

    fn readU32(self: *Decoder) DecodeError!u32 {
        const s = try self.readSlice(4);
        return std.mem.bigToNative(u32, @bitCast(s[0..4].*));
    }
};

// ---------- tests ----------

test "encode/decode nil" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeNil();
    var dec = Decoder.init(enc.getWritten());
    const v = try dec.read();
    try std.testing.expectEqual(Value.nil, v);
}

test "encode/decode bool" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeBool(true);
    try enc.writeBool(false);
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(true, (try dec.read()).boolean);
    try std.testing.expectEqual(false, (try dec.read()).boolean);
}

test "encode/decode positive fixint" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeUint(42);
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(u64, 42), (try dec.read()).uint);
}

test "encode/decode negative fixint" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeInt(-5);
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(i64, -5), (try dec.read()).int);
}

test "encode/decode uint8/16/32" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeUint(200);
    try enc.writeUint(30000);
    try enc.writeUint(100000);
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(u64, 200), try dec.readUint());
    try std.testing.expectEqual(@as(u64, 30000), try dec.readUint());
    try std.testing.expectEqual(@as(u64, 100000), try dec.readUint());
}

test "encode/decode int8/16/32" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeInt(-100);
    try enc.writeInt(-1000);
    try enc.writeInt(-100000);
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(i64, -100), try dec.readInt());
    try std.testing.expectEqual(@as(i64, -1000), try dec.readInt());
    try std.testing.expectEqual(@as(i64, -100000), try dec.readInt());
}

test "encode/decode fixstr" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeStr("hello");
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqualStrings("hello", try dec.readStr());
}

test "encode/decode str8" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    // Create a 40-byte string (> 31 so it uses str8).
    const long = "a" ** 40;
    try enc.writeStr(long);
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqualStrings(long, try dec.readStr());
}

test "encode/decode bin" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    const data = &[_]u8{ 0x89, 0x50, 0x4e, 0x47 };
    try enc.writeBin(data);
    var dec = Decoder.init(enc.getWritten());
    const v = try dec.read();
    try std.testing.expectEqualSlices(u8, data, v.bin);
}

test "encode/decode array" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeArrayHeader(3);
    try enc.writeUint(1);
    try enc.writeStr("two");
    try enc.writeBool(true);
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(u32, 3), try dec.readArray());
    try std.testing.expectEqual(@as(u64, 1), try dec.readUint());
    try std.testing.expectEqualStrings("two", try dec.readStr());
    try std.testing.expectEqual(true, try dec.readBool());
}

test "encode/decode map" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeMapHeader(2);
    try enc.writeStr("key1");
    try enc.writeInt(42);
    try enc.writeStr("key2");
    try enc.writeStr("value");
    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(u32, 2), try dec.readMap());
    try std.testing.expectEqualStrings("key1", try dec.readStr());
    try std.testing.expectEqual(@as(i64, 42), try dec.readInt());
    try std.testing.expectEqualStrings("key2", try dec.readStr());
    try std.testing.expectEqualStrings("value", try dec.readStr());
}

test "skip nested structure" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    // [{"a": [1, 2]}, nil]
    try enc.writeArrayHeader(2);
    try enc.writeMapHeader(1);
    try enc.writeStr("a");
    try enc.writeArrayHeader(2);
    try enc.writeUint(1);
    try enc.writeUint(2);
    try enc.writeNil();
    // After skipping the entire structure, decoder should be at the end.
    var dec = Decoder.init(enc.getWritten());
    try dec.skip();
    try std.testing.expectEqual(@as(usize, 0), dec.remaining());
}

test "tryMeasure complete message" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeArrayHeader(2);
    try enc.writeUint(1);
    try enc.writeStr("ok");
    const written = enc.getWritten();
    try std.testing.expectEqual(written.len, Decoder.tryMeasure(written).?);
}

test "tryMeasure incomplete message" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.writeArrayHeader(3);
    try enc.writeUint(1);
    // Missing third element
    try std.testing.expectEqual(@as(?usize, null), Decoder.tryMeasure(enc.getWritten()));
}
