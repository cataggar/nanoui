//! Unit tests for `src/web/js.zig` and `src/web/js_mock.zig` (host + Wasmtime).
const std = @import("std");
const js = @import("js.zig");

fn expectPropInt(comptime T: type, obj: js.Handle, key: []const u8, expected: T) !void {
    return expectIntAndRelease(T, try js.get(obj, key), expected);
}

fn expectPropStr(gpa: std.mem.Allocator, obj: js.Handle, key: []const u8, expected: []const u8) !void {
    const h = try js.get(obj, key);
    defer h.release();
    const s = try js.readString(h, gpa);
    defer gpa.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

fn expectIntAndRelease(comptime T: type, h: js.Handle, expected: T) !void {
    defer h.release();
    try std.testing.expectEqual(expected, try js.asInt(T, h));
}

var wake_count: u32 = 0;
fn bumpWake() void {
    wake_count += 1;
}

test "immortal handles 0..4 invariants and typeof" {
    defer js.mock.reset();
    for ([_]js.Handle{ .undef, .null, .false, .true, .global }, 0..) |h, idx| {
        try std.testing.expect(@backingInt(h) == idx and h.isReserved() and h.dup() == h and js.dup(h) == h);
        h.release();
        js.release(h);
    }
    try std.testing.expect(!js.Handle.invalid.isReserved() and js.Handle.invalid.dup() == .invalid);
    js.Handle.invalid.release();
    for ([_]struct { js.Handle, js.Type }{ .{ .undef, .undefined }, .{ .null, .null }, .{ .false, .boolean }, .{ .true, .boolean }, .{ .global, .object } }) |p|
        try std.testing.expectEqual(p[1], try js.typeof(p[0]));
    try std.testing.expect((try js.isNullOrUndefined(.undef)) and (try js.isNullOrUndefined(.null)));
    try std.testing.expect(!(try js.isNullOrUndefined(.false)) and !(try js.isNullOrUndefined(.global)));
    try std.testing.expect((try js.asBool(.true)) and !(try js.asBool(.false)));
    try std.testing.expectError(error.TypeMismatch, js.asBool(.null));
    try std.testing.expectError(error.TypeMismatch, js.asBool(.global));
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

test "generational slot allocation, LIFO free-list reuse, and >256 cycle wraparound" {
    defer js.mock.reset();
    const a = try js.object();
    const b = try js.object();
    const c = try js.object();
    try std.testing.expect(a.index() >= 5 and a.generation() == 1);
    try std.testing.expect(b.index() == a.index() + 1 and b.generation() == 1);
    try std.testing.expect(c.index() == b.index() + 1 and c.generation() == 1);
    try std.testing.expectEqual(@as(u32, 3), js.liveCount());

    b.release();
    try std.testing.expectEqual(@as(u32, 2), js.liveCount());
    const d = try js.object();
    try std.testing.expect(d.index() == b.index() and d.generation() == 2 and d != b);

    c.release();
    d.release();
    const e1 = try js.object();
    const e2 = try js.object();
    try std.testing.expect(e1.index() == d.index() and e1.generation() == 3);
    try std.testing.expect(e2.index() == c.index() and e2.generation() == 2);
    e2.release();
    e1.release();
    a.release();
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());

    var saw_254 = false;
    var wrapped_to_1 = false;
    for (0..300) |cycle| {
        const h = try js.object();
        const expected_gen: u8 = @intCast(((cycle + 1) % 254) + 1);
        try std.testing.expect(h.index() == a.index() and h.generation() == expected_gen);
        try std.testing.expect(h.generation() >= 1 and h.generation() <= 254 and @backingInt(h) < js.raw_err_oom);
        if (h.generation() == 254) saw_254 = true;
        if (saw_254 and h.generation() == 1) wrapped_to_1 = true;
        h.release();
    }
    try std.testing.expect(saw_254 and wrapped_to_1 and js.liveCount() == 0);
}

test "stale handle rejection and double-release safety" {
    defer js.mock.reset();
    const gpa = std.testing.allocator;
    const a = try js.object();
    const b = try js.object();
    const c = try js.object();
    try js.set(b, "x", .from(11));
    b.release();
    const d = try js.object();
    try std.testing.expectEqual(b.index(), d.index());
    try js.set(d, "x", .from(77));

    try std.testing.expectError(error.InvalidHandle, js.get(b, "x"));
    try std.testing.expectError(error.InvalidHandle, js.set(b, "x", .from(1)));
    try std.testing.expectError(error.InvalidHandle, js.has(b, "x"));
    try std.testing.expectError(error.InvalidHandle, js.delete(b, "x"));
    try std.testing.expectError(error.InvalidHandle, js.asBool(b));
    try std.testing.expectError(error.InvalidHandle, js.asNumber(b));
    try std.testing.expectError(error.InvalidHandle, js.asInt(i32, b));
    try std.testing.expectError(error.InvalidHandle, js.len(b));
    try std.testing.expectError(error.InvalidHandle, js.typeof(b));
    try std.testing.expectError(error.InvalidHandle, js.readString(b, gpa));
    try std.testing.expectEqual(js.Handle.invalid, b.dup());

    b.release();
    js.release(b);
    try std.testing.expectEqual(@as(u32, 3), js.liveCount());
    try expectPropInt(i32, d, "x", 77);
    a.release();
    c.release();
    d.release();
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

test "objects, properties, has, delete, and all Arg variants including u64 BigInt" {
    defer js.mock.reset();
    const gpa = std.testing.allocator;
    const obj = try js.object();
    const child = try js.object();
    try js.set(child, "tag", .from("nested"));

    const big_u64: u64 = 0x0123_4567_89AB_CDEF;
    const high_u64: u64 = 0xFEDC_BA98_7654_3210;
    try js.set(obj, "undef_k", .undef);
    try js.set(obj, "null_k", .null);
    try js.set(obj, "bool_k", .{ .bool = true });
    try js.set(obj, "i32_k", .{ .i32 = -1_234_567_890 });
    try js.set(obj, "u32_k", .{ .u32 = 4_000_000_000 });
    try js.set(obj, "f64_k", .{ .f64 = 3.141592653589793 });
    try js.set(obj, "u64_k", .{ .u64 = big_u64 });
    try js.set(obj, "usize_k", .{ .usize = 54321 });
    try js.set(obj, "str_k", .{ .string = "hello-zig" });
    try js.set(obj, "bytes_k", .{ .bytes = &.{ 0x00, 0x7F, 0x80, 0xFF } });
    try js.set(obj, "handle_k", .{ .handle = child });
    child.release();

    try std.testing.expect((try js.has(obj, "undef_k")) and !(try js.has(obj, "missing_k")));
    try std.testing.expectEqual(js.Handle.undef, try js.get(obj, "undef_k"));
    try std.testing.expectEqual(js.Handle.null, try js.get(obj, "null_k"));
    try std.testing.expectEqual(js.Handle.true, try js.get(obj, "bool_k"));
    try expectPropInt(i32, obj, "i32_k", -1_234_567_890);
    try expectPropInt(u32, obj, "u32_k", 4_000_000_000);
    try expectPropInt(usize, obj, "usize_k", 54321);
    try expectPropStr(gpa, obj, "str_k", "hello-zig");

    const h_f64 = try js.get(obj, "f64_k");
    try std.testing.expectApproxEqAbs(@as(f64, 3.141592653589793), try js.asNumber(h_f64), 1e-15);
    h_f64.release();

    const h_u64 = try js.get(obj, "u64_k");
    try std.testing.expect(try js.typeof(h_u64) == .bigint and try js.asInt(u64, h_u64) == big_u64);
    h_u64.release();
    const h_bi2 = try js.bigint(high_u64);
    try std.testing.expectEqual(high_u64, try js.asInt(u64, h_bi2));
    try std.testing.expectError(error.TypeMismatch, js.asInt(i64, h_bi2));
    h_bi2.release();

    const h_bytes = try js.get(obj, "bytes_k");
    try std.testing.expect(try js.isBytes(h_bytes));
    const b = try js.readBytes(h_bytes, gpa);
    defer gpa.free(b);
    h_bytes.release();
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x7F, 0x80, 0xFF }, b);

    const h_child = try js.get(obj, "handle_k");
    try expectPropStr(gpa, h_child, "tag", "nested");
    h_child.release();
    try js.delete(obj, "u32_k");
    try js.delete(obj, "handle_k");
    try std.testing.expect(!(try js.has(obj, "u32_k")) and (try js.get(obj, "u32_k")) == .undef);

    try js.set(js.global, "appVer", .from(@as(?u32, 14)));
    try std.testing.expect(try js.has(js.global, "appVer"));
    try expectPropInt(u32, js.global, "appVer", 14);
    try js.delete(js.global, "appVer");
    try std.testing.expect(!(try js.has(js.global, "appVer")));
    obj.release();
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

test "arrays, setIndex, getIndex, len, and sparse or out-of-bounds reads" {
    defer js.mock.reset();
    const gpa = std.testing.allocator;
    const arr = try js.array();
    try std.testing.expect((try js.isArray(arr)) and (try js.len(arr)) == 0);
    try js.setIndex(arr, 0, .from("first"));
    try js.setIndex(arr, 3, .from(42));
    try std.testing.expectEqual(@as(usize, 4), try js.len(arr));
    for ([_]usize{ 1, 2, 99 }) |idx| try std.testing.expectEqual(js.Handle.undef, try js.getIndex(arr, idx));
    try expectIntAndRelease(i32, try js.getIndex(arr, 3), 42);

    try js.setIndex(arr, 0, .from("updated"));
    const v0 = try js.getIndex(arr, 0);
    const s0 = try js.readString(v0, gpa);
    defer gpa.free(s0);
    v0.release();
    arr.release();
    try std.testing.expectEqualStrings("updated", s0);
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

test "strings and bytes across <=256B fast path and >256B payload sizes" {
    defer js.mock.reset();
    const gpa = std.testing.allocator;
    const utf8_unit = "é🚀Ωz!";
    for ([_]usize{ 0, 5, 256, 257, 8192 }) |sz| {
        const src = try gpa.alloc(u8, sz);
        defer gpa.free(src);
        if (sz == 5) @memcpy(src, "hello") else {
            var pos: usize = 0;
            while (pos + utf8_unit.len <= sz) : (pos += utf8_unit.len) @memcpy(src[pos .. pos + utf8_unit.len], utf8_unit);
            @memset(src[pos..], 'a');
        }
        const sh = try js.string(src);
        try std.testing.expectEqual(sz, try js.len(sh));
        try std.testing.expectError(error.TypeMismatch, js.readBytes(sh, gpa));
        const got = try js.readString(sh, gpa);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(src, got);
        sh.release();
    }
    for ([_]usize{ 0, 256, 257, 8192 }) |sz| {
        const src = try gpa.alloc(u8, sz);
        defer gpa.free(src);
        for (src, 0..) |*byte, i| byte.* = switch (i % 4) {
            0 => 0x00,
            1 => 0xFF,
            2 => 0x80,
            else => @truncate(i),
        };
        const bh = try js.bytes(src);
        try std.testing.expect((try js.isBytes(bh)) and (try js.len(bh)) == sz);
        try std.testing.expectError(error.TypeMismatch, js.readString(bh, gpa));
        const got = try js.readBytes(bh, gpa);
        defer gpa.free(got);
        try std.testing.expectEqualSlices(u8, src, got);
        bh.release();
    }
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

test "parseJson, stringifyJson, and invalid JSON JsException with lastError" {
    defer js.mock.reset();
    const gpa = std.testing.allocator;
    const parsed = try js.parseJson("{\"name\":\"Ada\",\"nums\":[1,2],\"ok\":true,\"empty\":null}");
    try js.set(parsed, "added", .from(9));
    const json_out = try js.stringifyJson(parsed, gpa);
    defer gpa.free(json_out);
    parsed.release();

    const reparsed = try js.parseJson(json_out);
    try expectPropInt(i32, reparsed, "added", 9);
    reparsed.release();

    try std.testing.expectError(error.JsException, js.parseJson("{bad json"));
    const err_msg = try js.lastError(gpa);
    defer gpa.free(err_msg);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "SyntaxError") != null);

    const bi = try js.bigint(123);
    try std.testing.expectError(error.JsException, js.stringifyJson(bi, gpa));
    bi.release();
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

test "function call, method invoke, global call, construct, >16 args, and host throw" {
    defer js.mock.reset();
    const gpa = std.testing.allocator;
    const CallStats = struct {
        calls: u32 = 0,
        fn sumWithThis(raw_ctx: ?*anyopaque, this: js.Handle, args: []const js.Arg) js.mock.MockReturn {
            const st: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            st.calls += 1;
            var acc: i32 = 0;
            if (this != .undef and this != .global) {
                if (js.get(this, "base")) |bh| {
                    defer bh.release();
                    acc += js.asInt(i32, bh) catch 0;
                } else |_| {}
            }
            for (args) |a| {
                if (a == .i32) acc += a.i32;
            }
            return .{ .arg = .from(acc) };
        }
        fn ctor(_: ?*anyopaque, this: js.Handle, args: []const js.Arg) js.mock.MockReturn {
            js.set(this, "label", args[0]) catch return .{ .throw = "set failed" };
            return .{ .arg = .undef };
        }
        fn thrower(_: ?*anyopaque, _: js.Handle, _: []const js.Arg) js.mock.MockReturn {
            return .{ .throw = "RangeError: boom" };
        }
    };

    var stats: CallStats = .{};
    const fn_h = try js.mock.func(&stats, CallStats.sumWithThis);
    const obj = try js.object();
    try js.set(obj, "base", .from(100));
    try js.set(obj, "calc", .{ .handle = fn_h });
    try js.set(js.global, "gCalc", .{ .handle = fn_h });

    try expectIntAndRelease(i32, try js.call(fn_h, .undef, &.{ .from(3), .from(4) }), 7);
    try expectIntAndRelease(i32, try js.invoke(obj, "calc", &.{ .from(5), .from(6) }), 111);
    try expectIntAndRelease(i32, try js.invoke(js.global, "gCalc", &.{.from(9)}), 9);
    try js.delete(js.global, "gCalc");

    const ctor_h = try js.mock.func(null, CallStats.ctor);
    const inst = try js.construct(ctor_h, &.{.from("widget")});
    try expectPropStr(gpa, inst, "label", "widget");
    inst.release();

    const args16: [16]js.Arg = @splat(.from(1));
    try expectIntAndRelease(i32, try js.call(fn_h, .undef, &args16), 16);
    const before_calls = stats.calls;
    const args17: [17]js.Arg = @splat(.from(1));
    try std.testing.expectError(error.TooManyArguments, js.call(fn_h, .undef, &args17));
    try std.testing.expectError(error.TooManyArguments, js.invoke(obj, "calc", &args17));
    try std.testing.expectError(error.TooManyArguments, js.construct(ctor_h, &args17));
    try std.testing.expectEqual(before_calls, stats.calls);

    const throw_h = try js.mock.func(null, CallStats.thrower);
    try std.testing.expectError(error.JsException, js.call(throw_h, .undef, &.{}));
    const err_s = try js.lastError(gpa);
    defer gpa.free(err_s);
    try std.testing.expectEqualStrings("RangeError: boom", err_s);

    throw_h.release();
    ctor_h.release();
    obj.release();
    fn_h.release();
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

test "Promise continuations: borrow vs dup, rejection, cancel, reentrant chaining, wake_hook" {
    defer js.mock.reset();
    defer js.wake_hook = null;
    const gpa = std.testing.allocator;
    wake_count = 0;
    js.wake_hook = bumpWake;

    const Obs = struct {
        val: i32 = 0,
        kept: js.Handle = .undef,
        keep: bool = false,
        reason: ?[]u8 = null,
        fn onSettle(self: *@This(), out: js.Outcome) void {
            switch (out) {
                .resolved => |h| {
                    const v_h = js.get(h, "n") catch unreachable;
                    defer v_h.release();
                    self.val = js.asInt(i32, v_h) catch unreachable;
                    if (self.keep) self.kept = h.dup();
                },
                .rejected => |msg| self.reason = std.testing.allocator.dupe(u8, msg) catch null,
            }
        }
    };
    var obs1: Obs = .{};
    const p1 = try js.mock.createPromise();
    try std.testing.expect(try js.isPromise(p1.handle));
    js.ignorePromise(p1.handle);
    _ = try js.awaitCallback(Obs, p1.handle, &obs1, Obs.onSettle);
    const payload1 = try js.object();
    try js.set(payload1, "n", .from(42));
    p1.resolve(.{ .handle = payload1 });
    payload1.release();
    p1.release();
    try std.testing.expect(obs1.val == 42 and wake_count == 1 and js.liveCount() == 0);

    var obs2: Obs = .{ .keep = true };
    const p2 = try js.mock.createPromise();
    _ = try js.awaitCallback(Obs, p2.handle, &obs2, Obs.onSettle);
    const payload2 = try js.object();
    try js.set(payload2, "n", .from(88));
    p2.resolve(.{ .handle = payload2 });
    payload2.release();
    p2.release();
    try std.testing.expectEqual(@as(u32, 1), js.liveCount());
    try expectPropInt(i32, obs2.kept, "n", 88);
    obs2.kept.release();
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());

    var robs: Obs = .{};
    const p3 = try js.mock.createPromise();
    _ = try js.awaitCallback(Obs, p3.handle, &robs, Obs.onSettle);
    p3.reject("network offline");
    p3.release();
    defer if (robs.reason) |r| gpa.free(r);
    try std.testing.expectEqualStrings("network offline", robs.reason.?);
    try std.testing.expect(wake_count == 3 and js.liveCount() == 0);

    var cancelled_called = false;
    const onCancel = struct {
        fn cb(raw: ?*anyopaque, _: js.Outcome) void {
            @as(*bool, @ptrCast(@alignCast(raw.?))).* = true;
        }
    }.cb;
    const pc1 = try js.mock.createPromise();
    const pc2 = try js.mock.createPromise();
    const cb1 = try js.then(pc1.handle, &cancelled_called, onCancel);
    const cb2 = try js.then(pc2.handle, &cancelled_called, onCancel);
    try std.testing.expectEqual(@as(u32, 2), js.pendingCallbackCount());
    js.cancel(cb1);
    js.cancel(cb2);
    try std.testing.expectEqual(@as(u32, 0), js.pendingCallbackCount());
    const unconsumed = try js.object();
    pc1.resolve(.{ .handle = unconsumed });
    unconsumed.release();
    pc2.reject("cancelled err");
    pc1.release();
    pc2.release();
    try std.testing.expect(!cancelled_called and wake_count == 3 and js.liveCount() == 0);

    const Chain = struct {
        second: js.Handle,
        step: i32 = 0,
        final_val: i32 = 0,
        second_cb: js.CallbackId = .invalid,
        fn onFirst(raw: ?*anyopaque, out: js.Outcome) void {
            const ch: *@This() = @ptrCast(@alignCast(raw.?));
            ch.step = js.asInt(i32, out.resolved) catch 0;
            ch.second_cb = js.then(ch.second, ch, onSecond) catch unreachable;
        }
        fn onSecond(raw: ?*anyopaque, out: js.Outcome) void {
            const ch: *@This() = @ptrCast(@alignCast(raw.?));
            ch.final_val = ch.step * 10 + (js.asInt(i32, out.resolved) catch 0);
        }
    };
    const pf = try js.mock.createPromise();
    const ps = try js.mock.createPromise();
    var chain: Chain = .{ .second = ps.handle };
    const first_cb = try js.then(pf.handle, &chain, Chain.onFirst);
    pf.resolve(.from(5));
    try std.testing.expect(chain.second_cb != first_cb and wake_count == 4 and chain.final_val == 0);
    ps.resolve(.from(7));
    pf.release();
    ps.release();
    try std.testing.expect(chain.final_val == 57 and wake_count == 5);
    try std.testing.expect(js.pendingCallbackCount() == 0 and js.liveCount() == 0);
}
