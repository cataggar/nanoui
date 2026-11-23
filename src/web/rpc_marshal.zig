//! Compile-time validation and hybrid JS/JSON marshalling for `src/web/rpc.zig`.
const std = @import("std");
const js = @import("js.zig");
const tsgen = @import("../tsgen.zig");

/// Binary buffer marshalled directly as a JS `Uint8Array` without Base64/JSON.
pub const Bytes = struct {
    data: []const u8,
    pub const nanoui_ts_type = "Uint8Array";

    pub fn init(slice: []const u8) Bytes {
        return .{ .data = slice };
    }
};

/// Per-call context injected into bound Zig service methods taking `*rpc.Call`.
pub const Call = struct {
    arena: std.mem.Allocator,
    pub const nanoui_call_context = {};
};

pub const Error = js.Error || error{
    UnknownService,
    UnknownMethod,
    MissingArgument,
    TooManyArguments,
    InvalidArgument,
    NoHostBound,
    AsyncHostResult,
};

pub const TempHandles = struct {
    buf: [js.max_args]js.Handle = undefined,
    len: usize = 0,

    pub fn add(self: *TempHandles, h: js.Handle) js.Handle {
        self.buf[self.len] = h;
        self.len += 1;
        return h;
    }

    pub fn releaseAll(self: *TempHandles) void {
        for (self.buf[0..self.len]) |h| h.release();
        self.len = 0;
    }
};

pub fn isCallParam(comptime P: type) bool {
    if (@typeInfo(P) != .pointer) return false;
    const ptr = @typeInfo(P).pointer;
    if (ptr.size != .one) return false;
    const C = ptr.child;
    if (C == Call) return true;
    switch (@typeInfo(C)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(C, "nanoui_call_context")) {
            @compileError("nanoui.web.rpc: call context parameter must be *nanoui.web.rpc.Call, got " ++ @typeName(P));
        },
        else => {},
    }
    return false;
}

fn hasType(comptime list: []const type, comptime T: type) bool {
    for (list) |item| {
        if (item == T) return true;
    }
    return false;
}

pub fn validateRpcType(comptime T: type, comptime top_level: bool, comptime seen: []const type) void {
    comptime {
        if (T == js.Handle or T == Bytes) {
            if (!top_level) {
                @compileError("nanoui.web.rpc: js.Handle and rpc.Bytes must be top-level RPC arguments or return values");
            }
            return;
        }
        if (T == std.json.Value) return;
        switch (@typeInfo(T)) {
            .void, .bool, .float => return,
            .int => |info| {
                if (T == usize or T == isize or info.bits > 53) {
                    @compileError("nanoui.web.rpc: 64-bit integers lose precision in JS numbers; use u32/i32/f64, string, or Layer 1 js.bigint");
                }
            },
            .optional => |o| validateRpcType(o.child, top_level, seen),
            .array => |a| {
                if (a.child == u8) return;
                validateRpcType(a.child, false, seen);
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    if (p.child == u8) return;
                    validateRpcType(p.child, false, seen);
                },
                .one => {
                    if (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return;
                    validateRpcType(p.child, false, seen);
                },
                else => @compileError("nanoui.web.rpc: unsupported pointer type " ++ @typeName(T)),
            },
            .@"enum" => return,
            .@"union" => |u| {
                if (u.tag_type == null) @compileError("nanoui.web.rpc: untagged unions are not supported: " ++ @typeName(T));
                if (hasType(seen, T)) return;
                const next = seen ++ .{T};
                for (u.field_types) |FT| {
                    if (FT != void) validateRpcType(FT, false, next);
                }
            },
            .@"struct" => |s| {
                if (s.is_tuple) @compileError("nanoui.web.rpc: tuples are not supported: " ++ @typeName(T));
                if (hasType(seen, T)) return;
                const next = seen ++ .{T};
                for (s.field_types) |FT| validateRpcType(FT, false, next);
            },
            else => @compileError("nanoui.web.rpc: unsupported type " ++ @typeName(T)),
        }
    }
}

pub fn validateService(comptime T: type) void {
    comptime {
        @setEvalBranchQuota(100_000);
        if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) {
            @compileError("nanoui.web.rpc: bound service must be a struct: " ++ @typeName(T));
        }
        for (tsgen.methodNames(T)) |m| {
            const F = @typeInfo(@TypeOf(@field(T, m))).@"fn";
            for (F.param_types[1..]) |P_opt| {
                const P = P_opt.?;
                if (isCallParam(P)) continue;
                validateRpcType(P, true, &.{});
            }
            const R = F.return_type.?;
            const Payload = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
            validateRpcType(Payload, true, &.{});
        }
    }
}

pub const FnInfo = @TypeOf(@typeInfo(fn () void).@"fn");

pub fn hostFnInfo(comptime H: type, comptime m: []const u8, comptime FT: type) FnInfo {
    comptime {
        const f = switch (@typeInfo(FT)) {
            .@"fn" => |fn_info| fn_info,
            .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .@"fn")
                @typeInfo(p.child).@"fn"
            else
                @compileError("nanoui.web.rpc: host interface field '" ++ m ++ "' in " ++ @typeName(H) ++ " must be fn or *const fn"),
            else => @compileError("nanoui.web.rpc: host interface field '" ++ m ++ "' in " ++ @typeName(H) ++ " must be fn or *const fn"),
        };
        if (f.is_generic) @compileError("nanoui.web.rpc: generic functions are not supported in host interface: " ++ @typeName(H) ++ "." ++ m);
        if (f.param_types.len > js.max_args) @compileError("nanoui.web.rpc: host method '" ++ m ++ "' exceeds js.max_args");
        return f;
    }
}

pub fn validateHost(comptime H: type) void {
    comptime {
        @setEvalBranchQuota(100_000);
        if (@typeInfo(H) != .@"struct" or @typeInfo(H).@"struct".is_tuple) {
            @compileError("nanoui.web.rpc: host interface must be a struct: " ++ @typeName(H));
        }
        const s = @typeInfo(H).@"struct";
        for (s.field_names, s.field_types) |m, FT| {
            const f = hostFnInfo(H, m, FT);
            for (f.param_types) |P_opt| validateRpcType(P_opt.?, true, &.{});
            const R = f.return_type.?;
            const Payload = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
            validateRpcType(Payload, true, &.{});
        }
    }
}

fn encodeJsonHandle(comptime T: type, gpa: std.mem.Allocator, value: T) Error!js.Handle {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    std.json.Stringify.value(value, .{}, &aw.writer) catch return error.OutOfMemory;
    return js.parseJson(aw.written());
}

/// Encodes a Zig value into a JS `Handle`. When returning a `js.Handle` from a
/// bound Zig service to JS, the bridge extracts the value and releases the
/// returned handle slot so `h.dup()` or newly created handles leave 0 leaks.
pub fn encodeToHandle(comptime T: type, gpa: std.mem.Allocator, value: T) Error!js.Handle {
    comptime validateRpcType(T, true, &.{});
    if (T == void) return .undef;
    if (T == bool) return js.boolean(value);
    if (T == js.Handle) return value;
    if (T == Bytes) return js.bytes(value.data);
    return switch (@typeInfo(T)) {
        .int => js.number(@floatFromInt(value)),
        .float => js.number(@floatCast(value)),
        .optional => if (value) |inner| encodeToHandle(@TypeOf(inner), gpa, inner) else .null,
        .array => |a| if (a.child == u8) js.string(&value) else encodeJsonHandle(T, gpa, value),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) js.string(value) else encodeJsonHandle(T, gpa, value),
            .one => encodeToHandle(p.child, gpa, value.*),
            else => unreachable,
        },
        else => encodeJsonHandle(T, gpa, value),
    };
}

pub fn encodeToArg(comptime T: type, gpa: std.mem.Allocator, value: T, temps: *TempHandles) Error!js.Arg {
    comptime validateRpcType(T, true, &.{});
    if (T == void) return .undef;
    if (T == bool) return .{ .bool = value };
    if (T == js.Handle) return .{ .handle = value };
    if (T == Bytes) return .{ .handle = temps.add(try js.bytes(value.data)) };
    return switch (@typeInfo(T)) {
        .int => |info| if (info.bits <= 32)
            (if (info.signedness == .signed) .{ .i32 = @intCast(value) } else .{ .u32 = @intCast(value) })
        else
            .{ .f64 = @floatFromInt(value) },
        .float => .{ .f64 = @floatCast(value) },
        .optional => |o| if (value) |inner| encodeToArg(o.child, gpa, inner, temps) else .null,
        .array => |a| if (a.child == u8)
            .{ .handle = temps.add(try js.string(&value)) }
        else
            .{ .handle = temps.add(try encodeJsonHandle(T, gpa, value)) },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) .{ .string = value } else .{ .handle = temps.add(try encodeJsonHandle(T, gpa, value)) },
            .one => if (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)
                .{ .string = value[0..@typeInfo(p.child).array.len] }
            else
                encodeToArg(p.child, gpa, value.*, temps),
            else => unreachable,
        },
        else => .{ .handle = temps.add(try encodeJsonHandle(T, gpa, value)) },
    };
}

pub fn decodeFromHandle(comptime T: type, arena: std.mem.Allocator, h: js.Handle) Error!T {
    comptime validateRpcType(T, true, &.{});
    if (T == void) return {};
    if (T == js.Handle) return h;
    if (T == Bytes) {
        const b = js.readBytes(h, arena) catch |err| return switch (err) {
            error.OutOfMemory, error.InvalidHandle => err,
            else => error.InvalidArgument,
        };
        return .{ .data = b };
    }
    return switch (@typeInfo(T)) {
        .bool => js.asBool(h) catch |err| return switch (err) {
            error.InvalidHandle => err,
            else => error.InvalidArgument,
        },
        .int => js.asInt(T, h) catch |err| return switch (err) {
            error.InvalidHandle => err,
            else => error.InvalidArgument,
        },
        .float => @floatCast(js.asNumber(h) catch |err| return switch (err) {
            error.InvalidHandle => err,
            else => error.InvalidArgument,
        }),
        .optional => |o| if (try js.isNullOrUndefined(h)) null else try decodeFromHandle(o.child, arena, h),
        .array => |a| if (a.child == u8) blk: {
            const s = js.readString(h, arena) catch |err| return switch (err) {
                error.OutOfMemory, error.InvalidHandle => err,
                else => error.InvalidArgument,
            };
            if (s.len != a.len) return error.InvalidArgument;
            var out: [a.len]u8 = undefined;
            @memcpy(&out, s);
            break :blk out;
        } else decodeJsonHandle(T, arena, h),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) (js.readString(h, arena) catch |err| return switch (err) {
                error.OutOfMemory, error.InvalidHandle => err,
                else => error.InvalidArgument,
            }) else decodeJsonHandle(T, arena, h),
            .one => blk: {
                const ptr = try arena.create(p.child);
                ptr.* = try decodeFromHandle(p.child, arena, h);
                break :blk ptr;
            },
            else => unreachable,
        },
        else => decodeJsonHandle(T, arena, h),
    };
}

fn decodeJsonHandle(comptime T: type, arena: std.mem.Allocator, h: js.Handle) Error!T {
    if (T != std.json.Value and (@typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union")) {
        if ((try js.isBytes(h)) or (try js.isPromise(h))) return error.InvalidArgument;
    }
    const json_bytes = js.stringifyJson(h, arena) catch |err| return switch (err) {
        error.OutOfMemory, error.InvalidHandle => err,
        else => error.InvalidArgument,
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_bytes, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgument,
    };
    return decodeJsonValue(T, arena, root);
}

fn decodeJsonValue(comptime T: type, arena: std.mem.Allocator, val: std.json.Value) Error!T {
    if (T == std.json.Value) return val;
    switch (@typeInfo(T)) {
        .optional => |o| return if (val == .null) null else try decodeJsonValue(o.child, arena, val),
        .@"struct" => |s| {
            if (std.meta.hasFn(T, "jsonParseFromValue")) return parseLeafJsonValue(T, arena, val);
            const obj = switch (val) {
                .object => |o| o,
                else => return error.InvalidArgument,
            };
            var r: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |fname, FT, fattrs| {
                if (obj.get(fname)) |fval| {
                    @field(r, fname) = try decodeJsonValue(FT, arena, fval);
                } else if (@typeInfo(FT) == .optional) {
                    @field(r, fname) = null;
                } else if (comptime fattrs.defaultValue(FT)) |default| {
                    @field(r, fname) = default;
                } else {
                    return error.InvalidArgument;
                }
            }
            return r;
        },
        .@"union" => |u| {
            if (std.meta.hasFn(T, "jsonParseFromValue")) return parseLeafJsonValue(T, arena, val);
            const obj = switch (val) {
                .object => |o| o,
                else => return error.InvalidArgument,
            };
            if (obj.count() != 1) return error.InvalidArgument;
            var it = obj.iterator();
            const entry = it.next().?;
            inline for (u.field_names, u.field_types) |uf, UT| {
                if (std.mem.eql(u8, uf, entry.key_ptr.*)) {
                    if (UT == void) {
                        if (entry.value_ptr.* != .object or entry.value_ptr.object.count() != 0) return error.InvalidArgument;
                        return @unionInit(T, uf, {});
                    }
                    return @unionInit(T, uf, try decodeJsonValue(UT, arena, entry.value_ptr.*));
                }
            }
            return error.InvalidArgument;
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return parseLeafJsonValue(T, arena, val);
                const arr = switch (val) {
                    .array => |a| a,
                    else => return error.InvalidArgument,
                };
                const out = try arena.alloc(p.child, arr.items.len);
                for (arr.items, 0..) |iv, i| out[i] = try decodeJsonValue(p.child, arena, iv);
                return out;
            },
            .one => {
                const ptr = try arena.create(p.child);
                ptr.* = try decodeJsonValue(p.child, arena, val);
                return ptr;
            },
            else => unreachable,
        },
        .array => |a| {
            if (a.child == u8) return parseLeafJsonValue(T, arena, val);
            const arr = switch (val) {
                .array => |ar| ar,
                else => return error.InvalidArgument,
            };
            if (arr.items.len != a.len) return error.InvalidArgument;
            var out: T = undefined;
            for (arr.items, 0..) |iv, i| out[i] = try decodeJsonValue(a.child, arena, iv);
            return out;
        },
        else => return parseLeafJsonValue(T, arena, val),
    }
}

fn parseLeafJsonValue(comptime T: type, arena: std.mem.Allocator, val: std.json.Value) Error!T {
    return std.json.parseFromValueLeaky(T, arena, val, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgument,
    };
}
