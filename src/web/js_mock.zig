//! Pure-Zig deterministic mock backend for `src/web/js.zig`.
const std = @import("std");
const builtin = @import("builtin");
const js = @import("js.zig");

const Handle = js.Handle;
const Arg = js.Arg;
const Error = js.Error;

pub const MockReturn = union(enum) { handle: Handle, arg: Arg, throw: []const u8 };
pub const MockFn = *const fn (ctx: ?*anyopaque, this: Handle, args: []const Arg) MockReturn;

pub const MockPromise = struct {
    handle: Handle,
    node: *Node,
    pub fn resolve(self: MockPromise, value: Arg) void {
        settlePromise(self.node, true, value, "");
    }
    pub fn reject(self: MockPromise, message: []const u8) void {
        settlePromise(self.node, false, .undef, message);
    }
    pub fn release(self: MockPromise) void {
        self.handle.release();
    }
};

const Val = union(enum) { undef, null, boolean: bool, global, node: *Node };
const ObjectMap = std.StringArrayHashMapUnmanaged(Val);
const PromiseState = struct { state: enum { pending, resolved, rejected } = .pending, resolved: Val = .undef, rejected: []u8 = &.{}, waiters: std.ArrayList(u32) = .empty };
const Value = union(enum) { number: f64, bigint: i128, string: []u8, bytes: []u8, array: std.ArrayList(Val), object: ObjectMap, func: struct { ctx: ?*anyopaque, handler: MockFn }, promise: PromiseState };
const Node = struct { refs: u32 = 1, all_idx: usize = 0, value: Value };
const Slot = struct { gen: u8 = 1, node: ?*Node = null };

var slots: std.ArrayList(Slot) = .empty;
var free_slots: std.ArrayList(u24) = .empty;
var all_nodes: std.ArrayList(*Node) = .empty;
var global_props: ObjectMap = .empty;
var last_err: []u8 = &.{};

fn gpa() std.mem.Allocator {
    return if (builtin.is_test) std.testing.allocator else if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
}
fn setError(msg: []const u8) Error {
    if (last_err.len > 0) gpa().free(last_err);
    last_err = gpa().dupe(u8, msg) catch &.{};
    return error.JsException;
}
fn newNode(v: Value) Error!*Node {
    const alloc = gpa();
    const n = try alloc.create(Node);
    errdefer alloc.destroy(n);
    n.* = .{ .refs = 1, .all_idx = all_nodes.items.len, .value = v };
    try all_nodes.append(alloc, n);
    return n;
}
fn newDupeNode(comptime is_bytes: bool, slice: []const u8) Error!*Node {
    const copy = try gpa().dupe(u8, slice);
    errdefer gpa().free(copy);
    return newNode(if (is_bytes) .{ .bytes = copy } else .{ .string = copy });
}
fn releaseVal(v: Val) void {
    if (v == .node) unrefNode(v.node);
}
fn freePayload(n: *Node) void {
    const alloc = gpa();
    switch (n.value) {
        .number, .bigint, .func => {},
        .string => |s| alloc.free(s),
        .bytes => |b| alloc.free(b),
        .array => |*arr| arr.deinit(alloc),
        .object => |*map| {
            for (map.keys()) |k| alloc.free(k);
            map.deinit(alloc);
        },
        .promise => |*p| {
            if (p.rejected.len > 0) alloc.free(p.rejected);
            p.waiters.deinit(alloc);
        },
    }
}
fn unrefNode(n: *Node) void {
    if (n.refs > 1) {
        n.refs -= 1;
        return;
    }
    const last = all_nodes.pop().?;
    if (n.all_idx < all_nodes.items.len) {
        all_nodes.items[n.all_idx] = last;
        last.all_idx = n.all_idx;
    }
    switch (n.value) {
        .array => |arr| for (arr.items) |item| releaseVal(item),
        .object => |map| for (map.values()) |item| releaseVal(item),
        .promise => |p| if (p.state == .resolved) releaseVal(p.resolved),
        else => {},
    }
    freePayload(n);
    gpa().destroy(n);
}
fn allocSlot(n: *Node) Error!Handle {
    errdefer unrefNode(n);
    const alloc = gpa();
    while (slots.items.len < 5) try slots.append(alloc, .{ .gen = 0 });
    const idx: u24 = if (free_slots.items.len > 0) free_slots.pop().? else blk: {
        if (slots.items.len > std.math.maxInt(u24)) return error.OutOfMemory;
        const next: u24 = @intCast(slots.items.len);
        try slots.append(alloc, .{});
        break :blk next;
    };
    slots.items[idx].node = n;
    return Handle.pack(slots.items[idx].gen, idx);
}
fn resolveVal(h: Handle) Error!Val {
    return switch (h) {
        .undef => .undef,
        .null => .null,
        .false => .{ .boolean = false },
        .true => .{ .boolean = true },
        .global => .global,
        .invalid => error.InvalidHandle,
        _ => if (h.generation() == 0 or h.generation() == 0xFF or h.index() < 5 or h.index() >= slots.items.len or slots.items[h.index()].gen != h.generation() or slots.items[h.index()].node == null)
            error.InvalidHandle
        else
            .{ .node = slots.items[h.index()].node.? },
    };
}
fn valToHandle(v: Val) Error!Handle {
    return switch (v) {
        .undef => .undef,
        .null => .null,
        .boolean => |b| if (b) .true else .false,
        .global => .global,
        .node => |n| blk: {
            n.refs += 1;
            break :blk allocSlot(n);
        },
    };
}
fn argToVal(arg: Arg) Error!Val {
    return switch (arg) {
        .undef => .undef,
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .i32 => |v| .{ .node = try newNode(.{ .number = @floatFromInt(v) }) },
        .u32 => |v| .{ .node = try newNode(.{ .number = @floatFromInt(v) }) },
        .usize => |v| .{ .node = try newNode(.{ .number = @floatFromInt(v) }) },
        .f64 => |v| .{ .node = try newNode(.{ .number = v }) },
        .u64 => |v| .{ .node = try newNode(.{ .bigint = v }) },
        .string => |s| .{ .node = try newDupeNode(false, s) },
        .bytes => |b| .{ .node = try newDupeNode(true, b) },
        .handle => |h| blk: {
            const v = try resolveVal(h);
            if (v == .node) v.node.refs += 1;
            break :blk v;
        },
    };
}

pub fn reset() void {
    const alloc = gpa();
    for (global_props.keys()) |k| alloc.free(k);
    global_props.deinit(alloc);
    global_props = .empty;
    for (all_nodes.items) |n| {
        freePayload(n);
        alloc.destroy(n);
    }
    all_nodes.deinit(alloc);
    slots.deinit(alloc);
    free_slots.deinit(alloc);
    all_nodes = .empty;
    slots = .empty;
    free_slots = .empty;
    if (last_err.len > 0) alloc.free(last_err);
    last_err = &.{};
    js.resetCallbacksForTest();
}
pub fn newCollection(is_arr: bool) Error!Handle {
    return allocSlot(try newNode(if (is_arr) .{ .array = .empty } else .{ .object = .empty }));
}
pub fn allocArg(a: Arg) Error!Handle {
    const v = try argToVal(a);
    return if (v == .node) allocSlot(v.node) else valToHandle(v);
}
pub fn func(ctx: ?*anyopaque, handler: MockFn) Error!Handle {
    return allocSlot(try newNode(.{ .func = .{ .ctx = ctx, .handler = handler } }));
}
pub fn createPromise() Error!MockPromise {
    const n = try newNode(.{ .promise = .{} });
    const h = try allocSlot(n);
    n.refs += 1;
    return .{ .handle = h, .node = n };
}
pub fn dup(h: Handle) Handle {
    const v = resolveVal(h) catch return .invalid;
    if (v != .node) return h;
    v.node.refs += 1;
    return allocSlot(v.node) catch .invalid;
}
pub fn release(h: Handle) void {
    const idx = h.index();
    const gen = h.generation();
    if (gen == 0 or gen == 0xFF or idx < 5 or idx >= slots.items.len) return;
    const s = &slots.items[idx];
    if (s.gen != gen or s.node == null) return;
    const n = s.node.?;
    s.* = .{ .gen = (s.gen % 254) + 1 };
    free_slots.append(gpa(), idx) catch {};
    unrefNode(n);
}
pub fn liveCount() u32 {
    return if (slots.items.len <= 5) 0 else @intCast(slots.items.len - 5 - free_slots.items.len);
}
pub fn valueFlags(h: Handle) Error!u32 {
    return switch (try resolveVal(h)) {
        .undef => @backingInt(js.Type.undefined),
        .null => @backingInt(js.Type.null),
        .boolean => @backingInt(js.Type.boolean),
        .global => @backingInt(js.Type.object),
        .node => |n| switch (n.value) {
            .number => @backingInt(js.Type.number),
            .bigint => @backingInt(js.Type.bigint),
            .string => @backingInt(js.Type.string),
            .func => @backingInt(js.Type.function),
            .array => @as(u32, @backingInt(js.Type.object)) | 16,
            .promise => @as(u32, @backingInt(js.Type.object)) | 32,
            .bytes => @as(u32, @backingInt(js.Type.object)) | 64,
            .object => |map| if (map.get("then")) |tv|
                (if (tv == .node and tv.node.value == .func) @as(u32, @backingInt(js.Type.object)) | 32 else @backingInt(js.Type.object))
            else
                @backingInt(js.Type.object),
        },
    };
}
fn putMapProp(map: *ObjectMap, key: []const u8, v: Val) Error!void {
    if (map.getPtr(key)) |existing| {
        releaseVal(existing.*);
        existing.* = v;
        return;
    }
    const owned = try gpa().dupe(u8, key);
    errdefer gpa().free(owned);
    try map.put(gpa(), owned, v);
}
pub fn get(target: Handle, key: []const u8) Error!Handle {
    return switch (try resolveVal(target)) {
        .undef, .null => setError("TypeError: Cannot read properties of null or undefined"),
        .global => if (global_props.get(key)) |v| valToHandle(v) else .undef,
        .boolean => .undef,
        .node => |n| switch (n.value) {
            .object => |map| if (map.get(key)) |v| valToHandle(v) else .undef,
            .array => |arr| if (std.mem.eql(u8, key, "length")) allocArg(.{ .usize = arr.items.len }) else .undef,
            .string => |s| if (std.mem.eql(u8, key, "length")) allocArg(.{ .usize = s.len }) else .undef,
            .bytes => |b| if (std.mem.eql(u8, key, "byteLength") or std.mem.eql(u8, key, "length")) allocArg(.{ .usize = b.len }) else .undef,
            else => .undef,
        },
    };
}
pub fn getIndex(target: Handle, index: usize) Error!Handle {
    const v = try resolveVal(target);
    if (v == .node and v.node.value == .array) return if (index < v.node.value.array.items.len) valToHandle(v.node.value.array.items[index]) else .undef;
    if (v == .node and v.node.value == .bytes) return if (index < v.node.value.bytes.len) allocArg(.{ .u32 = v.node.value.bytes[index] }) else .undef;
    var buf: [24]u8 = undefined;
    return get(target, std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable);
}
pub fn set(target: Handle, key: []const u8, value: Arg) Error!void {
    const t = try resolveVal(target);
    const v = try argToVal(value);
    errdefer releaseVal(v);
    if (t == .global) return putMapProp(&global_props, key, v);
    if (t == .node and t.node.value == .object) return putMapProp(&t.node.value.object, key, v);
    return setError("TypeError: Cannot set property on non-object");
}
pub fn setIndex(target: Handle, index: usize, value: Arg) Error!void {
    const t = try resolveVal(target);
    if (t == .node and t.node.value == .array) {
        const v = try argToVal(value);
        errdefer releaseVal(v);
        const arr = &t.node.value.array;
        while (arr.items.len <= index) try arr.append(gpa(), .undef);
        releaseVal(arr.items[index]);
        arr.items[index] = v;
        return;
    }
    var buf: [24]u8 = undefined;
    return set(target, std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable, value);
}
pub fn has(target: Handle, key: []const u8) Error!bool {
    return switch (try resolveVal(target)) {
        .global => global_props.contains(key),
        .node => |n| switch (n.value) {
            .object => |map| map.contains(key),
            .array => std.mem.eql(u8, key, "length"),
            .bytes => std.mem.eql(u8, key, "byteLength") or std.mem.eql(u8, key, "length"),
            else => setError("TypeError: Cannot use 'in' operator on primitive"),
        },
        else => setError("TypeError: Cannot use 'in' operator on primitive"),
    };
}
pub fn delete(target: Handle, key: []const u8) Error!void {
    const t = try resolveVal(target);
    if (t == .undef or t == .null) return setError("TypeError: Cannot convert undefined or null to object");
    const map: *ObjectMap = if (t == .global) &global_props else if (t == .node and t.node.value == .object) &t.node.value.object else return;
    if (map.fetchOrderedRemove(key)) |kv| {
        gpa().free(kv.key);
        releaseVal(kv.value);
    }
}
pub fn len(target: Handle) Error!usize {
    const v = try resolveVal(target);
    if (v != .node) return error.TypeMismatch;
    return switch (v.node.value) {
        .array => |arr| arr.items.len,
        .bytes => |b| b.len,
        .string => |s| s.len,
        else => error.TypeMismatch,
    };
}
pub fn asNumber(h: Handle) Error!f64 {
    const v = try resolveVal(h);
    return if (v == .node and v.node.value == .number) v.node.value.number else error.TypeMismatch;
}
pub fn asInt64(h: Handle, signed: bool) Error!u64 {
    const v = try resolveVal(h);
    if (v != .node) return error.TypeMismatch;
    if (signed) return switch (v.node.value) {
        .number => |f| if (std.math.isFinite(f) and @trunc(f) == f and @abs(f) <= 9007199254740991.0) @bitCast(@as(i64, @intFromFloat(f))) else error.TypeMismatch,
        .bigint => |bi| if (bi >= std.math.minInt(i64) and bi <= std.math.maxInt(i64)) @bitCast(@as(i64, @intCast(bi))) else error.TypeMismatch,
        else => error.TypeMismatch,
    };
    return switch (v.node.value) {
        .number => |f| if (std.math.isFinite(f) and @trunc(f) == f and f >= 0 and f <= 9007199254740991.0) @intFromFloat(f) else error.TypeMismatch,
        .bigint => |bi| if (bi >= 0 and bi <= std.math.maxInt(u64)) @intCast(bi) else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}
pub fn peekString(h: Handle) []const u8 {
    const v = resolveVal(h) catch return "Error";
    return if (v == .node and v.node.value == .string) v.node.value.string else "Error";
}
pub fn readBuf(mode: u2, h: Handle, out_gpa: std.mem.Allocator) Error![]u8 {
    if (mode == 3) return out_gpa.dupe(u8, last_err);
    if (mode == 2) return stringifyJson(h, out_gpa);
    const v = try resolveVal(h);
    if (v != .node) return error.TypeMismatch;
    return switch (v.node.value) {
        .string => |s| if (mode == 0) out_gpa.dupe(u8, s) else error.TypeMismatch,
        .bytes => |b| if (mode == 1) out_gpa.dupe(u8, b) else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn jsonToVal(jv: std.json.Value) Error!Val {
    return switch (jv) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .node = try newNode(.{ .number = @floatFromInt(i) }) },
        .float => |f| .{ .node = try newNode(.{ .number = f }) },
        .number_string => |s| .{ .node = try newNode(.{ .number = std.fmt.parseFloat(f64, s) catch return setError("SyntaxError: Invalid JSON") }) },
        .string => |s| .{ .node = try newDupeNode(false, s) },
        .array => |arr| blk: {
            const n = try newNode(.{ .array = .empty });
            errdefer unrefNode(n);
            for (arr.items) |item| {
                const elem = try jsonToVal(item);
                errdefer releaseVal(elem);
                try n.value.array.append(gpa(), elem);
            }
            break :blk .{ .node = n };
        },
        .object => |obj| blk: {
            const n = try newNode(.{ .object = .empty });
            errdefer unrefNode(n);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const elem = try jsonToVal(entry.value_ptr.*);
                errdefer releaseVal(elem);
                try putMapProp(&n.value.object, entry.key_ptr.*, elem);
            }
            break :blk .{ .node = n };
        },
    };
}
pub fn parseJson(json_utf8: []const u8) Error!Handle {
    var arena = std.heap.ArenaAllocator.init(gpa());
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_utf8, .{}) catch return setError("SyntaxError: Unexpected token in JSON");
    const v = try jsonToVal(parsed);
    return if (v == .node) allocSlot(v.node) else valToHandle(v);
}

fn writeJsonMap(map: *const ObjectMap, out: *std.Io.Writer, stack: *std.ArrayList(*Node)) anyerror!void {
    try out.writeByte('{');
    var first = true;
    for (map.keys(), map.values()) |k, val| {
        if (val == .undef or (val == .node and val.node.value == .func)) continue;
        if (!first) try out.writeByte(',');
        first = false;
        try std.json.Stringify.encodeJsonString(k, .{}, out);
        try out.writeByte(':');
        try writeJsonVal(val, out, stack);
    }
    try out.writeByte('}');
}
fn writeJsonVal(v: Val, out: *std.Io.Writer, stack: *std.ArrayList(*Node)) anyerror!void {
    switch (v) {
        .undef, .null => try out.writeAll("null"),
        .boolean => |b| try out.writeAll(if (b) "true" else "false"),
        .global => try writeJsonMap(&global_props, out, stack),
        .node => |n| {
            for (stack.items) |seen| {
                if (seen == n) return setError("TypeError: Converting circular structure to JSON");
            }
            try stack.append(gpa(), n);
            defer _ = stack.pop();
            switch (n.value) {
                .bigint => return setError("TypeError: Do not know how to serialize a BigInt"),
                .func => try out.writeAll("null"),
                .number => |f| if (!std.math.isFinite(f))
                    try out.writeAll("null")
                else if (@trunc(f) == f and @abs(f) <= 9007199254740991.0)
                    try out.print("{d}", .{@as(i64, @intFromFloat(f))})
                else
                    try std.json.Stringify.value(f, .{}, out),
                .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, out),
                .array => |arr| {
                    try out.writeByte('[');
                    for (arr.items, 0..) |item, i| {
                        if (i > 0) try out.writeByte(',');
                        try writeJsonVal(item, out, stack);
                    }
                    try out.writeByte(']');
                },
                .object => |*map| try writeJsonMap(map, out, stack),
                .bytes => |b| {
                    try out.writeByte('{');
                    for (b, 0..) |byte, i| try out.print("{s}\"{d}\":{d}", .{ if (i > 0) "," else "", i, byte });
                    try out.writeByte('}');
                },
                .promise => try out.writeAll("{}"),
            }
        },
    }
}
fn stringifyJson(h: Handle, out_gpa: std.mem.Allocator) Error![]u8 {
    const v = try resolveVal(h);
    if (v == .undef or (v == .node and v.node.value == .func)) return error.TypeMismatch;
    var stack: std.ArrayList(*Node) = .empty;
    defer stack.deinit(gpa());
    var aw: std.Io.Writer.Allocating = .init(out_gpa);
    errdefer aw.deinit();
    writeJsonVal(v, &aw.writer, &stack) catch |err| return if (err == error.JsException) error.JsException else error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn invokeMockFn(fv: Val, this_h: Handle, args: []const Arg, comptime is_ctor: bool) Error!Handle {
    for (args) |a| {
        if (a == .handle) _ = try resolveVal(a.handle);
    }
    if (fv != .node or fv.node.value != .func) return setError(if (is_ctor) "TypeError: target is not a constructor" else "TypeError: target is not a function");
    return switch (fv.node.value.func.handler(fv.node.value.func.ctx, this_h, args)) {
        .handle => |h| blk: {
            _ = try resolveVal(h);
            break :blk h;
        },
        .arg => |a| allocArg(a),
        .throw => |msg| setError(msg),
    };
}
pub fn call(fn_handle: Handle, this_handle: Handle, args: []const Arg) Error!Handle {
    const fv = try resolveVal(fn_handle);
    _ = try resolveVal(this_handle);
    return invokeMockFn(fv, this_handle, args, false);
}
pub fn invoke(target: Handle, method: []const u8, args: []const Arg) Error!Handle {
    const prop = try get(target, method);
    defer prop.release();
    return call(prop, target, args);
}
pub fn construct(ctor_handle: Handle, args: []const Arg) Error!Handle {
    const fv = try resolveVal(ctor_handle);
    const inst = try newCollection(false);
    defer inst.release();
    const res = try invokeMockFn(fv, inst, args, true);
    return if (res == .undef) dup(inst) else res;
}
pub fn promiseThen(h: Handle, cb_id: u32) Error!void {
    const v = try resolveVal(h);
    if (v == .node and v.node.value == .promise) {
        const p = &v.node.value.promise;
        switch (p.state) {
            .pending => return p.waiters.append(gpa(), cb_id),
            .resolved => js.nanoui_js_settle(cb_id, 1, @backingInt(try valToHandle(p.resolved))),
            .rejected => js.nanoui_js_settle(cb_id, 0, @backingInt(try allocArg(.{ .string = p.rejected }))),
        }
        return;
    }
    js.nanoui_js_settle(cb_id, 1, @backingInt(try valToHandle(v)));
}
fn settlePromise(n: *Node, ok: bool, value: Arg, message: []const u8) void {
    const p = &n.value.promise;
    if (p.state != .pending) return;
    defer unrefNode(n);
    if (ok) {
        p.resolved = argToVal(value) catch return;
        p.state = .resolved;
    } else {
        p.rejected = gpa().dupe(u8, message) catch return;
        p.state = .rejected;
    }
    var waiters = p.waiters;
    p.waiters = .empty;
    defer waiters.deinit(gpa());
    for (waiters.items) |cb_id| {
        const th = (if (ok) valToHandle(p.resolved) else allocArg(.{ .string = p.rejected })) catch continue;
        js.nanoui_js_settle(cb_id, @intFromBool(ok), @backingInt(th));
    }
}
