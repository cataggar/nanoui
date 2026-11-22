//! Verifies that a freestanding WebAssembly module has zero imports and exports the expected symbol.
const std = @import("std");

pub const Summary = struct {
    import_count: u32 = 0,
    first_import_mod: []const u8 = "",
    first_import_name: []const u8 = "",
    found_export: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: embed-wasm-check <module.wasm> [expected_export]\n", .{});
        std.process.exit(2);
    }
    const wasm_path = args[1];
    const expected_export = if (args.len >= 3) args[2] else "nanoui_embed_probe";
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, wasm_path, init.gpa, .limited(64 << 20));
    defer init.gpa.free(data);

    const summary = verifyWasm(data, expected_export) catch |err| {
        std.debug.print("embed-wasm-check: {s}: {t}\n", .{ wasm_path, err });
        std.process.exit(1);
    };
    if (summary.import_count != 0) {
        std.debug.print(
            "embed-wasm-check: {s}: expected 0 wasm imports, found {d} (first: {s}.{s})\n",
            .{ wasm_path, summary.import_count, summary.first_import_mod, summary.first_import_name },
        );
        std.process.exit(1);
    }
    if (!summary.found_export) {
        std.debug.print("embed-wasm-check: {s}: missing required function export '{s}'\n", .{ wasm_path, expected_export });
        std.process.exit(1);
    }
}

pub fn verifyWasm(data: []const u8, expected_export: []const u8) !Summary {
    if (data.len < 8) return error.TruncatedHeader;
    if (!std.mem.eql(u8, data[0..4], "\x00asm")) return error.InvalidMagic;
    if (!std.mem.eql(u8, data[4..8], "\x01\x00\x00\x00")) return error.UnsupportedVersion;

    var summary: Summary = .{};
    var pos: usize = 8;
    while (pos < data.len) {
        const section_id = data[pos];
        pos += 1;
        const payload = try readBytes(data, &pos);
        switch (section_id) {
            2 => {
                var p: usize = 0;
                const count = try readUleb32(payload, &p);
                summary.import_count += count;
                if (count > 0 and summary.first_import_mod.len == 0) {
                    summary.first_import_mod = try readBytes(payload, &p);
                    summary.first_import_name = try readBytes(payload, &p);
                }
            },
            7 => {
                var p: usize = 0;
                const count = try readUleb32(payload, &p);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const name = try readBytes(payload, &p);
                    if (p >= payload.len) return error.UnexpectedEof;
                    const kind = payload[p];
                    p += 1;
                    _ = try readUleb32(payload, &p);
                    if (kind == 0x00 and std.mem.eql(u8, name, expected_export)) {
                        summary.found_export = true;
                    }
                }
            },
            else => {},
        }
    }
    return summary;
}

fn readBytes(bytes: []const u8, pos: *usize) ![]const u8 {
    const len: usize = try readUleb32(bytes, pos);
    if (pos.* + len > bytes.len) return error.UnexpectedEof;
    const out = bytes[pos.* .. pos.* + len];
    pos.* += len;
    return out;
}

fn readUleb32(bytes: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.UnexpectedEof;
        const byte = bytes[pos.*];
        pos.* += 1;
        if (shift == 28 and (byte & 0xf0) != 0) return error.Leb128Overflow;
        result |= @as(u32, byte & 0x7f) << @intCast(shift);
        if ((byte & 0x80) == 0) return result;
        shift += 7;
        if (shift > 28) return error.Leb128Overflow;
    }
}

test "verifyWasm accepts zero-import module with expected function export" {
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x07\x16\x01\x12nanoui_embed_probe\x00\x00";
    const s = try verifyWasm(wasm, "nanoui_embed_probe");
    try std.testing.expectEqual(@as(u32, 0), s.import_count);
    try std.testing.expect(s.found_export);
}

test "verifyWasm reports unexpected wasm imports" {
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x02\x0b\x01\x03env\x03foo\x00\x00";
    const s = try verifyWasm(wasm, "nanoui_embed_probe");
    try std.testing.expectEqual(@as(u32, 1), s.import_count);
    try std.testing.expectEqualStrings("env", s.first_import_mod);
    try std.testing.expectEqualStrings("foo", s.first_import_name);
    try std.testing.expect(!s.found_export);
}
