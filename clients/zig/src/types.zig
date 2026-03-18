/// types.zig -- Data types for the kgd client protocol.
const std = @import("std");

/// RGB color with 16-bit per channel precision.
pub const Color = struct {
    r: u16 = 0,
    g: u16 = 0,
    b: u16 = 0,
};

/// Anchor type for placement positioning.
pub const AnchorType = enum {
    absolute,
    pane,
    nvim_win,

    pub fn toString(self: AnchorType) []const u8 {
        return switch (self) {
            .absolute => "absolute",
            .pane => "pane",
            .nvim_win => "nvim_win",
        };
    }

    pub fn fromString(s: []const u8) ?AnchorType {
        if (std.mem.eql(u8, s, "absolute")) return .absolute;
        if (std.mem.eql(u8, s, "pane")) return .pane;
        if (std.mem.eql(u8, s, "nvim_win")) return .nvim_win;
        return null;
    }
};

/// Describes a logical position for a placement.
/// Zero-valued optional fields are omitted during serialization.
pub const Anchor = struct {
    type: AnchorType = .absolute,
    pane_id: []const u8 = "",
    win_id: i32 = 0,
    buf_line: i32 = 0,
    row: i32 = 0,
    col: i32 = 0,

    /// Count the number of map entries needed for serialization (non-zero fields).
    pub fn mapCount(self: Anchor) u32 {
        var count: u32 = 1; // "type" is always present
        if (self.pane_id.len > 0) count += 1;
        if (self.win_id != 0) count += 1;
        if (self.buf_line != 0) count += 1;
        if (self.row != 0) count += 1;
        if (self.col != 0) count += 1;
        return count;
    }
};

/// Optional parameters for the place method.
pub const PlaceOpts = struct {
    src_x: i32 = 0,
    src_y: i32 = 0,
    src_w: i32 = 0,
    src_h: i32 = 0,
    z_index: i32 = 0,
};

/// Describes a single active placement (returned by list).
pub const PlacementInfo = struct {
    placement_id: u32 = 0,
    client_id: []const u8 = "",
    handle: u32 = 0,
    visible: bool = false,
    row: i32 = 0,
    col: i32 = 0,
};

/// Daemon status information (returned by status).
pub const StatusResult = struct {
    clients: i32 = 0,
    placements: i32 = 0,
    images: i32 = 0,
    cols: i32 = 0,
    rows: i32 = 0,
};

/// Result of the hello handshake.
pub const HelloResult = struct {
    client_id: []const u8 = "",
    cols: i32 = 0,
    rows: i32 = 0,
    cell_width: i32 = 0,
    cell_height: i32 = 0,
    in_tmux: bool = false,
    fg: Color = .{},
    bg: Color = .{},
};

/// Options for connecting to the kgd daemon.
pub const Options = struct {
    socket_path: []const u8 = "",
    session_id: []const u8 = "",
    client_type: []const u8 = "",
    label: []const u8 = "",
    /// Process ID sent in the hello handshake. Set to 0 to auto-detect.
    pid: i32 = 0,
};

/// Notification callback function types.
pub const EvictedCallback = *const fn (handle: u32, userdata: ?*anyopaque) void;
pub const TopologyCallback = *const fn (cols: i32, rows: i32, cell_width: i32, cell_height: i32, userdata: ?*anyopaque) void;
pub const VisibilityCallback = *const fn (placement_id: u32, visible: bool, userdata: ?*anyopaque) void;
pub const ThemeCallback = *const fn (fg: Color, bg: Color, userdata: ?*anyopaque) void;
