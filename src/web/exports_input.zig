//! Browser IME (EditContext and hidden textarea), paste, clipboard, and
//! UTF-8 <-> UTF-16 offset helpers for wasm32-wasi.
const std = @import("std");
const builtin = @import("builtin");
const utf16 = @import("utf16.zig");
const is_wasi = builtin.os.tag == .wasi;
const web = if (is_wasi) @import("web.zig") else struct {};
const tf_keys = if (is_wasi) @import("../ui/textfield_keys.zig") else struct {};

pub const utf8ToUtf16Index = utf16.utf8ToUtf16Index;
pub const utf16ToUtf8Index = utf16.utf16ToUtf8Index;

pub fn flushPendingKeyToOps(s: anytype) void {
    if (!is_wasi) return;
    if (s.pending_chars.items.len > 0) {
        if (dupeOpString(s, s.pending_chars.items)) |dup| {
            s.pending_ops.append(s.gpa, .{ .insert = dup }) catch {};
        }
        s.pending_chars.clearRetainingCapacity();
        s.pending_text_valid = false;
    }
    if (s.ctx.input.key) |prev| {
        const shift = s.ctx.input.shift;
        const word = s.ctx.input.ctrl or s.ctx.input.alt;
        const Cmd = @TypeOf(tf_keys.commandOf(prev, shift, word).?);
        const cmd: ?Cmd = tf_keys.commandOf(prev, shift, word) orelse switch (prev) {
            .home => if (shift) Cmd.select_line_start else Cmd.move_line_start,
            .end => if (shift) Cmd.select_line_end else Cmd.move_line_end,
            .up => if (shift) Cmd.select_up else Cmd.move_up,
            .down => if (shift) Cmd.select_down else Cmd.move_down,
            .enter => if (s.ctx.focused_multiline) Cmd.insert_newline else null,
            else => null,
        };
        if (cmd) |resolved| {
            s.pending_ops.append(s.gpa, .{ .command = resolved }) catch {};
            s.ctx.input.key = null;
            s.pending_text_valid = false;
        }
    }
}

fn dupeOpString(s: anytype, src: []const u8) ?[]const u8 {
    if (src.len == 0) return "";
    const dup = s.gpa.dupe(u8, src) catch return null;
    s.op_strings.append(s.gpa, dup) catch {
        s.gpa.free(dup);
        return null;
    };
    return dup;
}

fn ensurePendingText(s: anytype) bool {
    if (s.pending_text_valid) return true;
    const ft = s.ctx.focused_text orelse return false;
    s.pending_text.clearRetainingCapacity();
    s.pending_text.appendSlice(s.gpa, ft.text) catch return false;
    s.pending_caret = ft.caret;
    s.pending_anchor = ft.anchor;
    s.pending_marked = ft.marked;
    s.pending_text_valid = true;
    return true;
}

fn normalizePaste(s: anytype, src: []const u8, multiline: bool) ?[]const u8 {
    if (src.len == 0) return "";
    var out = s.gpa.alloc(u8, src.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const b = src[i];
        if (b == '\r') {
            if (i + 1 < src.len and src[i + 1] == '\n') i += 1;
            out[n] = if (multiline) '\n' else ' ';
            n += 1;
        } else if (b == '\n' and !multiline) {
            out[n] = ' ';
            n += 1;
        } else {
            out[n] = b;
            n += 1;
        }
    }
    if (n != out.len) {
        out = s.gpa.realloc(out, n) catch out;
    }
    const slice = out[0..n];
    s.op_strings.append(s.gpa, slice) catch {
        s.gpa.free(slice);
        return null;
    };
    return slice;
}

export fn nanoui_web_input_ptr(len: usize) usize {
    if (!is_wasi) return 0;
    const s = web.active orelse return 0;
    const alloc_len = @max(len, 1);
    s.scratch.resize(s.gpa, alloc_len) catch return 0;
    return @intFromPtr(s.scratch.items.ptr);
}

export fn nanoui_web_ime_set_marked(len: usize, sel_start_utf16: u32, sel_end_utf16: u32) void {
    if (!is_wasi) return;
    const s = web.active orelse return;
    if (s.lost) return;
    flushPendingKeyToOps(s);
    const raw = s.scratch.items[0..@min(len, s.scratch.items.len)];
    const b0 = utf16ToUtf8Index(raw, sel_start_utf16);
    const b1 = utf16ToUtf8Index(raw, sel_end_utf16);
    const lo = @min(b0, b1);
    const hi = @max(b0, b1);
    const dup = dupeOpString(s, raw) orelse return;
    if (ensurePendingText(s)) {
        const r = s.pending_marked orelse [2]usize{ @min(s.pending_caret, s.pending_anchor), @max(s.pending_caret, s.pending_anchor) };
        const r0 = @min(r[0], s.pending_text.items.len);
        const r1 = @min(@max(r0, r[1]), s.pending_text.items.len);
        if (s.pending_text.replaceRange(s.gpa, r0, r1 - r0, raw)) |_| {
            s.pending_marked = if (raw.len == 0) null else .{ r0, r0 + raw.len };
            s.pending_anchor = r0 + lo;
            s.pending_caret = r0 + hi;
        } else |_| s.pending_text_valid = false;
    }
    s.pending_ops.append(s.gpa, .{ .set_marked = .{ .text = dup, .sel_start = lo, .sel_len = hi -| lo } }) catch {};
    s.requestFrame();
}

export fn nanoui_web_ime_commit(len: usize) void {
    if (!is_wasi) return;
    const s = web.active orelse return;
    if (s.lost) return;
    flushPendingKeyToOps(s);
    const raw = s.scratch.items[0..@min(len, s.scratch.items.len)];
    if (raw.len == 0) {
        const had_marked = if (s.pending_text_valid) s.pending_marked != null else if (s.ctx.focused_text) |ft| ft.marked != null else false;
        if (had_marked) {
            if (ensurePendingText(s)) {
                if (s.pending_marked) |m| {
                    const r0 = @min(m[0], s.pending_text.items.len);
                    const r1 = @min(@max(r0, m[1]), s.pending_text.items.len);
                    if (s.pending_text.replaceRange(s.gpa, r0, r1 - r0, "")) |_| {
                        s.pending_caret = r0;
                        s.pending_anchor = r0;
                        s.pending_marked = null;
                    } else |_| s.pending_text_valid = false;
                }
            }
            s.pending_ops.append(s.gpa, .{ .insert = "" }) catch {};
            s.requestFrame();
        }
        return;
    }
    const dup = dupeOpString(s, raw) orelse return;
    if (ensurePendingText(s)) {
        const r = s.pending_marked orelse [2]usize{ @min(s.pending_caret, s.pending_anchor), @max(s.pending_caret, s.pending_anchor) };
        const r0 = @min(r[0], s.pending_text.items.len);
        const r1 = @min(@max(r0, r[1]), s.pending_text.items.len);
        if (s.pending_text.replaceRange(s.gpa, r0, r1 - r0, raw)) |_| {
            s.pending_marked = null;
            s.pending_caret = r0 + raw.len;
            s.pending_anchor = s.pending_caret;
        } else |_| s.pending_text_valid = false;
    }
    s.pending_ops.append(s.gpa, .{ .insert = dup }) catch {};
    s.requestFrame();
}

export fn nanoui_web_ime_unmark() void {
    if (!is_wasi) return;
    const s = web.active orelse return;
    if (s.lost) return;
    flushPendingKeyToOps(s);
    if (s.pending_text_valid) s.pending_marked = null;
    s.pending_ops.append(s.gpa, .unmark) catch {};
    s.requestFrame();
}

export fn nanoui_web_ime_select(anchor_utf16: u32, caret_utf16: u32) void {
    if (!is_wasi) return;
    const s = web.active orelse return;
    if (s.lost) return;
    flushPendingKeyToOps(s);
    if (!ensurePendingText(s)) return;
    const a = utf16ToUtf8Index(s.pending_text.items, anchor_utf16);
    const b = utf16ToUtf8Index(s.pending_text.items, caret_utf16);
    s.pending_anchor = a;
    s.pending_caret = b;
    s.pending_marked = null;
    s.pending_ops.append(s.gpa, .{ .select = .{ .anchor = a, .caret = b } }) catch {};
    s.requestFrame();
}

export fn nanoui_web_ime_replace_utf16(start_utf16: u32, end_utf16: u32, len: usize) void {
    if (!is_wasi) return;
    const s = web.active orelse return;
    if (s.lost) return;
    flushPendingKeyToOps(s);
    const raw = s.scratch.items[0..@min(len, s.scratch.items.len)];
    const dup = dupeOpString(s, raw) orelse return;
    if (ensurePendingText(s)) {
        const a = utf16ToUtf8Index(s.pending_text.items, start_utf16);
        const b = utf16ToUtf8Index(s.pending_text.items, end_utf16);
        const lo = @min(a, b);
        const hi = @max(a, b);
        const cur_lo = @min(s.pending_caret, s.pending_anchor);
        const cur_hi = @max(s.pending_caret, s.pending_anchor);
        if (lo != cur_lo or hi != cur_hi or s.pending_marked != null) {
            s.pending_ops.append(s.gpa, .{ .select = .{ .anchor = lo, .caret = hi } }) catch {};
        }
        if (s.pending_text.replaceRange(s.gpa, lo, hi - lo, raw)) |_| {
            s.pending_marked = null;
            s.pending_caret = lo + raw.len;
            s.pending_anchor = s.pending_caret;
        } else |_| s.pending_text_valid = false;
    } else if (start_utf16 != 0 or end_utf16 != 0) {
        s.pending_ops.append(s.gpa, .{ .select = .{ .anchor = 0, .caret = 0 } }) catch {};
    }
    s.pending_ops.append(s.gpa, .{ .insert = dup }) catch {};
    s.requestFrame();
}

export fn nanoui_web_paste(len: usize) void {
    if (!is_wasi) return;
    const s = web.active orelse return;
    if (s.lost) return;
    flushPendingKeyToOps(s);
    const raw = s.scratch.items[0..@min(len, s.scratch.items.len)];
    const dup = normalizePaste(s, raw, s.ctx.focused_multiline) orelse return;
    if (ensurePendingText(s)) {
        const r = s.pending_marked orelse [2]usize{ @min(s.pending_caret, s.pending_anchor), @max(s.pending_caret, s.pending_anchor) };
        const r0 = @min(r[0], s.pending_text.items.len);
        const r1 = @min(@max(r0, r[1]), s.pending_text.items.len);
        if (s.pending_text.replaceRange(s.gpa, r0, r1 - r0, dup)) |_| {
            s.pending_marked = null;
            s.pending_caret = r0 + dup.len;
            s.pending_anchor = s.pending_caret;
        } else |_| s.pending_text_valid = false;
    }
    s.ctx.paste_op = true;
    s.pending_ops.append(s.gpa, .{ .insert = dup }) catch {};
    s.requestFrame();
}

export fn nanoui_web_clipboard_op(is_cut: u32) u32 {
    if (!is_wasi) return 0;
    const s = web.active orelse return 0;
    if (s.lost) return 0;
    s.clipboard_wrote = false;
    if (s.ctx.focused_text != null) {
        flushPendingKeyToOps(s);
        s.pending_ops.append(s.gpa, .{ .command = if (is_cut != 0) .cut else .copy }) catch return 0;
        return 2;
    }
    if (is_cut == 0 and s.ctx.selection.text.items.len > 0) {
        s.ctx.clipboard.write(s.ctx.clipboard.ctx, s.ctx.selection.text.items);
        return 1;
    }
    s.ctx.input.shortcut = .{ .key = if (is_cut != 0) 'x' else 'c', .ctrl = true };
    return 2;
}

export fn nanoui_web_ime_info(out_ptr: [*]u32) u32 {
    if (!is_wasi) return 0;
    const s = web.active orelse return 0;
    const ft = s.ctx.focused_text orelse return 0;
    const lo = @min(ft.anchor, ft.caret);
    const hi = @max(ft.anchor, ft.caret);
    const rect = ft.clause_rect orelse ft.caret_rect;
    var flags: u32 = 0;
    if (s.ctx.focused_password) flags |= 1;
    if (s.ctx.focused_multiline) flags |= 2;
    if (ft.marked != null) flags |= 4;
    if (ft.anchor > ft.caret) flags |= 8;
    out_ptr[0] = @truncate(ft.id);
    out_ptr[1] = @truncate(ft.id >> 32);
    out_ptr[2] = utf8ToUtf16Index(ft.text, lo);
    out_ptr[3] = utf8ToUtf16Index(ft.text, hi);
    out_ptr[4] = @bitCast(rect.x);
    out_ptr[5] = @bitCast(rect.y);
    out_ptr[6] = @bitCast(rect.w);
    out_ptr[7] = @bitCast(rect.h);
    out_ptr[8] = flags;
    out_ptr[9] = @intCast(ft.text.len);
    return 1;
}

export fn nanoui_web_ime_text() usize {
    if (!is_wasi) return 0;
    const s = web.active orelse return 0;
    const ft = s.ctx.focused_text orelse return 0;
    if (ft.text.len == 0) return 0;
    return @intFromPtr(ft.text.ptr);
}

export fn nanoui_web_cursor() u32 {
    if (!is_wasi) return 0;
    const s = web.active orelse return 0;
    const c = &s.ctx;
    const cur: @TypeOf(c.cursor.?) = c.cursor orelse if (c.cursor_text) .text else if (c.cursor_hand) .hand else .arrow;
    return @backingInt(cur);
}
