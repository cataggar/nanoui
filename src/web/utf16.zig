//! Platform-free UTF-8 <-> UTF-16 offset conversion for browser IME & EditContext.
const std = @import("std");

/// Counts UTF-16 code units in `utf8[0..@min(byte_idx, utf8.len)]`.
/// Supplementary codepoints (`>= 0x10000`) count as 2 UTF-16 code units; BMP as 1.
pub fn utf8ToUtf16Index(utf8: []const u8, byte_idx: usize) u32 {
    const end = @min(byte_idx, utf8.len);
    var i: usize = 0;
    var units: u32 = 0;
    while (i < end) {
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
            i += 1;
            units +|= 1;
            continue;
        };
        if (i + seq_len > end) break;
        const cp = std.unicode.utf8Decode(utf8[i .. i + seq_len]) catch {
            i += 1;
            units +|= 1;
            continue;
        };
        units +|= if (cp >= 0x10000) 2 else 1;
        i += seq_len;
    }
    return units;
}

/// Maps a UTF-16 code unit offset back to an exact UTF-8 codepoint boundary in `utf8`.
/// Clamps to `utf8.len` and snaps surrogate-interior offsets to the codepoint start.
pub fn utf16ToUtf8Index(utf8: []const u8, utf16_idx: u32) usize {
    var i: usize = 0;
    var units: u32 = 0;
    while (i < utf8.len and units < utf16_idx) {
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
            i += 1;
            units += 1;
            continue;
        };
        if (i + seq_len > utf8.len) break;
        const cp = std.unicode.utf8Decode(utf8[i .. i + seq_len]) catch {
            i += 1;
            units += 1;
            continue;
        };
        const step: u32 = if (cp >= 0x10000) 2 else 1;
        if (units + step > utf16_idx) break;
        units += step;
        i += seq_len;
    }
    return i;
}

test "UTF-8 <-> UTF-16 offset conversion handles ASCII, CJK, and surrogate pairs" {
    try std.testing.expectEqual(@as(u32, 0), utf8ToUtf16Index("", 0));
    try std.testing.expectEqual(@as(usize, 0), utf16ToUtf8Index("", 0));
    try std.testing.expectEqual(@as(usize, 0), utf16ToUtf8Index("", 12));

    const ascii = "hello";
    for (0..ascii.len + 1) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), utf8ToUtf16Index(ascii, i));
        try std.testing.expectEqual(i, utf16ToUtf8Index(ascii, @intCast(i)));
    }

    const cjk = "日本語é"; // 3 + 3 + 3 + 2 = 11 UTF-8 bytes, 4 UTF-16 code units
    const cjk_bytes = [_]usize{ 0, 3, 6, 9, 11 };
    for (cjk_bytes, 0..) |b, u16_i| {
        try std.testing.expectEqual(@as(u32, @intCast(u16_i)), utf8ToUtf16Index(cjk, b));
        try std.testing.expectEqual(b, utf16ToUtf8Index(cjk, @intCast(u16_i)));
    }

    const mixed = "a😀b👨\u{200D}💻c";
    try std.testing.expectEqual(@as(u32, 0), utf8ToUtf16Index(mixed, 0));
    try std.testing.expectEqual(@as(u32, 1), utf8ToUtf16Index(mixed, 1));
    try std.testing.expectEqual(@as(u32, 3), utf8ToUtf16Index(mixed, 5));
    try std.testing.expectEqual(@as(u32, 4), utf8ToUtf16Index(mixed, 6));
    try std.testing.expectEqual(@as(u32, 6), utf8ToUtf16Index(mixed, 10));
    try std.testing.expectEqual(@as(u32, 7), utf8ToUtf16Index(mixed, 13));
    try std.testing.expectEqual(@as(u32, 9), utf8ToUtf16Index(mixed, 17));
    try std.testing.expectEqual(@as(u32, 10), utf8ToUtf16Index(mixed, 18));

    try std.testing.expectEqual(@as(usize, 1), utf16ToUtf8Index(mixed, 1));
    // Mid-surrogate snaps cleanly to start of '😀' (byte 1), never splitting UTF-8.
    try std.testing.expectEqual(@as(usize, 1), utf16ToUtf8Index(mixed, 2));
    try std.testing.expectEqual(@as(usize, 5), utf16ToUtf8Index(mixed, 3));
    try std.testing.expectEqual(@as(usize, 6), utf16ToUtf8Index(mixed, 4));
    try std.testing.expectEqual(@as(usize, 10), utf16ToUtf8Index(mixed, 6));
    try std.testing.expectEqual(@as(usize, 13), utf16ToUtf8Index(mixed, 7));
    try std.testing.expectEqual(@as(usize, 17), utf16ToUtf8Index(mixed, 9));
    try std.testing.expectEqual(@as(usize, 18), utf16ToUtf8Index(mixed, 10));
    try std.testing.expectEqual(@as(usize, 18), utf16ToUtf8Index(mixed, 999));
}

test "UTF-8 <-> UTF-16 helpers never panic on truncated or invalid bytes" {
    const bad = &[_]u8{ 'x', 0xff, 0xf0, 0x9f, 'y' };
    _ = utf8ToUtf16Index(bad, 2);
    _ = utf8ToUtf16Index(bad, bad.len);
    _ = utf8ToUtf16Index(bad, 99);
    _ = utf16ToUtf8Index(bad, 0);
    _ = utf16ToUtf8Index(bad, 3);
    _ = utf16ToUtf8Index(bad, 99);
}
