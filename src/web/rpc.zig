//! Typed bidirectional Zig <-> TypeScript RPC, events, and `.d.ts` schema bundle for web targets.
const std = @import("std");
const builtin = @import("builtin");
const js = @import("js.zig");
const tsgen = @import("../tsgen.zig");
const marshal = @import("rpc_marshal.zig");

const use_mock = builtin.is_test or builtin.os.tag != .wasi or @import("../backend.zig").is_embed;

pub const Bytes = marshal.Bytes;
pub const Call = marshal.Call;
pub const Error = marshal.Error;
pub const TempHandles = marshal.TempHandles;
pub const validateRpcType = marshal.validateRpcType;
pub const encodeToHandle = marshal.encodeToHandle;
pub const encodeToArg = marshal.encodeToArg;
pub const decodeFromHandle = marshal.decodeFromHandle;

pub fn Outcome(comptime R: type) type {
    return union(enum) { ok: R, err: []const u8 };
}

pub const DispatchResult = struct { ok: bool, handle: js.Handle };

const ServiceEntry = struct {
    ctx: *anyopaque,
    dispatch_fn: *const fn (ctx: *anyopaque, call: *Call, method: []const u8, args_arr: js.Handle) anyerror!js.Handle,
};

var services: std.StringHashMapUnmanaged(ServiceEntry) = .empty;
var scratch_buf: std.ArrayList(u8) = .empty;
var host_handle: js.Handle = .undef;
var emitter_handle: js.Handle = .undef;
pub var deinit_hook: ?*const fn () void = null;

fn rpcAllocator() std.mem.Allocator {
    return if (builtin.is_test) std.testing.allocator else if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
}

const WasmExports = struct {
    comptime {
        if (!use_mock) {
            @export(&nanoui_rpc_scratch, .{ .name = "nanoui_rpc_scratch" });
            @export(&nanoui_rpc_call, .{ .name = "nanoui_rpc_call" });
            @export(&nanoui_rpc_set_host, .{ .name = "nanoui_rpc_set_host" });
            @export(&nanoui_rpc_set_emitter, .{ .name = "nanoui_rpc_set_emitter" });
            @export(&nanoui_rpc_destroy, .{ .name = "nanoui_rpc_destroy" });
        }
    }
};

fn ensureExports() void {
    _ = WasmExports;
    deinit_hook = reset;
}

pub fn reset() void {
    const gpa = rpcAllocator();
    services.deinit(gpa);
    services = .empty;
    scratch_buf.deinit(gpa);
    scratch_buf = .empty;
    const prev_host = host_handle;
    host_handle = .undef;
    prev_host.release();
    const prev_emitter = emitter_handle;
    emitter_handle = .undef;
    prev_emitter.release();
    deinit_hook = null;
}

pub fn setHost(h: js.Handle) void {
    ensureExports();
    const next = h.dup();
    const prev = host_handle;
    host_handle = next;
    prev.release();
}

pub fn setEmitter(h: js.Handle) void {
    ensureExports();
    const next = h.dup();
    const prev = emitter_handle;
    emitter_handle = next;
    prev.release();
}

/// Binds a Zig service struct pointer (`*T` or `*const T`) so TypeScript can
/// invoke `runtime.rpc.<ShortName>.<method>(...)`.
pub fn bind(service_ptr: anytype) !void {
    const Ptr = @TypeOf(service_ptr);
    const ptr_info = @typeInfo(Ptr);
    if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
        @compileError("nanoui.web.rpc.bind expects a single-item struct pointer (*T), got " ++ @typeName(Ptr));
    }
    const T = ptr_info.pointer.child;
    comptime {
        marshal.validateService(T);
        if (Ptr != *T) {
            for (tsgen.methodNames(T)) |m| {
                const F = @typeInfo(@TypeOf(@field(T, m))).@"fn";
                if (F.param_types[0].? == *T) {
                    @compileError("nanoui.web.rpc.bind: *const " ++ @typeName(T) ++ " cannot bind mutable method '" ++ m ++ "'");
                }
            }
        }
    }
    ensureExports();
    const Impl = struct {
        fn callMethod(ctx: *anyopaque, call: *Call, method: []const u8, args_arr: js.Handle) anyerror!js.Handle {
            const self: *T = @ptrCast(@alignCast(ctx));
            inline for (comptime tsgen.methodNames(T)) |m| {
                if (std.mem.eql(u8, method, m)) return invokeServiceMethod(T, m, self, call, args_arr);
            }
            return error.UnknownMethod;
        }
    };
    try services.put(rpcAllocator(), tsgen.shortName(T), .{
        .ctx = @ptrCast(@constCast(service_ptr)),
        .dispatch_fn = Impl.callMethod,
    });
}

fn countJsArgs(comptime params: []const ?type) usize {
    comptime {
        var n: usize = 0;
        for (params) |P_opt| {
            if (!marshal.isCallParam(P_opt.?)) n += 1;
        }
        return n;
    }
}

fn invokeServiceMethod(comptime T: type, comptime m: []const u8, self: *T, call: *Call, args_arr: js.Handle) anyerror!js.Handle {
    const func = @field(T, m);
    const F = @typeInfo(@TypeOf(func)).@"fn";
    const expected = comptime countJsArgs(F.param_types[1..]);
    const actual = js.len(args_arr) catch return error.InvalidArgument;
    if (actual < expected) return error.MissingArgument;
    if (actual > expected) return error.TooManyArguments;

    var item_handles: [expected]js.Handle = @splat(.undef);
    var transferred_ret: js.Handle = .invalid;
    defer for (item_handles) |ih| {
        if (ih != transferred_ret) ih.release();
    };

    var tuple: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    tuple[0] = if (F.param_types[0].? == T) self.* else self;
    comptime var js_idx: usize = 0;
    inline for (F.param_types[1..], 1..) |P_opt, i| {
        const P = P_opt.?;
        if (comptime marshal.isCallParam(P)) {
            tuple[i] = call;
        } else {
            const item = try js.getIndex(args_arr, js_idx);
            item_handles[js_idx] = item;
            tuple[i] = try marshal.decodeFromHandle(P, call.arena, item);
            js_idx += 1;
        }
    }
    const raw_res = @call(.auto, func, tuple);
    const val = if (@typeInfo(@TypeOf(raw_res)) == .error_union) try raw_res else raw_res;
    const ret_h = try marshal.encodeToHandle(@TypeOf(val), call.arena, val);
    if (!ret_h.isReserved() and ret_h != .invalid) transferred_ret = ret_h;
    return ret_h;
}

pub fn dispatch(method: []const u8, args_arr: js.Handle) DispatchResult {
    const ret_h = dispatchInner(method, args_arr) catch |err| {
        var stack_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&stack_buf, "{s}: {s}", .{ method, @errorName(err) }) catch {
            const heap = std.fmt.allocPrint(rpcAllocator(), "{s}: {s}", .{ method, @errorName(err) }) catch return .{ .ok = false, .handle = .invalid };
            defer rpcAllocator().free(heap);
            return .{ .ok = false, .handle = js.string(heap) catch .invalid };
        };
        return .{ .ok = false, .handle = js.string(msg) catch .invalid };
    };
    if (js.wake_hook) |w| w();
    return .{ .ok = true, .handle = ret_h };
}

fn dispatchInner(method: []const u8, args_arr: js.Handle) anyerror!js.Handle {
    var arena: std.heap.ArenaAllocator = .init(rpcAllocator());
    defer arena.deinit();
    const a = arena.allocator();
    const owned_method = try a.dupe(u8, method);
    const dot = std.mem.indexOfScalar(u8, owned_method, '.') orelse return error.UnknownMethod;
    const svc = services.get(owned_method[0..dot]) orelse return error.UnknownService;
    var call: Call = .{ .arena = a };
    return svc.dispatch_fn(svc.ctx, &call, owned_method[dot + 1 ..], args_arr);
}

fn resolveHostTarget(short_name: []const u8) Error!js.Handle {
    if (try js.isNullOrUndefined(host_handle)) return error.NoHostBound;
    const sub = try js.get(host_handle, short_name);
    if (!(try js.isNullOrUndefined(sub))) return sub;
    sub.release();
    return host_handle.dup();
}

fn settleSyncThrow(raw_ctx: ?*anyopaque, cb: *const fn (?*anyopaque, js.Outcome) void) Error!js.CallbackId {
    const gpa = rpcAllocator();
    const err_bytes = try js.lastError(gpa);
    defer gpa.free(err_bytes);
    const msg = if (err_bytes.len > 0) err_bytes else "Error";
    if (use_mock) {
        const mp = try js.mock.createPromise();
        defer mp.release();
        mp.reject(msg);
        return js.then(mp.handle, raw_ctx, cb);
    }
    const promise_ctor = try js.get(js.global, "Promise");
    defer promise_ctor.release();
    const rej_h = try js.invoke(promise_ctor, "reject", &.{.{ .string = msg }});
    defer rej_h.release();
    return js.then(rej_h, raw_ctx, cb);
}

/// Typed Zig -> TypeScript client for a host interface `H`.
pub fn HostClient(comptime H: type) type {
    comptime marshal.validateHost(H);
    const iface_name = tsgen.shortName(H);
    return struct {
        pub const Method = std.meta.FieldEnum(H);

        pub fn FnType(comptime method: Method) type {
            const FT = @FieldType(H, @tagName(method));
            return if (@typeInfo(FT) == .@"fn") FT else @typeInfo(FT).pointer.child;
        }

        pub fn Args(comptime method: Method) type {
            return std.meta.ArgsTuple(FnType(method));
        }

        pub fn ReturnPayload(comptime method: Method) type {
            const R = @typeInfo(FnType(method)).@"fn".return_type.?;
            return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
        }

        pub fn call(
            comptime method: Method,
            args: Args(method),
            ctx: anytype,
            comptime onSettle: anytype,
        ) Error!js.CallbackId {
            ensureExports();
            const Fn = FnType(method);
            const f_info = @typeInfo(Fn).@"fn";
            const Payload = ReturnPayload(method);
            const CtxParam = @TypeOf(ctx);
            const raw_ctx: ?*anyopaque = switch (@typeInfo(CtxParam)) {
                .pointer => |p| blk: {
                    if (p.size != .one) @compileError("HostClient.call ctx must be a single-item pointer (*T), {}, or null");
                    break :blk if (@sizeOf(p.child) == 0) null else @ptrCast(@constCast(ctx));
                },
                .void, .null => null,
                else => @compileError("HostClient.call ctx must be a single-item pointer (*T), {}, or null"),
            };

            const Trampoline = struct {
                fn deliver(erased: ?*anyopaque, out: Outcome(Payload)) void {
                    const cb_fn = switch (@typeInfo(@TypeOf(onSettle))) {
                        .@"fn" => |fi| fi,
                        .pointer => |p| @typeInfo(p.child).@"fn",
                        else => @compileError("HostClient.call onSettle must be a function"),
                    };
                    if (cb_fn.param_types.len == 1) {
                        onSettle(out);
                    } else switch (@typeInfo(CtxParam)) {
                        .pointer => |p| if (@sizeOf(p.child) == 0) {
                            var zst: p.child = undefined;
                            onSettle(&zst, out);
                        } else {
                            onSettle(@ptrCast(@alignCast(erased.?)), out);
                        },
                        .void => onSettle({}, out),
                        .null => onSettle(null, out),
                        else => unreachable,
                    }
                }

                fn onJsSettle(erased: ?*anyopaque, js_out: js.Outcome) void {
                    switch (js_out) {
                        .rejected => |err_msg| deliver(erased, .{ .err = err_msg }),
                        .resolved => |val_h| {
                            var arena: std.heap.ArenaAllocator = .init(rpcAllocator());
                            defer arena.deinit();
                            const decoded = marshal.decodeFromHandle(Payload, arena.allocator(), val_h) catch {
                                deliver(erased, .{ .err = "Invalid host return value" });
                                return;
                            };
                            deliver(erased, .{ .ok = decoded });
                        },
                    }
                }
            };

            const iface = try resolveHostTarget(iface_name);
            defer iface.release();
            var call_arena: std.heap.ArenaAllocator = .init(rpcAllocator());
            defer call_arena.deinit();
            var temps: TempHandles = .{};
            defer temps.releaseAll();
            var js_args: [f_info.param_types.len]js.Arg = undefined;
            inline for (f_info.param_types, 0..) |P_opt, i| {
                js_args[i] = try marshal.encodeToArg(P_opt.?, call_arena.allocator(), args[i], &temps);
            }
            const res_h = js.invoke(iface, @tagName(method), js_args[0..f_info.param_types.len]) catch |err| switch (err) {
                error.JsException => return settleSyncThrow(raw_ctx, Trampoline.onJsSettle),
                else => return err,
            };
            defer res_h.release();
            return js.then(res_h, raw_ctx, Trampoline.onJsSettle);
        }

        pub fn callSync(arena: std.mem.Allocator, comptime method: Method, args: Args(method)) Error!ReturnPayload(method) {
            ensureExports();
            const Fn = FnType(method);
            const f_info = @typeInfo(Fn).@"fn";
            const Payload = ReturnPayload(method);
            const iface = try resolveHostTarget(iface_name);
            defer iface.release();
            var temps: TempHandles = .{};
            defer temps.releaseAll();
            var js_args: [f_info.param_types.len]js.Arg = undefined;
            inline for (f_info.param_types, 0..) |P_opt, i| {
                js_args[i] = try marshal.encodeToArg(P_opt.?, arena, args[i], &temps);
            }
            const res_h = try js.invoke(iface, @tagName(method), js_args[0..f_info.param_types.len]);
            defer res_h.release();
            if (try js.isPromise(res_h)) {
                js.ignorePromise(res_h);
                return error.AsyncHostResult;
            }
            if (Payload == js.Handle) return res_h.dup();
            if (Payload == ?js.Handle) return if (try js.isNullOrUndefined(res_h)) null else res_h.dup();
            return marshal.decodeFromHandle(Payload, arena, res_h);
        }
    };
}

/// Registers a pure-Zig mock implementation of host interface `H` under `js.mock`
/// so host and Wasmtime unit tests can exercise `HostClient(H)` end-to-end.
pub fn bindMockHost(comptime H: type, impl_ptr: anytype) !void {
    comptime marshal.validateHost(H);
    const Ptr = @TypeOf(impl_ptr);
    if (@typeInfo(Ptr) != .pointer or @typeInfo(Ptr).pointer.size != .one) {
        @compileError("nanoui.web.rpc.bindMockHost expects a single-item struct pointer (*Impl)");
    }
    const Impl = @typeInfo(Ptr).pointer.child;
    if (try js.isNullOrUndefined(host_handle)) {
        const root = try js.object();
        defer root.release();
        setHost(root);
    }
    const iface_obj = try js.object();
    defer iface_obj.release();

    const s = @typeInfo(H).@"struct";
    inline for (s.field_names, s.field_types) |m, FT| {
        if (!@hasDecl(Impl, m)) @compileError("bindMockHost: missing method '" ++ m ++ "' on " ++ @typeName(Impl));
        const h_fn = comptime marshal.hostFnInfo(H, m, FT);
        const Wrapper = struct {
            fn invoke(ctx: ?*anyopaque, _: js.Handle, raw_args: []const js.Arg) js.mock.MockReturn {
                if (raw_args.len != h_fn.param_types.len) return .{ .throw = "InvalidArgumentCount" };
                const self: *Impl = @ptrCast(@alignCast(ctx.?));
                const impl_fn = @field(Impl, m);
                const ImplF = @typeInfo(@TypeOf(impl_fn)).@"fn";
                var arena: std.heap.ArenaAllocator = .init(rpcAllocator());
                defer arena.deinit();
                var call_ctx: Call = .{ .arena = arena.allocator() };
                var arg_handles: [h_fn.param_types.len]js.Handle = @splat(.undef);
                var transferred: js.Handle = .invalid;
                defer for (arg_handles) |ah| {
                    if (ah != transferred) ah.release();
                };
                var tuple: std.meta.ArgsTuple(@TypeOf(impl_fn)) = undefined;
                tuple[0] = if (ImplF.param_types[0].? == Impl) self.* else self;
                comptime var raw_idx: usize = 0;
                inline for (ImplF.param_types[1..], 1..) |IP_opt, ti| {
                    const IP = IP_opt.?;
                    if (comptime marshal.isCallParam(IP)) {
                        tuple[ti] = &call_ctx;
                    } else {
                        const arg_h = js.mock.allocArg(raw_args[raw_idx]) catch |e| return .{ .throw = @errorName(e) };
                        arg_handles[raw_idx] = arg_h;
                        tuple[ti] = marshal.decodeFromHandle(h_fn.param_types[raw_idx].?, call_ctx.arena, arg_h) catch |e| return .{ .throw = @errorName(e) };
                        raw_idx += 1;
                    }
                }
                const res = @call(.auto, impl_fn, tuple);
                const val = if (@typeInfo(@TypeOf(res)) == .error_union) (res catch |e| return .{ .throw = @errorName(e) }) else res;
                if (@TypeOf(val) == js.Handle) {
                    if (!val.isReserved() and val != .invalid) transferred = val;
                    return .{ .handle = val };
                }
                const out_h = marshal.encodeToHandle(@TypeOf(val), call_ctx.arena, val) catch |e| return .{ .throw = @errorName(e) };
                return .{ .handle = out_h };
            }
        };
        const fn_h = try js.mock.func(@ptrCast(@constCast(impl_ptr)), Wrapper.invoke);
        defer fn_h.release();
        try js.set(iface_obj, m, .{ .handle = fn_h });
    }
    try js.set(host_handle, tsgen.shortName(H), .{ .handle = iface_obj });
}

/// Declares a typed Zig -> TypeScript event (`runtime.rpc.on<Pascal>(fn)` and `runtime.rpc.on(name, fn)`).
pub fn Event(comptime event_name: []const u8, comptime T: type) type {
    comptime marshal.validateRpcType(T, true, &.{});
    return struct {
        pub const name = event_name;
        pub const Payload = T;
        pub const web_event = tsgen.webEvent(event_name, T);

        pub fn emit(payload: T) Error!void {
            ensureExports();
            if (try js.isNullOrUndefined(emitter_handle)) return;
            var arena: std.heap.ArenaAllocator = .init(rpcAllocator());
            defer arena.deinit();
            const h = try marshal.encodeToHandle(T, arena.allocator(), payload);
            defer h.release();
            const ret = try js.call(emitter_handle, .undef, &.{ .from(event_name), .{ .handle = h } });
            ret.release();
        }
    };
}

/// Bundles bound Zig services, TS host interfaces, and events into a `.d.ts` schema.
pub fn Schema(comptime spec: tsgen.WebSchemaSpec) type {
    comptime {
        for (spec.services) |S| marshal.validateService(S);
        for (spec.hosts) |H| marshal.validateHost(H);
    }
    return struct {
        pub const specification = spec;
        pub const dts: []const u8 = tsgen.webBundleDts(spec);
    };
}

pub fn nanoui_rpc_scratch(method_len: usize) callconv(.c) usize {
    const needed = std.math.add(usize, 4, method_len) catch return 0;
    const gpa = rpcAllocator();
    scratch_buf.ensureTotalCapacity(gpa, needed) catch return 0;
    scratch_buf.items.len = needed;
    return @intFromPtr(scratch_buf.items.ptr);
}

pub fn nanoui_rpc_call(method_ptr: [*]const u8, method_len: usize, args_raw: u32, out_is_err: *u32) callconv(.c) u32 {
    const res = dispatch(method_ptr[0..method_len], @fromBackingInt(args_raw));
    out_is_err.* = if (res.ok) 0 else 1;
    return @backingInt(res.handle);
}

pub fn nanoui_rpc_set_host(raw: u32) callconv(.c) void {
    deinit_hook = reset;
    const prev = host_handle;
    host_handle = @fromBackingInt(raw);
    prev.release();
}

pub fn nanoui_rpc_set_emitter(raw: u32) callconv(.c) void {
    deinit_hook = reset;
    const prev = emitter_handle;
    emitter_handle = @fromBackingInt(raw);
    prev.release();
}

pub fn nanoui_rpc_destroy() callconv(.c) void {
    reset();
}
