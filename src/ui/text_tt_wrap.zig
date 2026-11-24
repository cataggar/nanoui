//! Portable TrueType greedy line breaking and `xAt` pen lookup (`text_tt.zig`).
const std = @import("std");
const types = @import("types.zig");
const utf8 = @import("utf8.zig");
const cjk_break = @import("cjk_break.zig");
const text_tt = @import("text_tt.zig");
const Layout = text_tt.Layout;
const Line = text_tt.Line;
const TextSystem = text_tt.TextSystem;

/// The pen position at byte `at` of a layout.
pub fn xAt(lay: Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

/// Greedy line breaking over a shaped paragraph.
pub fn breakLines(gpa: std.mem.Allocator, lines: *std.ArrayList(Line), s: []const u8, lay: Layout, max: f32) !void {
    var start: usize = 0;
    while (start < s.len) {
        const x0 = xAt(lay, start);
        var end = start;
        var last_break: ?usize = null;
        var previous: u21 = 0;
        var i = start;
        while (i < s.len) {
            if (s[i] == '\n') {
                end = i;
                break;
            }
            const n = utf8.seqLen(s[i]);
            const next = @min(s.len, i + n);
            const current = cjk_break.codepoint(s[i..next]);
            if (i > start and cjk_break.between(previous, current)) last_break = i;
            previous = current;
            // A character that ends past the line, unless it is a space.
            if (s[i] != ' ' and xAt(lay, next) - x0 > max and i > start) {
                end = last_break orelse i;
                break;
            }
            if (s[i] == ' ' or s[i] == '-' or s[i] == '/') last_break = next;
            i = next;
            end = i;
        }
        const trimmed = std.mem.trimEnd(u8, s[start..end], " \t\r");
        try lines.append(gpa, .{ .start = start, .end = start + trimmed.len, .width = xAt(lay, start + trimmed.len) - x0 });
        var next_start = end;
        if (next_start < s.len and s[next_start] == '\n') next_start += 1;
        while (next_start < s.len and s[next_start] == ' ') next_start += 1;
        if (next_start == start) next_start += 1;
        start = next_start;
        if (start == s.len and end < s.len and s[end] == '\n') try lines.append(gpa, .{ .start = s.len, .end = s.len, .width = 0 });
    }
}

test "a character cut off at a string's end is shaped, not decoded short" {
    var ts = TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    // "a→" with the arrow's last byte gone, as a span can end.
    const w = ts.width("a\xe2\x86", .{ .size = 13 });
    try std.testing.expect(w > 0);
}

test "a closing mark takes the character before it to the next line" {
    var ts = TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const s = "中文中文中文。";
    const style: types.TextStyle = .{ .size = 13 };
    const lines = ts.wrap(s, style, ts.width(s, style) - ts.width("。", style) / 2);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("文。", s[lines[1].start..lines[1].end]);
}

test "ideographs after a Latin word fill the line instead of breaking at its space" {
    var ts = TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const s = "连接 Agent 或 API，然后继续发送中文消息并等待回复完成";
    const first = "连接 Agent 或 API，然后继续";
    const style: types.TextStyle = .{ .size = 13 };
    const lines = ts.wrap(s, style, ts.width(first, style) + 1);
    try std.testing.expect(lines.len >= 2);
    try std.testing.expectEqualStrings(first, s[lines[0].start..lines[0].end]);
}

test "Latin text still wraps only at spaces" {
    var ts = TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const s = "alpha beta gamma";
    const style: types.TextStyle = .{ .size = 13 };
    const lines = ts.wrap(s, style, ts.width("alpha beta", style) + 1);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("gamma", s[lines[1].start..lines[1].end]);
}
