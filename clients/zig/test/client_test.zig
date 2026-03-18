/// client_test.zig -- Tests for the kgd Zig client library.
///
/// These tests exercise type construction, protocol encoding/decoding,
/// and anchor serialization without requiring a running daemon.
const std = @import("std");
const kgd = @import("kgd");

// ---------- Type construction tests ----------

test "Color default" {
    const c = kgd.Color{};
    try std.testing.expectEqual(@as(u16, 0), c.r);
    try std.testing.expectEqual(@as(u16, 0), c.g);
    try std.testing.expectEqual(@as(u16, 0), c.b);
}

test "Color values" {
    const c = kgd.Color{ .r = 65535, .g = 32768, .b = 0 };
    try std.testing.expectEqual(@as(u16, 65535), c.r);
    try std.testing.expectEqual(@as(u16, 32768), c.g);
    try std.testing.expectEqual(@as(u16, 0), c.b);
}

test "Anchor default" {
    const a = kgd.Anchor{};
    try std.testing.expectEqual(kgd.AnchorType.absolute, a.type);
    try std.testing.expectEqual(@as(i32, 0), a.row);
    try std.testing.expectEqual(@as(i32, 0), a.col);
    try std.testing.expectEqual(@as(i32, 0), a.win_id);
    try std.testing.expectEqual(@as(i32, 0), a.buf_line);
    try std.testing.expectEqualStrings("", a.pane_id);
}

test "Anchor absolute mapCount" {
    const a = kgd.Anchor{ .type = .absolute, .row = 5, .col = 10 };
    try std.testing.expectEqual(@as(u32, 3), a.mapCount());
}

test "Anchor omits zero fields mapCount" {
    const a = kgd.Anchor{ .type = .absolute };
    try std.testing.expectEqual(@as(u32, 1), a.mapCount());
}

test "Anchor pane mapCount" {
    const a = kgd.Anchor{ .type = .pane, .pane_id = "%0", .row = 2, .col = 3 };
    try std.testing.expectEqual(@as(u32, 4), a.mapCount());
}

test "Anchor nvim_win mapCount" {
    const a = kgd.Anchor{ .type = .nvim_win, .win_id = 1000, .buf_line = 5 };
    try std.testing.expectEqual(@as(u32, 3), a.mapCount());
}

test "AnchorType string round-trip" {
    inline for (.{ .absolute, .pane, .nvim_win }) |at| {
        const typed: kgd.AnchorType = at;
        const s = typed.toString();
        const parsed = kgd.AnchorType.fromString(s);
        try std.testing.expectEqual(at, parsed.?);
    }
}

test "AnchorType fromString unknown" {
    try std.testing.expectEqual(@as(?kgd.AnchorType, null), kgd.AnchorType.fromString("bogus"));
}

test "PlaceOpts default" {
    const o = kgd.PlaceOpts{};
    try std.testing.expectEqual(@as(i32, 0), o.src_x);
    try std.testing.expectEqual(@as(i32, 0), o.z_index);
}

test "StatusResult default" {
    const s = kgd.StatusResult{};
    try std.testing.expectEqual(@as(i32, 0), s.clients);
    try std.testing.expectEqual(@as(i32, 0), s.placements);
}

test "PlacementInfo default" {
    const p = kgd.PlacementInfo{};
    try std.testing.expectEqual(@as(u32, 0), p.placement_id);
    try std.testing.expectEqual(false, p.visible);
}

test "HelloResult default" {
    const h = kgd.HelloResult{};
    try std.testing.expectEqualStrings("", h.client_id);
    try std.testing.expectEqual(@as(i32, 0), h.cols);
    try std.testing.expectEqual(false, h.in_tmux);
}

test "Options default" {
    const o = kgd.Options{};
    try std.testing.expectEqualStrings("", o.socket_path);
    try std.testing.expectEqualStrings("", o.client_type);
}

// ---------- Protocol encoding/decoding tests ----------

test "encode and decode request message" {
    const allocator = std.testing.allocator;
    var enc = kgd.Encoder.init(allocator);
    defer enc.deinit();

    // Encode: [0, 1, "hello", [{...}]]
    try enc.writeArrayHeader(4);
    try enc.writeUint(0); // request
    try enc.writeUint(1); // msgid
    try enc.writeStr("hello");
    try enc.writeArrayHeader(1);
    try enc.writeMapHeader(2);
    try enc.writeStr("client_type");
    try enc.writeStr("test");
    try enc.writeStr("pid");
    try enc.writeInt(12345);

    var dec = kgd.Decoder.init(enc.getWritten());

    try std.testing.expectEqual(@as(u32, 4), try dec.readArray());
    try std.testing.expectEqual(@as(u64, 0), try dec.readUint());
    try std.testing.expectEqual(@as(u64, 1), try dec.readUint());
    try std.testing.expectEqualStrings("hello", try dec.readStr());
    try std.testing.expectEqual(@as(u32, 1), try dec.readArray());
    try std.testing.expectEqual(@as(u32, 2), try dec.readMap());
    try std.testing.expectEqualStrings("client_type", try dec.readStr());
    try std.testing.expectEqualStrings("test", try dec.readStr());
    try std.testing.expectEqualStrings("pid", try dec.readStr());
    try std.testing.expectEqual(@as(i64, 12345), try dec.readInt());
    try std.testing.expectEqual(@as(usize, 0), dec.remaining());
}

test "encode and decode response message" {
    const allocator = std.testing.allocator;
    var enc = kgd.Encoder.init(allocator);
    defer enc.deinit();

    // Encode: [1, 1, nil, {"handle": 42}]
    try enc.writeArrayHeader(4);
    try enc.writeUint(1); // response
    try enc.writeUint(1); // msgid
    try enc.writeNil(); // no error
    try enc.writeMapHeader(1);
    try enc.writeStr("handle");
    try enc.writeUint(42);

    var dec = kgd.Decoder.init(enc.getWritten());

    try std.testing.expectEqual(@as(u32, 4), try dec.readArray());
    try std.testing.expectEqual(@as(u64, 1), try dec.readUint());
    try std.testing.expectEqual(@as(u64, 1), try dec.readUint());

    const err_val = try dec.read();
    try std.testing.expectEqual(kgd.Value.nil, err_val);

    try std.testing.expectEqual(@as(u32, 1), try dec.readMap());
    try std.testing.expectEqualStrings("handle", try dec.readStr());
    try std.testing.expectEqual(@as(u64, 42), try dec.readUint());
}

test "encode and decode notification message" {
    const allocator = std.testing.allocator;
    var enc = kgd.Encoder.init(allocator);
    defer enc.deinit();

    // Encode: [2, "evicted", [{"handle": 7}]]
    try enc.writeArrayHeader(3);
    try enc.writeUint(2); // notification
    try enc.writeStr("evicted");
    try enc.writeArrayHeader(1);
    try enc.writeMapHeader(1);
    try enc.writeStr("handle");
    try enc.writeUint(7);

    var dec = kgd.Decoder.init(enc.getWritten());

    try std.testing.expectEqual(@as(u32, 3), try dec.readArray());
    try std.testing.expectEqual(@as(u64, 2), try dec.readUint());
    try std.testing.expectEqualStrings("evicted", try dec.readStr());
    try std.testing.expectEqual(@as(u32, 1), try dec.readArray());
    try std.testing.expectEqual(@as(u32, 1), try dec.readMap());
    try std.testing.expectEqualStrings("handle", try dec.readStr());
    try std.testing.expectEqual(@as(u64, 7), try dec.readUint());
}

test "binary data round-trip" {
    const allocator = std.testing.allocator;
    var enc = kgd.Encoder.init(allocator);
    defer enc.deinit();

    const png_header = &[_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    try enc.writeBin(png_header);

    var dec = kgd.Decoder.init(enc.getWritten());
    const val = try dec.read();
    try std.testing.expectEqualSlices(u8, png_header, val.bin);
}

test "message framing with tryMeasure" {
    const allocator = std.testing.allocator;

    // Encode two complete messages back-to-back.
    var enc = kgd.Encoder.init(allocator);
    defer enc.deinit();

    // Message 1: [1, 0, nil, {"handle": 1}]
    try enc.writeArrayHeader(4);
    try enc.writeUint(1);
    try enc.writeUint(0);
    try enc.writeNil();
    try enc.writeMapHeader(1);
    try enc.writeStr("handle");
    try enc.writeUint(1);

    const msg1_len = enc.getWritten().len;

    // Message 2: [2, "evicted", [{"handle": 1}]]
    try enc.writeArrayHeader(3);
    try enc.writeUint(2);
    try enc.writeStr("evicted");
    try enc.writeArrayHeader(1);
    try enc.writeMapHeader(1);
    try enc.writeStr("handle");
    try enc.writeUint(1);

    const data = enc.getWritten();

    // First message measurement.
    const m1 = kgd.Decoder.tryMeasure(data);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(msg1_len, m1.?);

    // Second message measurement.
    const m2 = kgd.Decoder.tryMeasure(data[msg1_len..]);
    try std.testing.expect(m2 != null);
    try std.testing.expectEqual(data.len - msg1_len, m2.?);
}

test "error response encoding" {
    const allocator = std.testing.allocator;
    var enc = kgd.Encoder.init(allocator);
    defer enc.deinit();

    // Encode: [1, 5, {"message": "not found"}, nil]
    try enc.writeArrayHeader(4);
    try enc.writeUint(1); // response
    try enc.writeUint(5); // msgid
    try enc.writeMapHeader(1);
    try enc.writeStr("message");
    try enc.writeStr("not found");
    try enc.writeNil(); // result

    var dec = kgd.Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(u32, 4), try dec.readArray());
    try std.testing.expectEqual(@as(u64, 1), try dec.readUint());
    try std.testing.expectEqual(@as(u64, 5), try dec.readUint());
    // Error field is a map.
    const err_val = try dec.read();
    try std.testing.expectEqual(@as(u32, 1), err_val.map);
    try std.testing.expectEqualStrings("message", try dec.readStr());
    try std.testing.expectEqualStrings("not found", try dec.readStr());
    // Result is nil.
    try std.testing.expectEqual(kgd.Value.nil, try dec.read());
}
