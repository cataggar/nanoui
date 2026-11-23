//! 2D CSS-style Grid layout in two passes: sparse row-major cell placement,
//! `fixed` / `auto` / `fr` column and row track sizing with multi-track span
//! distribution, width-dependent re-measurement for wrapping text, and
//! cumulative pixel-snapped track boundaries so adjacent and spanning cells
//! share exact edges without 1px seams.
const std = @import("std");
const types = @import("types.zig");
const grid_types = @import("grid_types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;
const layout = @import("layout.zig");

pub const MeasureResult = struct {
    size: types.Size,
    flexible: bool,
};

const Item = struct {
    node: u32,
    row: usize = 0,
    col: usize = 0,
    rs: usize = 1,
    cs: usize = 1,
    measured: bool = false,
    measured_avail_w: f32 = 0,
    size: types.Size = .{},
};

const Occupancy = struct {
    cols: usize,
    max_row: usize = 0,
    cells: std.ArrayListUnmanaged(bool) = .empty,

    fn ensureRows(o: *Occupancy, arena: std.mem.Allocator, rows: usize) void {
        const need = rows * o.cols;
        if (need <= o.cells.items.len) return;
        const old = o.cells.items.len;
        o.cells.resize(arena, need) catch unreachable;
        @memset(o.cells.items[old..need], false);
    }

    fn fits(o: *const Occupancy, r: usize, col: usize, rs: usize, cs: usize) bool {
        if (col + cs > o.cols) return false;
        const rows_alloc = o.cells.items.len / o.cols;
        if (r >= rows_alloc) return true;
        const check_end = @min(r + rs, rows_alloc);
        for (r..check_end) |rr| {
            const row_off = rr * o.cols;
            for (col..col + cs) |cc| {
                if (o.cells.items[row_off + cc]) return false;
            }
        }
        return true;
    }

    fn mark(o: *Occupancy, arena: std.mem.Allocator, r: usize, col: usize, rs: usize, cs: usize) void {
        const r_end = r + rs;
        const c_end = @min(o.cols, col + cs);
        o.ensureRows(arena, r_end);
        for (r..r_end) |rr| {
            const row_off = rr * o.cols;
            for (col..c_end) |cc| o.cells.items[row_off + cc] = true;
        }
        o.max_row = @max(o.max_row, r_end);
    }
};

fn colTrack(g: *const types.Grid, col: usize) types.Track {
    return if (col < g.cols.len) g.cols[col] else .auto;
}

fn rowTrack(g: *const types.Grid, r: usize) types.Track {
    return if (r < g.rows.len) g.rows[r] else .auto;
}

fn spanSum(tracks: []const f32, start: usize, span: usize, gap: f32) f32 {
    var total: f32 = 0;
    for (tracks[start .. start + span]) |v| total += v;
    if (span > 1) total += gap * @as(f32, @floatFromInt(span - 1));
    return total;
}

fn placeItems(c: *Context, arena: std.mem.Allocator, first_child: u32, g: *const types.Grid) struct { items: []Item, cols: usize, rows: usize } {
    var flow_count: usize = 0;
    var child = first_child;
    while (child != none) : (child = c.node(child).next) {
        if (!c.node(child).style.absolute) flow_count += 1;
    }
    const items = arena.alloc(Item, flow_count) catch unreachable;
    var num_cols: usize = g.cols.len;
    var idx: usize = 0;
    child = first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        const a = ch.style.grid_area;
        const rs: usize = @max(1, @as(usize, a.row_span));
        const cs: usize = @max(1, @as(usize, a.col_span));
        if (a.col != grid_types.auto_place) {
            num_cols = @max(num_cols, @as(usize, a.col) + cs);
        } else {
            num_cols = @max(num_cols, cs);
        }
        items[idx] = .{ .node = child, .rs = rs, .cs = cs };
        idx += 1;
    }
    if (num_cols == 0 and flow_count > 0) num_cols = 1;
    if (num_cols == 0) return .{ .items = items, .cols = 0, .rows = g.rows.len };

    var occ: Occupancy = .{ .cols = num_cols };

    // Pass 1: definite row and definite column.
    for (items) |*it| {
        const a = c.node(it.node).style.grid_area;
        if (a.row != grid_types.auto_place and a.col != grid_types.auto_place) {
            it.row = a.row;
            it.col = a.col;
            occ.mark(arena, it.row, it.col, it.rs, it.cs);
        }
    }
    // Pass 2: definite row, auto column.
    for (items) |*it| {
        const a = c.node(it.node).style.grid_area;
        if (a.row != grid_types.auto_place and a.col == grid_types.auto_place) {
            it.row = a.row;
            var col: usize = 0;
            while (col + it.cs <= num_cols and !occ.fits(it.row, col, it.rs, it.cs)) : (col += 1) {}
            if (col + it.cs > num_cols) col = 0;
            it.col = col;
            occ.mark(arena, it.row, it.col, it.rs, it.cs);
        }
    }
    // Pass 3: auto row (with definite or auto column), sparse row-major cursor.
    var cur_r: usize = 0;
    var cur_c: usize = 0;
    for (items) |*it| {
        const a = c.node(it.node).style.grid_area;
        if (a.row != grid_types.auto_place) continue;
        if (a.col != grid_types.auto_place) {
            const col: usize = a.col;
            if (cur_c > col) {
                cur_r += 1;
                cur_c = 0;
            }
            while (!occ.fits(cur_r, col, it.rs, it.cs)) cur_r += 1;
            it.row = cur_r;
            it.col = col;
            occ.mark(arena, it.row, it.col, it.rs, it.cs);
            cur_c = col + it.cs;
            if (cur_c >= num_cols) {
                cur_r += 1;
                cur_c = 0;
            }
        } else {
            while (true) {
                if (cur_c + it.cs > num_cols) {
                    cur_r += 1;
                    cur_c = 0;
                }
                if (occ.fits(cur_r, cur_c, it.rs, it.cs)) {
                    it.row = cur_r;
                    it.col = cur_c;
                    occ.mark(arena, it.row, it.col, it.rs, it.cs);
                    cur_c += it.cs;
                    if (cur_c >= num_cols) {
                        cur_r += 1;
                        cur_c = 0;
                    }
                    break;
                }
                cur_c += 1;
            }
        }
    }

    return .{ .items = items, .cols = num_cols, .rows = @max(g.rows.len, occ.max_row) };
}

fn ensureMeasured(c: *Context, it: *Item, avail_w: f32, do_measure: bool) types.Size {
    if (it.measured) return it.size;
    if (do_measure) {
        it.size = layout.measure(c, it.node, avail_w);
    } else {
        it.size = c.node(it.node).measured;
    }
    it.measured = true;
    it.measured_avail_w = avail_w;
    return it.size;
}

const SolvedTracks = struct {
    col_w: []f32,
    row_h: []f32,
    non_fr_cols_w: f32,
    total_cols_w: f32,
    total_rows_h: f32,
    has_fr_cols: bool,
    child_flexible: bool,
};

fn solve(c: *Context, index: u32, avail_w: f32, avail_h: ?f32, is_arrange: bool) struct { items: []Item, tracks: SolvedTracks } {
    const arena = c.alloc();
    const n = c.node(index);
    const st = &n.style;
    const g = st.grid.?;
    const col_gap = @max(0, g.col_gap orelse st.gap);
    const row_gap = @max(0, g.row_gap orelse st.gap);

    if (!is_arrange) {
        var ch_idx = n.first_child;
        while (ch_idx != none) : (ch_idx = c.node(ch_idx).next) {
            if (c.node(ch_idx).style.absolute) {
                _ = layout.measure(c, ch_idx, if (st.scroll_x) std.math.inf(f32) else avail_w);
            }
        }
    }

    const placed = placeItems(c, arena, n.first_child, g);
    const items = placed.items;
    const num_cols = placed.cols;
    const num_rows = placed.rows;

    const col_w = arena.alloc(f32, num_cols) catch unreachable;
    @memset(col_w, 0);
    const row_h = arena.alloc(f32, num_rows) catch unreachable;
    @memset(row_h, 0);

    const col_gaps = if (num_cols > 1) col_gap * @as(f32, @floatFromInt(num_cols - 1)) else 0;
    var fixed_cols_w: f32 = 0;
    var fr_col_total: f32 = 0;
    for (0..num_cols) |col| switch (colTrack(g, col)) {
        .fixed => |px| {
            col_w[col] = @max(0, px);
            fixed_cols_w += col_w[col];
        },
        .fr => |w| fr_col_total += @max(0, w),
        .auto => {},
    };

    const probe_w = if (st.scroll_x) std.math.inf(f32) else avail_w;
    const auto_avail_w = if (std.math.isFinite(probe_w)) @max(0, probe_w - fixed_cols_w - col_gaps) else probe_w;
    const min_col_w = arena.alloc(f32, num_cols) catch unreachable;
    @memcpy(min_col_w, col_w);

    // 1a. Single-column auto tracks.
    for (items) |*it| {
        if (it.cs == 1 and colTrack(g, it.col) == .auto) {
            const ch_flex = c.node(it.node).flexible;
            const s = ensureMeasured(c, it, auto_avail_w, !is_arrange or ch_flex);
            col_w[it.col] = @max(col_w[it.col], s.w);
            const ch = c.node(it.node);
            const rigid = if (ch.flexible and ch.style.width != .px) ch.style.min_width else s.w;
            min_col_w[it.col] = @max(min_col_w[it.col], rigid);
        }
    }
    // 1b. Multi-column spans across auto/fixed tracks (no fr tracks).
    for (items) |*it| {
        if (it.cs <= 1) continue;
        var auto_cnt: usize = 0;
        var has_fr = false;
        var span_fixed: f32 = 0;
        for (it.col..it.col + it.cs) |col| switch (colTrack(g, col)) {
            .auto => auto_cnt += 1,
            .fr => |w| if (w > 0) {
                has_fr = true;
            },
            .fixed => span_fixed += col_w[col],
        };
        if (auto_cnt == 0 or has_fr) continue;
        const internal_gaps = col_gap * @as(f32, @floatFromInt(it.cs - 1));
        const span_probe = if (std.math.isFinite(probe_w)) @max(0, auto_avail_w + span_fixed + internal_gaps) else probe_w;
        const s = ensureMeasured(c, it, span_probe, !is_arrange or c.node(it.node).flexible);
        const cur = spanSum(col_w, it.col, it.cs, col_gap);
        if (s.w > cur) {
            const add = (s.w - cur) / @as(f32, @floatFromInt(auto_cnt));
            const ch = c.node(it.node);
            const rigid_span = !(ch.flexible and ch.style.width != .px);
            for (it.col..it.col + it.cs) |col| {
                if (colTrack(g, col) == .auto) {
                    col_w[col] += add;
                    if (rigid_span) min_col_w[col] = @max(min_col_w[col], col_w[col]);
                }
            }
        }
    }

    var non_fr_cols_w: f32 = col_gaps;
    for (col_w) |w| non_fr_cols_w += w;

    // Shrink flexible auto columns proportionally when wrapping text exceeds container width.
    if (std.math.isFinite(probe_w) and non_fr_cols_w > probe_w) {
        var shrinkable: f32 = 0;
        for (0..num_cols) |col| {
            if (colTrack(g, col) == .auto and col_w[col] > min_col_w[col]) {
                shrinkable += col_w[col] - min_col_w[col];
            }
        }
        if (shrinkable > 0) {
            const excess = @min(shrinkable, non_fr_cols_w - probe_w);
            non_fr_cols_w = col_gaps;
            for (0..num_cols) |col| {
                if (colTrack(g, col) == .auto and col_w[col] > min_col_w[col]) {
                    const room = col_w[col] - min_col_w[col];
                    col_w[col] -= excess * (room / shrinkable);
                }
                non_fr_cols_w += col_w[col];
            }
        }
    }

    // 1c. Fractional column tracks.
    if (fr_col_total > 0) {
        if (std.math.isFinite(probe_w)) {
            const rem_w = @max(0, probe_w - non_fr_cols_w);
            for (0..num_cols) |col| switch (colTrack(g, col)) {
                .fr => |w| col_w[col] = rem_w * @max(0, w) / fr_col_total,
                else => {},
            };
        } else {
            var unit: f32 = 0;
            for (items) |*it| {
                var span_fr: f32 = 0;
                var fixed_auto: f32 = if (it.cs > 1) col_gap * @as(f32, @floatFromInt(it.cs - 1)) else 0;
                for (it.col..it.col + it.cs) |col| switch (colTrack(g, col)) {
                    .fr => |w| span_fr += @max(0, w),
                    else => fixed_auto += col_w[col],
                };
                if (span_fr > 0) {
                    const s = ensureMeasured(c, it, probe_w, !is_arrange);
                    unit = @max(unit, @max(0, s.w - fixed_auto) / span_fr);
                }
            }
            for (0..num_cols) |col| switch (colTrack(g, col)) {
                .fr => |w| col_w[col] = @max(0, w) * unit,
                else => {},
            };
        }
    }

    // 2. Measure remaining children at exact resolved cell widths, and re-measure
    // flexible children (wrapping text, nested flexible containers) if needed.
    var child_flexible = false;
    for (items) |*it| {
        const ch = c.node(it.node);
        const span_w = spanSum(col_w, it.col, it.cs, col_gap);
        const stretch_x = ch.style.width == .fill or (g.justify_items == .stretch and ch.style.width == .auto);
        var target_w: f32 = switch (ch.style.width) {
            .px => |v| v,
            .fill => span_w,
            .auto => if (stretch_x) span_w else ensureMeasured(c, it, span_w, !is_arrange).w,
        };
        target_w = std.math.clamp(target_w, ch.style.min_width, @max(ch.style.min_width, ch.style.max_width));

        if (!it.measured) {
            _ = ensureMeasured(c, it, target_w, !is_arrange);
        }
        if (c.node(it.node).flexible and c.node(it.node).style.width != .px) {
            const ref_w = if (is_arrange) c.node(it.node).measured.w else it.measured_avail_w;
            if (@abs(target_w - ref_w) > 0.5) {
                it.size = layout.measure(c, it.node, target_w);
                it.measured_avail_w = target_w;
            }
        }
        if (!st.scroll_x and c.node(it.node).flexible) child_flexible = true;
    }

    // 3a. Fixed and auto row tracks.
    var fr_row_total: f32 = 0;
    for (0..num_rows) |r| switch (rowTrack(g, r)) {
        .fixed => |px| row_h[r] = @max(0, px),
        .fr => |w| fr_row_total += @max(0, w),
        .auto => {},
    };
    for (items) |it| {
        if (it.rs == 1 and rowTrack(g, it.row) == .auto) {
            row_h[it.row] = @max(row_h[it.row], it.size.h);
        }
    }
    for (items) |it| {
        if (it.rs <= 1) continue;
        var auto_cnt: usize = 0;
        var has_fr = false;
        for (it.row..it.row + it.rs) |r| switch (rowTrack(g, r)) {
            .auto => auto_cnt += 1,
            .fr => |w| if (w > 0) {
                has_fr = true;
            },
            .fixed => {},
        };
        if (auto_cnt == 0 or has_fr) continue;
        const cur = spanSum(row_h, it.row, it.rs, row_gap);
        if (it.size.h > cur) {
            const add = (it.size.h - cur) / @as(f32, @floatFromInt(auto_cnt));
            for (it.row..it.row + it.rs) |r| {
                if (rowTrack(g, r) == .auto) row_h[r] += add;
            }
        }
    }

    const row_gaps = if (num_rows > 1) row_gap * @as(f32, @floatFromInt(num_rows - 1)) else 0;
    var non_fr_rows_h: f32 = row_gaps;
    for (row_h) |h| non_fr_rows_h += h;

    // 3b. Fractional row tracks.
    if (fr_row_total > 0) {
        var intrinsic_unit: f32 = 0;
        if (avail_h == null or st.scroll) {
            for (items) |it| {
                var span_fr: f32 = 0;
                var fixed_auto: f32 = if (it.rs > 1) row_gap * @as(f32, @floatFromInt(it.rs - 1)) else 0;
                for (it.row..it.row + it.rs) |r| switch (rowTrack(g, r)) {
                    .fr => |w| span_fr += @max(0, w),
                    else => fixed_auto += row_h[r],
                };
                if (span_fr > 0) intrinsic_unit = @max(intrinsic_unit, @max(0, it.size.h - fixed_auto) / span_fr);
            }
        }
        const unit: f32 = if (avail_h) |ah| blk: {
            const fit_unit = @max(0, ah - non_fr_rows_h) / fr_row_total;
            break :blk if (st.scroll) @max(intrinsic_unit, fit_unit) else fit_unit;
        } else intrinsic_unit;
        for (0..num_rows) |r| switch (rowTrack(g, r)) {
            .fr => |w| row_h[r] = @max(0, w) * unit,
            else => {},
        };
    }

    var total_cols_w: f32 = col_gaps;
    for (col_w) |w| total_cols_w += w;
    var total_rows_h: f32 = row_gaps;
    for (row_h) |h| total_rows_h += h;

    return .{
        .items = items,
        .tracks = .{
            .col_w = col_w,
            .row_h = row_h,
            .non_fr_cols_w = non_fr_cols_w,
            .total_cols_w = total_cols_w,
            .total_rows_h = total_rows_h,
            .has_fr_cols = fr_col_total > 0,
            .child_flexible = child_flexible,
        },
    };
}

pub fn measure(c: *Context, index: u32, inner_w: f32) MeasureResult {
    const st = &c.node(index).style;
    const avail_h: ?f32 = if (st.height == .px) @max(0, st.height.px - st.padding.vertical()) else null;
    const res = solve(c, index, inner_w, avail_h, false);
    const t = res.tracks;
    // When growing inside a Flexbox row (`width == .auto` and `grow > 0`), report
    // non-fr intrinsic base width so sibling `.grow()` items divide free space by weight.
    const w = if (st.width == .auto and st.grow > 0 and t.has_fr_cols) t.non_fr_cols_w else t.total_cols_w;
    return .{
        .size = .{ .w = w, .h = t.total_rows_h },
        .flexible = (t.has_fr_cols or t.child_flexible) and !st.scroll_x,
    };
}

fn snapEdge(v: f32, scale: f32) f32 {
    const sv = v * scale;
    const r = if (sv >= 0) @ceil(sv - 0.5) else @floor(sv + 0.5);
    return r / scale;
}

pub fn arrange(c: *Context, index: u32, rect: types.Rect) void {
    const arena = c.alloc();
    const n = c.node(index);
    const st = &n.style;
    const g = st.grid.?;
    const inner = rect.inset(st.padding);
    const col_gap = @max(0, g.col_gap orelse st.gap);
    const row_gap = @max(0, g.row_gap orelse st.gap);

    const solved = solve(c, index, inner.w, inner.h, true);
    const items = solved.items;
    const t = solved.tracks;
    const num_cols = t.col_w.len;
    const num_rows = t.row_h.len;

    const free_x = inner.w - t.total_cols_w;
    var offset_x: f32 = 0;
    var extra_col_gap: f32 = 0;
    if (!t.has_fr_cols and free_x > 0) switch (st.justify) {
        .start => {},
        .center => offset_x = free_x / 2,
        .end => offset_x = free_x,
        .space_between => if (num_cols > 1) {
            extra_col_gap = free_x / @as(f32, @floatFromInt(num_cols - 1));
        },
    };

    const scroll_y: f32 = if (st.scroll) @import("scroll.zig").arrangeScrollY(c, n, inner.h, t.total_rows_h) else 0;
    var scroll_x: f32 = 0;
    if (st.scroll_x) {
        if (c.scroll_x.getPtr(n.id)) |s| {
            s.* = std.math.clamp(s.*, 0, @max(0, t.total_cols_w - inner.w));
            scroll_x = s.*;
        }
    }

    c.motion.carried -= scroll_y;

    const snap_tracks = c.pixel_snap and c.scale > 0;
    const col_start = arena.alloc(f32, num_cols) catch unreachable;
    const col_end = arena.alloc(f32, num_cols) catch unreachable;
    var cx = inner.x + offset_x - scroll_x;
    for (0..num_cols) |col| {
        const s0 = if (snap_tracks) snapEdge(cx, c.scale) else cx;
        const next_raw = cx + t.col_w[col];
        const s1 = if (snap_tracks) snapEdge(next_raw, c.scale) else next_raw;
        col_start[col] = s0;
        col_end[col] = @max(s0, s1);
        cx = next_raw + col_gap + extra_col_gap;
    }

    const row_start = arena.alloc(f32, num_rows) catch unreachable;
    const row_end = arena.alloc(f32, num_rows) catch unreachable;
    var ry = inner.y - scroll_y;
    for (0..num_rows) |r| {
        const s0 = if (snap_tracks) snapEdge(ry, c.scale) else ry;
        const next_raw = ry + t.row_h[r];
        const s1 = if (snap_tracks) snapEdge(next_raw, c.scale) else next_raw;
        row_start[r] = s0;
        row_end[r] = @max(s0, s1);
        ry = next_raw + row_gap;
    }

    // Arrange absolute children just like Flexbox containers do.
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (!ch.style.absolute) continue;
        if (ch.style.fixed) {
            const w = if (ch.style.width == .fill) c.size.w else ch.measured.w;
            const h = if (ch.style.height == .fill) c.size.h else ch.measured.h;
            layout.arrange(c, child, .{ .x = 0, .y = 0, .w = w, .h = h });
        } else {
            const w = if (ch.style.width == .fill) inner.w else ch.measured.w;
            const h = if (ch.style.height == .fill) inner.h else ch.measured.h;
            layout.arrange(c, child, .{ .x = inner.x - scroll_x, .y = inner.y - scroll_y, .w = w, .h = h });
        }
    }

    const align_x = g.justify_items;
    const align_y: types.Align = g.align_items orelse if (st.align_set or st.align_items != .start) st.align_items else .stretch;

    for (items) |it| {
        const ch = c.node(it.node);
        const cell_x = col_start[it.col];
        const cell_w = @max(0, col_end[it.col + it.cs - 1] - cell_x);
        const cell_y = row_start[it.row];
        const cell_h = @max(0, row_end[it.row + it.rs - 1] - cell_y);

        const stretch_x = ch.style.width == .fill or (align_x == .stretch and ch.style.width == .auto);
        var w = if (stretch_x) cell_w else it.size.w;
        if (ch.style.width == .px) w = ch.style.width.px;
        w = std.math.clamp(w, ch.style.min_width, @max(ch.style.min_width, ch.style.max_width));

        const stretch_y = ch.style.height == .fill or (align_y == .stretch and ch.style.height == .auto);
        var h = if (stretch_y) cell_h else it.size.h;
        if (ch.style.height == .px) h = ch.style.height.px;
        h = std.math.clamp(h, ch.style.min_height, @max(ch.style.min_height, ch.style.max_height));

        const dx: f32 = switch (align_x) {
            .start, .stretch => 0,
            .center => (cell_w - w) / 2,
            .end => cell_w - w,
        };
        const dy: f32 = switch (align_y) {
            .start, .stretch => 0,
            .center => (cell_h - h) / 2,
            .end => cell_h - h,
        };
        const x = if (snap_tracks and dx != 0) snapEdge(cell_x + dx, c.scale) else cell_x + dx;
        const y = if (snap_tracks and dy != 0) snapEdge(cell_y + dy, c.scale) else cell_y + dy;
        layout.arrange(c, it.node, .{ .x = x, .y = y, .w = w, .h = h });
    }
}
