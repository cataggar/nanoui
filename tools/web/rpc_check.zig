//! Headless wasm32-wasi reactor exercising Layer 1 `web.js` and Layer 2 `web.rpc`.
const std = @import("std");
const nanoui = @import("nanoui");
const js = nanoui.web.js;
const rpc = nanoui.web.rpc;
const schema = @import("rpc_schema.zig");

var math_svc: schema.MathService = .{};
var zig_wakes: u32 = 0;
var grow_async_checksum: u32 = 0;
var promise_resolved: u32 = 0;
var promise_rejected: u32 = 0;
var promise_cancelled_ran: u32 = 0;

fn onWake() void {
    zig_wakes += 1;
}

export fn rpc_check_init() u32 {
    math_svc = .{};
    zig_wakes = 0;
    grow_async_checksum = 0;
    js.wake_hook = onWake;
    rpc.bind(&math_svc) catch return 1;
    return 0;
}

export fn rpc_check_zig_wakes() u32 {
    return zig_wakes;
}

export fn rpc_check_pending_callbacks() u32 {
    return js.pendingCallbackCount();
}

export fn rpc_check_force_grow(megabytes: u32) u32 {
    const byte_len: usize = @as(usize, megabytes) * 1024 * 1024;
    const buf = std.heap.wasm_allocator.alloc(u8, byte_len) catch return 0;
    defer std.heap.wasm_allocator.free(buf);
    var off: usize = 0;
    while (off < buf.len) : (off += 65536) buf[off] = @truncate((off >> 16) ^ 0x5A);
    var verify_off: usize = 0;
    while (verify_off < buf.len) : (verify_off += 65536) {
        if (buf[verify_off] != @as(u8, @truncate((verify_off >> 16) ^ 0x5A))) return 0;
    }
    return @intCast(@wasmMemorySize(0));
}

export fn rpc_check_handles_and_types() u32 {
    const gpa = std.heap.wasm_allocator;
    const base_live = js.liveCount();

    const first = js.object() catch return 1;
    const first_idx = first.index();
    const first_gen = first.generation();
    js.set(first, "k", .from(@as(i32, 99))) catch return 2;
    const duped = first.dup();
    const duped_idx = duped.index();
    const duped_gen = duped.generation();
    if (duped == .invalid or js.liveCount() != base_live + 2) return 3;
    first.release();
    first.release(); // idempotent double release
    if (first.dup() != .invalid) return 4;
    if (js.get(first, "k") != error.InvalidHandle) return 5;
    if (js.typeof(first) != error.InvalidHandle) return 6;
    const via_duped = js.get(duped, "k") catch return 7;
    if ((js.asInt(i32, via_duped) catch return 8) != 99) return 9;
    via_duped.release();
    duped.release();

    const reused_hi = js.object() catch return 10;
    const reused_lo = js.object() catch return 10;
    if (reused_hi.index() != duped_idx or reused_hi.generation() == duped_gen) return 11;
    if (reused_lo.index() != first_idx or reused_lo.generation() == first_gen) return 11;
    if (js.get(first, "k") != error.InvalidHandle) return 12;
    reused_lo.release();
    reused_hi.release();

    for (0..128) |i| {
        const obj = js.object() catch return 13;
        const arr = js.array() catch return 14;
        if (obj.index() > 16 or arr.index() > 16) return 15;
        js.setIndex(arr, 0, .from(@as(u32, @intCast(i)))) catch return 16;
        js.set(obj, "arr", .{ .handle = arr }) catch return 17;
        if (!(js.has(obj, "arr") catch return 18)) return 19;
        js.delete(obj, "arr") catch return 20;
        if (js.has(obj, "arr") catch return 21) return 22;
        arr.release();
        obj.release();
    }
    if (js.liveCount() != base_live) return 23;

    {
        // 64-bit BigInt above 2^53 (MAX_SAFE_INTEGER)
        const big_const: u64 = 0x0123_4567_89ab_cdef;
        const bi = js.bigint(big_const) catch return 24;
        defer bi.release();
        if ((js.typeof(bi) catch return 25) != .bigint) return 26;
        if ((js.asInt(u64, bi) catch return 27) != big_const) return 28;
        if (js.asInt(u32, bi) != error.TypeMismatch) return 29;
        const host_bi = js.get(js.global, "__checkBigInt") catch return 30;
        defer host_bi.release();
        if ((js.asInt(u64, host_bi) catch return 31) != 0xfedc_ba98_7654_3210) return 32;
    }

    {
        // >256B UTF-8 string (emoji + CJK) and >256B Uint8Array via read_pending
        const long_str_h = js.get(js.global, "__checkLongUtf8") catch return 33;
        defer long_str_h.release();
        const long_str = js.readString(long_str_h, gpa) catch return 34;
        defer gpa.free(long_str);
        if (long_str.len <= 512) return 35;
        js.set(js.global, "__zigEchoUtf8", .from(long_str)) catch return 36;

        const long_bytes_h = js.get(js.global, "__checkLongBytes") catch return 37;
        defer long_bytes_h.release();
        const long_bytes = js.readBytes(long_bytes_h, gpa) catch return 38;
        defer gpa.free(long_bytes);
        if (long_bytes.len != 2048 or long_bytes[0] != 0xAA or long_bytes[2047] != 0x55) return 39;
        js.set(js.global, "__zigEchoBytes", .{ .bytes = long_bytes }) catch return 40;
    }

    return if (js.liveCount() == base_live) 0 else 41;
}

fn checkThrowCase(gpa: std.mem.Allocator, kind: i32, expected: []const u8) bool {
    const res = js.invoke(js.global, "__throwCase", &.{.from(kind)});
    if (res != error.JsException) return false;
    const msg = js.lastError(gpa) catch return false;
    defer gpa.free(msg);
    return std.mem.eql(u8, msg, expected);
}

export fn rpc_check_exceptions() u32 {
    const gpa = std.heap.wasm_allocator;
    if (!checkThrowCase(gpa, 0, "TypeError: bad arg")) return 1;
    if (!checkThrowCase(gpa, 1, "plain string")) return 2;
    if (!checkThrowCase(gpa, 2, "{\"code\":42}")) return 3;
    if (!checkThrowCase(gpa, 3, "[object Object]")) return 4;

    const ctor = js.get(js.global, "__ThrowingCtor") catch return 5;
    defer ctor.release();
    if (js.construct(ctor, &.{}) != error.JsException) return 6;
    const ctor_msg = js.lastError(gpa) catch return 7;
    defer gpa.free(ctor_msg);
    if (!std.mem.eql(u8, ctor_msg, "RangeError: bad ctor")) return 8;
    return 0;
}

fn onGrowAsyncBytes(_: ?*anyopaque, out: js.Outcome) void {
    if (rpc_check_force_grow(1) == 0) return;
    switch (out) {
        .resolved => |h| {
            grow_async_checksum = js.asInt(u32, h) catch 0;
        },
        .rejected => {},
    }
}

export fn rpc_check_grow_midflight() u32 {
    const gpa = std.heap.wasm_allocator;
    grow_async_checksum = 0;

    // 1. Host callback triggers 4 MiB memory.grow while Zig reads >256B string & bytes.
    const host_obj = js.invoke(js.global, "__growDuringHostCall", &.{}) catch return 1;
    defer host_obj.release();
    const s_h = js.get(host_obj, "text") catch return 2;
    defer s_h.release();
    const text = js.readString(s_h, gpa) catch return 3;
    defer gpa.free(text);
    if (text.len != 4096 or text[0] != 'G' or text[4095] != 'Z') return 4;

    const b_h = js.get(host_obj, "bytes") catch return 5;
    defer b_h.release();
    const raw = js.readBytes(b_h, gpa) catch return 6;
    defer gpa.free(raw);
    if (raw.len != 4096 or raw[0] != 0x11 or raw[4095] != 0xEE) return 7;

    // 2. Pass linear-memory slice as `.bytes` to async JS Promise, then grow Wasm memory by 5 MiB
    // BEFORE the Promise settles, proving JS received a detached-safe `.slice()` copy.
    const payload = gpa.alloc(u8, 1024) catch return 8;
    for (payload, 0..) |*byte, idx| byte.* = @truncate(idx * 7 + 3);
    const p = js.invoke(js.global, "__asyncConsumeBytes", &.{.{ .bytes = payload }}) catch {
        gpa.free(payload);
        return 9;
    };
    @memset(payload, 0xFF);
    gpa.free(payload);
    defer p.release();
    if (rpc_check_force_grow(5) == 0) return 10;
    _ = js.then(p, null, onGrowAsyncBytes) catch return 11;
    return 0;
}

export fn rpc_check_grow_result() u32 {
    return grow_async_checksum;
}

fn onTestPromiseResolve(_: ?*anyopaque, out: js.Outcome) void {
    switch (out) {
        .resolved => |h| {
            const s = js.readString(h, std.heap.wasm_allocator) catch return;
            defer std.heap.wasm_allocator.free(s);
            if (s.len > 280 and std.mem.startsWith(u8, s, "resolved:")) promise_resolved += 1;
        },
        .rejected => {},
    }
}

fn onTestPromiseReject(_: ?*anyopaque, out: js.Outcome) void {
    switch (out) {
        .resolved => {},
        .rejected => |msg| {
            if (msg.len > 280 and std.mem.startsWith(u8, msg, "RangeError: over-256:")) promise_rejected += 1;
        },
    }
}

fn onCancelledShouldNotRun(_: ?*anyopaque, _: js.Outcome) void {
    promise_cancelled_ran += 1;
}

export fn rpc_check_promises() u32 {
    js.wake_hook = onWake;
    promise_resolved = 0;
    promise_rejected = 0;
    promise_cancelled_ran = 0;
    const bundle = js.invoke(js.global, "__makeTestPromises", &.{}) catch return 1;
    defer bundle.release();

    const p_res = js.get(bundle, "resolve") catch return 2;
    defer p_res.release();
    const p_rej = js.get(bundle, "reject") catch return 3;
    defer p_rej.release();
    const p_can_res = js.get(bundle, "cancelResolve") catch return 4;
    defer p_can_res.release();
    const p_can_rej = js.get(bundle, "cancelReject") catch return 5;
    defer p_can_rej.release();

    _ = js.then(p_res, null, onTestPromiseResolve) catch return 6;
    _ = js.then(p_rej, null, onTestPromiseReject) catch return 7;
    const cb_res = js.then(p_can_res, null, onCancelledShouldNotRun) catch return 8;
    const cb_rej = js.then(p_can_rej, null, onCancelledShouldNotRun) catch return 9;
    js.cancel(cb_res);
    js.cancel(cb_rej);
    return if (js.pendingCallbackCount() == 2) 0 else 10;
}

export fn rpc_check_promise_state() u32 {
    return (promise_cancelled_ran << 16) | (promise_rejected << 8) | promise_resolved;
}
