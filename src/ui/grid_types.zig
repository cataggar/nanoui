//! 2D CSS-style Grid track and placement definitions (`layout_grid.zig`).
const std = @import("std");

pub const Align = enum { start, center, end, stretch };

/// One column or row track of a `Grid`.
pub const Track = union(enum) {
    /// Sized from the intrinsic content of the items placed in it.
    auto,
    /// Exactly this many points (`>= 0`).
    fixed: f32,
    /// Proportional share of the free room after `fixed` and `auto` tracks.
    fr: f32,

    pub fn px(v: f32) Track {
        return .{ .fixed = v };
    }

    pub fn flex(weight: f32) Track {
        return .{ .fr = weight };
    }
};

/// A 2D Grid template attached to `Style.grid`.
pub const Grid = struct {
    cols: []const Track = &.{},
    rows: []const Track = &.{},
    /// Separate vertical gap between rows; when null, `Style.gap` is used.
    row_gap: ?f32 = null,
    /// Separate horizontal gap between columns; when null, `Style.gap` is used.
    col_gap: ?f32 = null,
    /// Horizontal cell alignment for non-`.fill` children (CSS `justify-items`).
    justify_items: Align = .stretch,
    /// Vertical cell alignment override; when null, `Style.align_items` is used
    /// if explicitly set, otherwise `.stretch` (CSS `align-items` Grid default).
    align_items: ?Align = null,
};

/// Sentinel meaning an item's row or column is chosen by the auto-placement cursor.
pub const auto_place: u16 = std.math.maxInt(u16);

/// Where a child sits inside a parent `Grid`, and how many tracks it spans.
pub const GridPlacement = struct {
    row: u16 = auto_place,
    col: u16 = auto_place,
    row_span: u16 = 1,
    col_span: u16 = 1,
};
