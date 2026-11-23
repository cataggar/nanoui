//! Zero-dependency JS value/handle and Promise bridge for `wasm32-wasi`.
const std = @import("std");
const builtin = @import("builtin");

pub const mock = @import("js_mock.zig");
const use_mock = builtin.is_test or builtin.os.tag != .wasi or @import("../backend.zig").is_embed;

pub const max_args = 16;
pub const Error = error{ JsException, InvalidHandle, TooManyArguments, OutOfMemory, TypeMismatch };
pub const Type = enum(u8) { undefined = 0, null = 1, boolean = 2, number = 3, bigint = 4, string = 5, symbol = 6, function = 7, object = 8 };

pub const Handle = enum(u32) {
    undef = 0,
    null = 1,
    false = 2,
    true = 3,
    global = 4,
    invalid = 0xFFFF_FFFF,
    _,

    pub const nanoui_ts_type = "unknown";

    pub fn isReserved(h: Handle) bool {
        return @backingInt(h) <= 4;
    }
    pub fn index(h: Handle) u24 {
        return @truncate(@backingInt(h));
    }
    pub fn generation(h: Handle) u8 {
        return @truncate(@backingInt(h) >> 24);
    }
    pub fn pack(gen: u8, idx: u24) Handle {
        return @fromBackingInt((@as(u32, gen) << 24) | @as(u32, idx));
    }
    pub fn release(h: Handle) void {
        if (h.isReserved() or h == .invalid) return;
        if (use_mock) mock.release(h) else wasm_host.release(@backingInt(h));
    }
    pub fn dup(h: Handle) Handle {
        if (h.isReserved() or h == .invalid) return h;
        if (use_mock) return mock.dup(h);
        const raw = wasm_host.dup(@backingInt(h));
        return if (raw >= raw_err_oom) .invalid else @fromBackingInt(raw);
    }
};

pub const global: Handle = .global;
pub const dup = Handle.dup;
pub const release = Handle.release;

pub const Arg = union(enum) {
    undef,
    null,
    bool: bool,
    i32: i32,
    u32: u32,
    f64: f64,
    u64: u64,
    usize: usize,
    string: []const u8,
    bytes: []const u8,
    handle: Handle,

    pub fn from(v: anytype) Arg {
        const T = @TypeOf(v);
        if (T == Arg) return v;
        if (T == Handle) return .{ .handle = v };
        return switch (@typeInfo(T)) {
            .void => .undef,
            .null => .null,
            .bool => .{ .bool = v },
            .optional => if (v) |inner| Arg.from(inner) else .null,
            .comptime_int => if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32))
                .{ .i32 = v }
            else if (v >= 0 and v <= std.math.maxInt(u64))
                (if (v <= std.math.maxInt(u32)) .{ .u32 = v } else .{ .u64 = v })
            else
                .{ .f64 = @floatFromInt(v) },
            .int => |info| if (T == usize)
                .{ .usize = v }
            else if (info.signedness == .unsigned)
                (if (info.bits <= 32) .{ .u32 = @intCast(v) } else .{ .u64 = @intCast(v) })
            else
                (if (info.bits <= 32) .{ .i32 = @intCast(v) } else .{ .f64 = @floatFromInt(v) }),
            .float, .comptime_float => .{ .f64 = @floatCast(v) },
            .pointer => |p| if (p.size == .slice and p.child == u8)
                .{ .string = v }
            else if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)
                .{ .string = v[0..@typeInfo(p.child).array.len] }
            else if (p.size == .many and p.sentinel_ptr != null and p.child == u8)
                .{ .string = std.mem.span(v) }
            else
                @compileError("unsupported pointer type for js.Arg.from: " ++ @typeName(T)),
            else => @compileError("unsupported type for js.Arg.from: " ++ @typeName(T)),
        };
    }
};

pub const RawArg = extern struct { tag: u32, a: u32, b: u64 align(8) };
comptime {
    std.debug.assert(@sizeOf(RawArg) == 16 and @alignOf(RawArg) == 8 and @offsetOf(RawArg, "b") == 8);
}

pub const CallbackId = enum(u32) {
    invalid = 0,
    _,
    pub fn index(id: CallbackId) u24 {
        return @truncate(@backingInt(id));
    }
    pub fn generation(id: CallbackId) u8 {
        return @truncate(@backingInt(id) >> 24);
    }
    pub fn pack(gen: u8, idx: u24) CallbackId {
        return @fromBackingInt((@as(u32, gen) << 24) | @as(u32, idx));
    }
};

pub const Outcome = union(enum) { resolved: Handle, rejected: []const u8 };
pub var wake_hook: ?*const fn () void = null;
pub const raw_err_exception: u32 = 0xFFFF_FFFF;
pub const raw_err_invalid_handle: u32 = 0xFFFF_FFFE;
pub const raw_err_type_mismatch: u32 = 0xFFFF_FFFD;
pub const raw_err_oom: u32 = 0xFFFF_FFFC;

const wasm_host = struct {
    extern "nanoui_js" fn obj_new() u32;
    extern "nanoui_js" fn arr_new() u32;
    extern "nanoui_js" fn num_new(v: f64) u32;
    extern "nanoui_js" fn bigint_new(v: u64) u32;
    extern "nanoui_js" fn str_new(ptr: [*]const u8, len: u32) u32;
    extern "nanoui_js" fn bytes_new(ptr: [*]const u8, len: u32) u32;
    extern "nanoui_js" fn dup(raw: u32) u32;
    extern "nanoui_js" fn release(raw: u32) void;
    extern "nanoui_js" fn live_count() u32;
    extern "nanoui_js" fn value_kind(raw: u32, out_flags: *u32) u32;
    extern "nanoui_js" fn prop_get(raw: u32, key_ptr: [*]const u8, key_len: u32) u32;
    extern "nanoui_js" fn idx_get(raw: u32, index: u32) u32;
    extern "nanoui_js" fn prop_set(raw: u32, key_ptr: [*]const u8, key_len: u32, val: *const RawArg) u32;
    extern "nanoui_js" fn idx_set(raw: u32, index: u32, val: *const RawArg) u32;
    extern "nanoui_js" fn prop_has(raw: u32, key_ptr: [*]const u8, key_len: u32, out: *u32) u32;
    extern "nanoui_js" fn prop_del(raw: u32, key_ptr: [*]const u8, key_len: u32) u32;
    extern "nanoui_js" fn value_len(raw: u32, out: *u32) u32;
    extern "nanoui_js" fn as_number(raw: u32, out: *f64) u32;
    extern "nanoui_js" fn as_int(raw: u32, signed: u32, out: *u64) u32;
    extern "nanoui_js" fn read_buf(mode: u32, raw: u32, ptr: [*]u8, cap: u32, out_len: *u32) u32;
    extern "nanoui_js" fn read_pending(ptr: [*]u8, len: u32) void;
    extern "nanoui_js" fn json_parse(ptr: [*]const u8, len: u32) u32;
    extern "nanoui_js" fn call(fn_raw: u32, this_raw: u32, args_ptr: [*]const RawArg, args_len: u32) u32;
    extern "nanoui_js" fn invoke(raw: u32, name_ptr: [*]const u8, name_len: u32, args_ptr: [*]const RawArg, args_len: u32) u32;
    extern "nanoui_js" fn construct(ctor_raw: u32, args_ptr: [*]const RawArg, args_len: u32) u32;
    extern "nanoui_js" fn promise_then(raw: u32, cb_id: u32) u32;
};

fn safePtr(s: []const u8) [*]const u8 {
    return if (s.len == 0) ""[0..0].ptr else s.ptr;
}
fn unwrapHandle(raw: u32) Error!Handle {
    return switch (raw) {
        raw_err_exception => error.JsException,
        raw_err_invalid_handle => error.InvalidHandle,
        raw_err_type_mismatch => error.TypeMismatch,
        raw_err_oom => error.OutOfMemory,
        else => @fromBackingInt(raw),
    };
}
fn checkStatus(status: u32) Error!void {
    return switch (status) {
        0 => {},
        2 => error.InvalidHandle,
        3 => error.TypeMismatch,
        4 => error.OutOfMemory,
        else => error.JsException,
    };
}
fn marshalArg(arg: Arg) RawArg {
    return switch (arg) {
        .undef => .{ .tag = 0, .a = 0, .b = 0 },
        .null => .{ .tag = 1, .a = 0, .b = 0 },
        .bool => |v| .{ .tag = 2, .a = @intFromBool(v), .b = 0 },
        .i32 => |v| .{ .tag = 3, .a = @bitCast(v), .b = 0 },
        .u32 => |v| .{ .tag = 4, .a = v, .b = 0 },
        .f64 => |v| .{ .tag = 5, .a = 0, .b = @bitCast(v) },
        .u64 => |v| .{ .tag = 6, .a = 0, .b = v },
        .usize => |v| .{ .tag = 7, .a = @intCast(v), .b = 0 },
        .string => |s| .{ .tag = 8, .a = @intFromPtr(safePtr(s)), .b = s.len },
        .bytes => |s| .{ .tag = 9, .a = @intFromPtr(safePtr(s)), .b = s.len },
        .handle => |h| .{ .tag = 10, .a = @backingInt(h), .b = 0 },
    };
}
fn marshalArgs(args: []const Arg, buf: *[max_args]RawArg) [*]const RawArg {
    for (args, 0..) |a, i| buf[i] = marshalArg(a);
    return buf;
}
fn readMode(mode: u2, h: Handle, gpa: std.mem.Allocator) Error![]u8 {
    if (use_mock) return mock.readBuf(mode, h, gpa);
    var stack_buf: [256]u8 = undefined;
    var total_len: u32 = 0;
    try checkStatus(wasm_host.read_buf(mode, @backingInt(h), &stack_buf, stack_buf.len, &total_len));
    if (total_len <= stack_buf.len) return gpa.dupe(u8, stack_buf[0..total_len]);
    const out = gpa.alloc(u8, total_len) catch |err| {
        wasm_host.read_pending(&stack_buf, 0);
        return err;
    };
    wasm_host.read_pending(out.ptr, total_len);
    return out;
}
fn queryFlags(h: Handle) Error!u32 {
    if (use_mock) return mock.valueFlags(h);
    var flags: u32 = 0;
    try checkStatus(wasm_host.value_kind(@backingInt(h), &flags));
    return flags;
}

pub fn object() Error!Handle {
    return if (use_mock) mock.newCollection(false) else unwrapHandle(wasm_host.obj_new());
}
pub fn array() Error!Handle {
    return if (use_mock) mock.newCollection(true) else unwrapHandle(wasm_host.arr_new());
}
pub fn boolean(v: bool) Handle {
    return if (v) .true else .false;
}
pub fn number(v: f64) Error!Handle {
    return if (use_mock) mock.allocArg(.{ .f64 = v }) else unwrapHandle(wasm_host.num_new(v));
}
pub fn bigint(v: u64) Error!Handle {
    return if (use_mock) mock.allocArg(.{ .u64 = v }) else unwrapHandle(wasm_host.bigint_new(v));
}
pub fn string(s: []const u8) Error!Handle {
    return if (use_mock) mock.allocArg(.{ .string = s }) else unwrapHandle(wasm_host.str_new(safePtr(s), @intCast(s.len)));
}
pub fn bytes(b: []const u8) Error!Handle {
    return if (use_mock) mock.allocArg(.{ .bytes = b }) else unwrapHandle(wasm_host.bytes_new(safePtr(b), @intCast(b.len)));
}
pub fn liveCount() u32 {
    return if (use_mock) mock.liveCount() else wasm_host.live_count();
}
pub fn typeof(h: Handle) Error!Type {
    return @fromBackingInt(@as(u8, @intCast((try queryFlags(h)) & 0xF)));
}
pub fn isNullOrUndefined(h: Handle) Error!bool {
    const t = try typeof(h);
    return t == .undefined or t == .null;
}
pub fn isArray(h: Handle) Error!bool {
    return (try queryFlags(h)) & 16 != 0;
}
pub fn isPromise(h: Handle) Error!bool {
    return (try queryFlags(h)) & 32 != 0;
}
pub fn isBytes(h: Handle) Error!bool {
    return (try queryFlags(h)) & 64 != 0;
}
pub fn get(target: Handle, key: []const u8) Error!Handle {
    return if (use_mock) mock.get(target, key) else unwrapHandle(wasm_host.prop_get(@backingInt(target), safePtr(key), @intCast(key.len)));
}
pub fn getIndex(target: Handle, index: usize) Error!Handle {
    return if (use_mock) mock.getIndex(target, index) else unwrapHandle(wasm_host.idx_get(@backingInt(target), @intCast(index)));
}
pub fn set(target: Handle, key: []const u8, value: Arg) Error!void {
    if (use_mock) return mock.set(target, key, value);
    const raw = marshalArg(value);
    return checkStatus(wasm_host.prop_set(@backingInt(target), safePtr(key), @intCast(key.len), &raw));
}
pub fn setIndex(target: Handle, index: usize, value: Arg) Error!void {
    if (use_mock) return mock.setIndex(target, index, value);
    const raw = marshalArg(value);
    return checkStatus(wasm_host.idx_set(@backingInt(target), @intCast(index), &raw));
}
pub fn has(target: Handle, key: []const u8) Error!bool {
    if (use_mock) return mock.has(target, key);
    var out: u32 = 0;
    try checkStatus(wasm_host.prop_has(@backingInt(target), safePtr(key), @intCast(key.len), &out));
    return out != 0;
}
pub fn delete(target: Handle, key: []const u8) Error!void {
    return if (use_mock) mock.delete(target, key) else checkStatus(wasm_host.prop_del(@backingInt(target), safePtr(key), @intCast(key.len)));
}
pub fn len(target: Handle) Error!usize {
    if (use_mock) return mock.len(target);
    var out: u32 = 0;
    try checkStatus(wasm_host.value_len(@backingInt(target), &out));
    return out;
}
pub fn asBool(h: Handle) Error!bool {
    if (h == .true) return true;
    if (h == .false) return false;
    _ = try typeof(h);
    return error.TypeMismatch;
}
pub fn asNumber(h: Handle) Error!f64 {
    if (use_mock) return mock.asNumber(h);
    var out: f64 = 0;
    try checkStatus(wasm_host.as_number(@backingInt(h), &out));
    return out;
}
pub fn asInt(comptime T: type, h: Handle) Error!T {
    comptime std.debug.assert(@typeInfo(T).int.bits <= 64);
    const signed = @typeInfo(T).int.signedness == .signed;
    var raw: u64 = 0;
    if (use_mock) raw = try mock.asInt64(h, signed) else try checkStatus(wasm_host.as_int(@backingInt(h), @intFromBool(signed), &raw));
    if (!signed) return if (raw <= std.math.maxInt(T)) @intCast(raw) else error.TypeMismatch;
    const sv: i64 = @bitCast(raw);
    return if (sv >= std.math.minInt(T) and sv <= std.math.maxInt(T)) @intCast(sv) else error.TypeMismatch;
}
pub fn readString(h: Handle, gpa: std.mem.Allocator) Error![]u8 {
    return readMode(0, h, gpa);
}
pub fn readBytes(h: Handle, gpa: std.mem.Allocator) Error![]u8 {
    return readMode(1, h, gpa);
}
pub fn parseJson(json_utf8: []const u8) Error!Handle {
    return if (use_mock) mock.parseJson(json_utf8) else unwrapHandle(wasm_host.json_parse(safePtr(json_utf8), @intCast(json_utf8.len)));
}
pub fn stringifyJson(h: Handle, gpa: std.mem.Allocator) Error![]u8 {
    return readMode(2, h, gpa);
}
pub fn lastError(gpa: std.mem.Allocator) Error![]u8 {
    return readMode(3, .undef, gpa);
}
pub fn call(fn_handle: Handle, this_handle: Handle, args: []const Arg) Error!Handle {
    if (args.len > max_args) return error.TooManyArguments;
    if (use_mock) return mock.call(fn_handle, this_handle, args);
    var raw_buf: [max_args]RawArg = undefined;
    return unwrapHandle(wasm_host.call(@backingInt(fn_handle), @backingInt(this_handle), marshalArgs(args, &raw_buf), @intCast(args.len)));
}
pub fn invoke(target: Handle, method: []const u8, args: []const Arg) Error!Handle {
    if (args.len > max_args) return error.TooManyArguments;
    if (use_mock) return mock.invoke(target, method, args);
    var raw_buf: [max_args]RawArg = undefined;
    return unwrapHandle(wasm_host.invoke(@backingInt(target), safePtr(method), @intCast(method.len), marshalArgs(args, &raw_buf), @intCast(args.len)));
}
pub fn construct(ctor_handle: Handle, args: []const Arg) Error!Handle {
    if (args.len > max_args) return error.TooManyArguments;
    if (use_mock) return mock.construct(ctor_handle, args);
    var raw_buf: [max_args]RawArg = undefined;
    return unwrapHandle(wasm_host.construct(@backingInt(ctor_handle), marshalArgs(args, &raw_buf), @intCast(args.len)));
}

const CallbackFn = *const fn (?*anyopaque, Outcome) void;
const CallbackEntry = struct { ctx: ?*anyopaque, cb: CallbackFn };
const CallbackSlot = struct { gen: u8 = 1, active: bool = false, ctx: ?*anyopaque = null, cb: CallbackFn = undefined };
var cb_slots: std.ArrayList(CallbackSlot) = .empty;
var cb_free: std.ArrayList(u24) = .empty;
var cb_live: u32 = 0;

fn cbAllocator() std.mem.Allocator {
    return if (builtin.is_test) std.testing.allocator else if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
}
fn allocCallbackSlot(ctx: ?*anyopaque, cb: CallbackFn) Error!CallbackId {
    const gpa = cbAllocator();
    const idx: u24 = if (cb_free.items.len > 0) cb_free.pop().? else blk: {
        if (cb_slots.items.len > std.math.maxInt(u24)) return error.OutOfMemory;
        const n: u24 = @intCast(cb_slots.items.len);
        try cb_slots.append(gpa, .{});
        break :blk n;
    };
    cb_slots.items[idx] = .{ .gen = cb_slots.items[idx].gen, .active = true, .ctx = ctx, .cb = cb };
    cb_live += 1;
    return CallbackId.pack(cb_slots.items[idx].gen, idx);
}
fn takeCallbackSlot(id: CallbackId) ?CallbackEntry {
    const idx = id.index();
    const gen = id.generation();
    if (id == .invalid or gen == 0 or gen == 0xFF or idx >= cb_slots.items.len) return null;
    const slot = &cb_slots.items[idx];
    if (!slot.active or slot.gen != gen) return null;
    const res: CallbackEntry = .{ .ctx = slot.ctx, .cb = slot.cb };
    slot.* = .{ .gen = (slot.gen % 254) + 1 };
    cb_live -= 1;
    cb_free.append(cbAllocator(), idx) catch {};
    return res;
}

pub fn then(promise_or_val: Handle, ctx: ?*anyopaque, cb: CallbackFn) Error!CallbackId {
    comptime if (!use_mock) @export(&nanoui_js_settle, .{ .name = "nanoui_js_settle" });
    const id = try allocCallbackSlot(ctx, cb);
    errdefer _ = takeCallbackSlot(id);
    if (use_mock) try mock.promiseThen(promise_or_val, @backingInt(id)) else try checkStatus(wasm_host.promise_then(@backingInt(promise_or_val), @backingInt(id)));
    return id;
}
pub fn awaitCallback(comptime Ctx: type, promise_or_val: Handle, ctx: *Ctx, comptime onSettle: fn (*Ctx, Outcome) void) Error!CallbackId {
    const Trampoline = struct {
        fn invokeCb(raw_ctx: ?*anyopaque, outcome: Outcome) void {
            if (@sizeOf(Ctx) == 0) {
                var zst: Ctx = undefined;
                onSettle(&zst, outcome);
            } else onSettle(@ptrCast(@alignCast(raw_ctx.?)), outcome);
        }
    };
    return then(promise_or_val, if (@sizeOf(Ctx) == 0) null else @ptrCast(ctx), Trampoline.invokeCb);
}
pub fn cancel(cb_id: CallbackId) void {
    _ = takeCallbackSlot(cb_id);
}
pub fn ignorePromise(h: Handle) void {
    if (h.isReserved() or h == .invalid or use_mock) return;
    _ = wasm_host.promise_then(@backingInt(h), 0);
}
pub fn pendingCallbackCount() u32 {
    return cb_live;
}
pub fn resetCallbacksForTest() void {
    const gpa = cbAllocator();
    cb_slots.deinit(gpa);
    cb_free.deinit(gpa);
    cb_slots = .empty;
    cb_free = .empty;
    cb_live = 0;
}

pub fn nanoui_js_settle(cb_id_raw: u32, ok: u32, raw_handle: u32) callconv(.c) void {
    const h: Handle = @fromBackingInt(raw_handle);
    defer h.release();
    const entry = takeCallbackSlot(@fromBackingInt(cb_id_raw)) orelse return;
    if (ok == 1) {
        entry.cb(entry.ctx, .{ .resolved = h });
    } else if (use_mock) {
        entry.cb(entry.ctx, .{ .rejected = mock.peekString(h) });
    } else {
        var stack_buf: [256]u8 = undefined;
        var total_len: u32 = 0;
        if (wasm_host.read_buf(0, raw_handle, &stack_buf, stack_buf.len, &total_len) != 0) {
            entry.cb(entry.ctx, .{ .rejected = "Error" });
        } else if (total_len <= stack_buf.len) {
            entry.cb(entry.ctx, .{ .rejected = stack_buf[0..total_len] });
        } else if (cbAllocator().alloc(u8, total_len)) |heap| {
            defer cbAllocator().free(heap);
            wasm_host.read_pending(heap.ptr, total_len);
            entry.cb(entry.ctx, .{ .rejected = heap });
        } else |_| {
            wasm_host.read_pending(&stack_buf, 0);
            entry.cb(entry.ctx, .{ .rejected = "OutOfMemory" });
        }
    }
    if (wake_hook) |w| w();
}
