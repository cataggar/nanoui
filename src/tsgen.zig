//! TypeScript declarations and the JavaScript client, generated at comptime
//! from bound services and events. Zig keeps no parameter names in function
//! types, so a service may name them: `pub const nanoui_params = .{ .greet = .{"name"} };`
const std = @import("std");

/// A named type declaration (`interface X {...}` or `type X = ...`), deduped
/// by name across services.
pub const Decl = struct { name: []const u8, source: []const u8 };

pub fn shortName(comptime T: type) []const u8 {
    if (@hasDecl(T, "nanoui_name")) return T.nanoui_name;
    const full = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// True for the methods a service exposes: public functions whose first
/// parameter is the service itself.
pub fn isMethod(comptime T: type, comptime name: []const u8) bool {
    const F = @TypeOf(@field(T, name));
    const info = @typeInfo(F);
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.is_generic or f.param_types.len == 0 or name[0] == '_') return false;
    const P = f.param_types[0] orelse return false;
    return P == T or P == *T or P == *const T;
}

pub fn methodNames(comptime T: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"struct".decl_names) |name| {
            if (isMethod(T, name)) names = names ++ .{name};
        }
        return names;
    }
}

fn isCallParam(comptime P: type) bool {
    if (@typeInfo(P) != .pointer) return false;
    const C = @typeInfo(P).pointer.child;
    return switch (@typeInfo(C)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(C, "nanoui_call_context"),
        else => false,
    };
}

fn paramName(comptime T: type, comptime method: []const u8, comptime i: usize) []const u8 {
    if (@hasDecl(T, "nanoui_params") and @hasField(@TypeOf(T.nanoui_params), method)) {
        const names = @field(T.nanoui_params, method);
        if (i < names.len) return names[i];
    }
    return std.fmt.comptimePrint("arg{d}", .{i});
}

/// The TypeScript type of `T`, appending the declarations it needs to `decls`.
pub fn tsType(comptime T: type, comptime decls: *[]const Decl) []const u8 {
    comptime {
        if (T == std.json.Value) return "unknown";
        switch (@typeInfo(T)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "nanoui_ts_type")) return T.nanoui_ts_type,
            else => {},
        }
        switch (@typeInfo(T)) {
            .void, .null => return "void",
            .bool => return "boolean",
            .int, .float, .comptime_int, .comptime_float => return "number",
            .optional => |o| return tsType(o.child, decls) ++ " | null",
            .error_union => |e| return tsType(e.payload, decls),
            .array => |a| return if (a.child == u8) "string" else arrayOf(tsType(a.child, decls)),
            .pointer => |p| switch (p.size) {
                .slice => return if (p.child == u8) "string" else arrayOf(tsType(p.child, decls)),
                .one => return tsType(p.child, decls),
                else => @compileError("nanoui: unsupported pointer type " ++ @typeName(T)),
            },
            .@"enum" => |e| {
                const name = shortName(T);
                if (!hasDecl(decls.*, name)) {
                    var src: []const u8 = "export type " ++ name ++ " =";
                    for (e.field_names, 0..) |f, i| src = src ++ (if (i == 0) " " else " | ") ++ "\"" ++ f ++ "\"";
                    decls.* = decls.* ++ .{Decl{ .name = name, .source = src ++ ";" }};
                }
                return name;
            },
            .@"union" => |u| {
                if (u.tag_type == null) @compileError("nanoui: untagged unions are not supported: " ++ @typeName(T));
                const name = shortName(T);
                if (!hasDecl(decls.*, name)) {
                    const index = decls.len;
                    decls.* = decls.* ++ .{Decl{ .name = name, .source = "" }};
                    var src: []const u8 = "export type " ++ name ++ " =";
                    if (u.field_names.len == 0) {
                        src = src ++ " never";
                    } else for (u.field_names, u.field_types, 0..) |f, FT, i| {
                        const rhs = if (FT == void) "Record<string, never>" else tsType(FT, decls);
                        src = src ++ (if (i == 0) " " else " | ") ++ "{ " ++ f ++ ": " ++ rhs ++ " }";
                    }
                    var copy = decls.*[0..decls.len].*;
                    copy[index].source = src ++ ";";
                    decls.* = &copy;
                }
                return name;
            },
            .@"struct" => |s| {
                if (s.is_tuple) @compileError("nanoui: tuples are not supported: " ++ @typeName(T));
                const name = shortName(T);
                if (!hasDecl(decls.*, name)) {
                    // Reserve the name first so recursive types terminate.
                    const index = decls.len;
                    decls.* = decls.* ++ .{Decl{ .name = name, .source = "" }};
                    var src: []const u8 = "export interface " ++ name ++ " {\n";
                    for (s.field_names, s.field_types) |f, FT| {
                        const optional = @typeInfo(FT) == .optional;
                        src = src ++ "  " ++ f ++ (if (optional) "?" else "") ++ ": " ++ tsType(FT, decls) ++ ";\n";
                    }
                    var copy = decls.*[0..decls.len].*;
                    copy[index].source = src ++ "}";
                    decls.* = &copy;
                }
                return name;
            },
            else => @compileError("nanoui: unsupported type " ++ @typeName(T)),
        }
    }
}

fn arrayOf(comptime t: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, t, ' ') != null) "(" ++ t ++ ")[]" else t ++ "[]";
}

fn syncOrPromise(comptime ret: []const u8) []const u8 {
    const lhs = if (std.mem.indexOfScalar(u8, ret, ' ') != null) "(" ++ ret ++ ")" else ret;
    return lhs ++ " | Promise<" ++ ret ++ ">";
}

fn ifaceBlock(comptime name: []const u8, comptime body: []const u8) []const u8 {
    return if (body.len == 0)
        "export interface " ++ name ++ " {}\n"
    else
        "export interface " ++ name ++ " {\n" ++ body ++ "}\n";
}

fn hasDecl(decls: []const Decl, name: []const u8) bool {
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return true;
    return false;
}

fn appendUniqueDecls(comptime dst: *[]const Decl, comptime src: []const Decl) void {
    for (src) |d| if (!hasDecl(dst.*, d.name)) {
        dst.* = dst.* ++ .{d};
    };
}

pub const Service = struct {
    /// `export declare const Name: {...};`
    dts: []const u8,
    /// `export const Name = ...;`
    js: []const u8,
    decls: []const Decl,
};

pub fn serviceMethodsDts(comptime T: type, comptime decls: *[]const Decl, comptime indent: []const u8) []const u8 {
    comptime {
        var dts: []const u8 = "";
        for (methodNames(T)) |m| {
            const f = @typeInfo(@TypeOf(@field(T, m))).@"fn";
            var params: []const u8 = "";
            var n = 0;
            for (f.param_types[1..]) |P| {
                if (isCallParam(P.?)) continue;
                params = params ++ (if (n > 0) ", " else "") ++ paramName(T, m, n) ++ ": " ++ tsType(P.?, decls);
                n += 1;
            }
            dts = dts ++ indent ++ m ++ "(" ++ params ++ "): Promise<" ++ tsType(f.return_type.?, decls) ++ ">;\n";
        }
        return dts;
    }
}

pub fn service(comptime T: type) Service {
    comptime {
        @setEvalBranchQuota(100_000);
        var decls: []const Decl = &.{};
        const name = shortName(T);
        const dts = "export declare const " ++ name ++ ": {\n" ++ serviceMethodsDts(T, &decls, "  ") ++ "};\n";
        var js: []const u8 = "export const " ++ name ++ " = Object.freeze({\n";
        for (methodNames(T)) |m| {
            js = js ++ "  " ++ m ++ ": (...a) => window.nanoui.call(\"" ++ name ++ "." ++ m ++ "\", ...a),\n";
        }
        const d = decls[0..decls.len].*;
        return .{ .dts = dts, .js = js ++ "});\n", .decls = &d };
    }
}

/// Generates a TypeScript interface for host methods implemented in JS/TS and
/// callable from Zig (`T | Promise<T>`).
pub fn hostInterface(comptime T: type) Service {
    comptime {
        @setEvalBranchQuota(100_000);
        if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) {
            @compileError("nanoui: host interface must be a struct: " ++ @typeName(T));
        }
        const s = @typeInfo(T).@"struct";
        var decls: []const Decl = &.{};
        var body: []const u8 = "";
        for (s.field_names, s.field_types) |m, FT| {
            const f = switch (@typeInfo(FT)) {
                .@"fn" => |fn_info| fn_info,
                .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .@"fn")
                    @typeInfo(p.child).@"fn"
                else
                    @compileError("nanoui: host interface field '" ++ m ++ "' in " ++ @typeName(T) ++ " must be fn or *const fn"),
                else => @compileError("nanoui: host interface field '" ++ m ++ "' in " ++ @typeName(T) ++ " must be fn or *const fn"),
            };
            if (f.is_generic) @compileError("nanoui: generic functions are not supported in host interface: " ++ @typeName(T) ++ "." ++ m);
            var params: []const u8 = "";
            for (f.param_types, 0..) |P, i| {
                params = params ++ (if (i > 0) ", " else "") ++ paramName(T, m, i) ++ ": " ++ tsType(P.?, &decls);
            }
            const R = f.return_type.?;
            const Payload = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
            body = body ++ "  " ++ m ++ "(" ++ params ++ "): " ++ syncOrPromise(tsType(Payload, &decls)) ++ ";\n";
        }
        const d = decls[0..decls.len].*;
        return .{ .dts = ifaceBlock(shortName(T), body), .js = "", .decls = &d };
    }
}

pub const WebEvent = struct {
    name: []const u8,
    method_name: []const u8,
    payload_dts: []const u8,
    decls: []const Decl,
};

pub fn webEvent(comptime event_name: []const u8, comptime T: type) WebEvent {
    comptime {
        @setEvalBranchQuota(100_000);
        var decls: []const Decl = &.{};
        const ty = tsType(T, &decls);
        const d = decls[0..decls.len].*;
        return .{ .name = event_name, .method_name = "on" ++ pascal(event_name), .payload_dts = ty, .decls = &d };
    }
}

pub const WebSchemaSpec = struct {
    services: []const type = &.{},
    hosts: []const type = &.{},
    events: []const WebEvent = &.{},
};

/// Bundles deduplicated declarations, host interfaces, `RpcServices`, `RpcHost`,
/// `RpcEvents`, and web runtime type aliases into a single `.d.ts` file at comptime.
pub fn webBundleDts(comptime spec: WebSchemaSpec) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        var decls: []const Decl = &.{};

        var services_body: []const u8 = "";
        for (spec.services) |S| {
            const methods = serviceMethodsDts(S, &decls, "    ");
            services_body = services_body ++ "  " ++ shortName(S) ++ (if (methods.len == 0) ": {};\n" else ": {\n" ++ methods ++ "  };\n");
        }

        var host_ifaces_dts: []const u8 = "";
        var hosts_body: []const u8 = "";
        for (spec.hosts) |H| {
            const hi = hostInterface(H);
            appendUniqueDecls(&decls, hi.decls);
            host_ifaces_dts = host_ifaces_dts ++ "\n" ++ hi.dts;
            const hname = shortName(H);
            hosts_body = hosts_body ++ "  " ++ hname ++ ": " ++ hname ++ ";\n";
        }

        var events_body: []const u8 = "";
        for (spec.events) |ev| {
            appendUniqueDecls(&decls, ev.decls);
            events_body = events_body ++ "  " ++ ev.method_name ++ "(listener: (payload: " ++ ev.payload_dts ++ ") => void): () => void;\n";
        }

        var out: []const u8 =
            "// Generated by nanoui. Do not edit.\n" ++
            "import type { WebRuntime, StartOptions, LoadOptions } from \"./nanoui.js\";\n";
        for (decls) |d| out = out ++ "\n" ++ d.source ++ "\n";
        out = out ++ host_ifaces_dts;
        out = out ++ "\n" ++ ifaceBlock("RpcServices", services_body);
        out = out ++ "\n" ++ ifaceBlock("RpcHost", hosts_body);
        out = out ++ "\n" ++ ifaceBlock("RpcEvents", events_body);
        return out ++
            "\nexport type AppRuntime = WebRuntime<RpcServices, RpcHost, RpcEvents>;\n" ++
            "export type AppStartOptions = StartOptions<RpcHost>;\n" ++
            "export type AppLoadOptions = LoadOptions<RpcHost>;\n";
    }
}

pub fn event(comptime name: []const u8, comptime T: type) Service {
    comptime {
        const ev = webEvent(name, T);
        return .{
            .dts = "export declare function " ++ ev.method_name ++ "(listener: (payload: " ++ ev.payload_dts ++ ") => void): () => void;\n",
            .js = "export const " ++ ev.method_name ++ " = (fn) => window.nanoui.on(\"" ++ name ++ "\", fn);\n",
            .decls = ev.decls,
        };
    }
}

fn pascal(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (s) |c| {
            if (c == '-' or c == '_' or c == ':' or c == '.') {
                upper = true;
                continue;
            }
            out = out ++ .{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return out;
    }
}

pub const runtime_dts =
    \\// Generated by nanoui. Do not edit.
    \\export declare const nanoui: {
    \\  call(method: string, ...args: unknown[]): Promise<unknown>;
    \\  on(event: string, listener: (payload: unknown) => void): () => void;
    \\  once(event: string, listener: (payload: unknown) => void): () => void;
    \\  log(...values: unknown[]): void;
    \\  window: { close(): void; minimize(): void; toggleMaximize(): void; setTitle(title: string): void };
    \\  platform: "macos" | "windows" | "linux";
    \\  version: string;
    \\};
    \\
;

pub const runtime_js =
    \\// Generated by nanoui. Do not edit.
    \\export const nanoui = window.nanoui;
    \\
;

test "types" {
    const Todo = struct { id: u32, title: []const u8, done: bool, note: ?[]const u8 };
    comptime var decls: []const Decl = &.{};
    try std.testing.expectEqualStrings("Todo[]", comptime tsType([]const Todo, &decls));
    try std.testing.expectEqualStrings("(string | null)[]", comptime tsType([]const ?[]const u8, &decls));
    try std.testing.expectEqualStrings(
        "export interface Todo {\n  id: number;\n  title: string;\n  done: boolean;\n  note?: string | null;\n}",
        decls[0].source,
    );
}

test "desktop service and event unchanged" {
    const Call = struct {
        pub const nanoui_call_context = {};
    };
    const Greeter = struct {
        pub const nanoui_params = .{ .greet = .{"name"} };
        pub fn greet(_: *@This(), _: *Call, name: []const u8) ![]const u8 {
            return name;
        }
    };
    const TickPayload = struct { uptime: u64, todos: usize };
    const svc = comptime service(Greeter);
    try std.testing.expectEqualStrings("export declare const Greeter: {\n  greet(name: string): Promise<string>;\n};\n", svc.dts);
    try std.testing.expectEqualStrings("export const Greeter = Object.freeze({\n  greet: (...a) => window.nanoui.call(\"Greeter.greet\", ...a),\n});\n", svc.js);
    const ev = comptime event("tick", TickPayload);
    try std.testing.expectEqualStrings("export declare function onTick(listener: (payload: TickPayload) => void): () => void;\n", ev.dts);
    try std.testing.expectEqualStrings("export const onTick = (fn) => window.nanoui.on(\"tick\", fn);\n", ev.js);
}

test "nanoui_ts_type escape hatch" {
    const Handle = enum(u32) {
        invalid = 0,
        _,
        pub const nanoui_ts_type = "unknown";
    };
    const Bytes = struct {
        pub const nanoui_ts_type = "Uint8Array";
        slice: []const u8,
    };
    const OpaqueRef = opaque {
        pub const nanoui_ts_type = "unknown";
    };

    comptime var decls: []const Decl = &.{};
    try std.testing.expectEqualStrings("unknown", comptime tsType(Handle, &decls));
    try std.testing.expectEqualStrings("Uint8Array", comptime tsType(Bytes, &decls));
    try std.testing.expectEqualStrings("Uint8Array | null", comptime tsType(?Bytes, &decls));
    try std.testing.expectEqualStrings("Uint8Array[]", comptime tsType([]const Bytes, &decls));
    try std.testing.expectEqualStrings("(Uint8Array | null)[]", comptime tsType([]const ?Bytes, &decls));
    try std.testing.expectEqualStrings("unknown", comptime tsType(*OpaqueRef, &decls));
    try std.testing.expectEqual(@as(usize, 0), decls.len);
}

test "tagged union matches std.json" {
    const Summary = struct { ok: bool, count: u32 };
    const JobState = union(enum) { idle: void, running: u32, finished: Summary };
    const Node = union(enum) { leaf: i32, branch: []const @This() };

    comptime var decls: []const Decl = &.{};
    try std.testing.expectEqualStrings("JobState", comptime tsType(JobState, &decls));
    try std.testing.expectEqualStrings("Node", comptime tsType(Node, &decls));
    try std.testing.expectEqual(@as(usize, 3), decls.len);
    try std.testing.expectEqualStrings("export type JobState = { idle: Record<string, never> } | { running: number } | { finished: Summary };", decls[0].source);
    try std.testing.expectEqualStrings("export interface Summary {\n  ok: boolean;\n  count: number;\n}", decls[1].source);
    try std.testing.expectEqualStrings("export type Node = { leaf: number } | { branch: Node[] };", decls[2].source);

    const cases = [_]struct { val: JobState, json: []const u8 }{
        .{ .val = .idle, .json = "{\"idle\":{}}" },
        .{ .val = .{ .running = 42 }, .json = "{\"running\":42}" },
        .{ .val = .{ .finished = .{ .ok = true, .count = 7 } }, .json = "{\"finished\":{\"ok\":true,\"count\":7}}" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(c.val, .{}, &aw.writer);
        try std.testing.expectEqualStrings(c.json, aw.written());

        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const parsed = try std.json.parseFromSliceLeaky(JobState, arena.allocator(), aw.written(), .{});
        try std.testing.expectEqual(c.val, parsed);
    }
}

test "hostInterface" {
    const User = struct { id: u32, name: []const u8 };
    const HostApi = struct {
        pub const nanoui_params = .{ .getItem = .{"key"}, .loadUser = .{"id"} };
        getItem: fn ([]const u8) ?[]const u8,
        loadUser: *const fn (u32) anyerror!User,
        clear: *const fn ([]const u8) void,
    };

    const hi = comptime hostInterface(HostApi);
    try std.testing.expectEqualStrings("", hi.js);
    try std.testing.expectEqual(@as(usize, 1), hi.decls.len);
    try std.testing.expectEqualStrings("export interface User {\n  id: number;\n  name: string;\n}", hi.decls[0].source);
    try std.testing.expectEqualStrings(
        \\export interface HostApi {
        \\  getItem(key: string): (string | null) | Promise<string | null>;
        \\  loadUser(id: number): User | Promise<User>;
        \\  clear(arg0: string): void | Promise<void>;
        \\}
        \\
    , hi.dts);
}

test "webBundleDts deduplicates decls across services, hosts, and events" {
    const User = struct { id: u32, name: []const u8 };
    const Bytes = struct {
        pub const nanoui_ts_type = "Uint8Array";
        data: []const u8,
    };
    const CallCtx = struct {
        pub const nanoui_call_context = {};
    };
    const Users = struct {
        pub const nanoui_params = .{ .save = .{ "user", "avatar" } };
        pub fn current(_: *const @This(), _: *CallCtx) !User {
            return .{ .id = 1, .name = "Ada" };
        }
        pub fn save(_: *@This(), user: User, avatar: Bytes) void {
            _ = .{ user, avatar };
        }
    };
    const Storage = struct {
        pub const nanoui_params = .{ .cacheUser = .{"user"} };
        cacheUser: *const fn (User) void,
    };

    const dts = comptime webBundleDts(.{
        .services = &.{Users},
        .hosts = &.{Storage},
        .events = &.{webEvent("user-updated", User)},
    });
    try std.testing.expectEqualStrings(
        \\// Generated by nanoui. Do not edit.
        \\import type { WebRuntime, StartOptions, LoadOptions } from "./nanoui.js";
        \\
        \\export interface User {
        \\  id: number;
        \\  name: string;
        \\}
        \\
        \\export interface Storage {
        \\  cacheUser(user: User): void | Promise<void>;
        \\}
        \\
        \\export interface RpcServices {
        \\  Users: {
        \\    current(): Promise<User>;
        \\    save(user: User, avatar: Uint8Array): Promise<void>;
        \\  };
        \\}
        \\
        \\export interface RpcHost {
        \\  Storage: Storage;
        \\}
        \\
        \\export interface RpcEvents {
        \\  onUserUpdated(listener: (payload: User) => void): () => void;
        \\}
        \\
        \\export type AppRuntime = WebRuntime<RpcServices, RpcHost, RpcEvents>;
        \\export type AppStartOptions = StartOptions<RpcHost>;
        \\export type AppLoadOptions = LoadOptions<RpcHost>;
        \\
    , dts);
    try std.testing.expectEqualStrings(
        \\// Generated by nanoui. Do not edit.
        \\import type { WebRuntime, StartOptions, LoadOptions } from "./nanoui.js";
        \\
        \\export interface RpcServices {}
        \\
        \\export interface RpcHost {}
        \\
        \\export interface RpcEvents {}
        \\
        \\export type AppRuntime = WebRuntime<RpcServices, RpcHost, RpcEvents>;
        \\export type AppStartOptions = StartOptions<RpcHost>;
        \\export type AppLoadOptions = LoadOptions<RpcHost>;
        \\
    , comptime webBundleDts(.{}));
}
