//! Unit tests for `src/web/rpc.zig` and `src/web/rpc_marshal.zig` (host + Wasmtime).
const std = @import("std");
const js = @import("js.zig");
const rpc = @import("rpc.zig");

var wake_count: u32 = 0;
fn bumpWake() void {
    wake_count += 1;
}
fn resetAll() void {
    rpc.reset();
    js.mock.reset();
    js.wake_hook = null;
}
fn assertClean() !void {
    rpc.reset();
    try std.testing.expectEqual(@as(u32, 0), js.liveCount());
}

fn callJson(method: []const u8, json_args: []const u8) !rpc.DispatchResult {
    const args = try js.parseJson(json_args);
    defer args.release();
    return rpc.dispatch(method, args);
}

fn expectDispatchErr(gpa: std.mem.Allocator, method: []const u8, args_h: js.Handle, expected: []const u8) !void {
    const res = rpc.dispatch(method, args_h);
    try std.testing.expect(!res.ok);
    const msg = try js.readString(res.handle, gpa);
    defer gpa.free(msg);
    res.handle.release();
    try std.testing.expectEqualStrings(expected, msg);
}

test "bound Zig services: value, *Svc, *const Svc receivers, Call arena, void, and !T errors" {
    defer resetAll();
    const gpa = std.testing.allocator;
    wake_count = 0;
    js.wake_hook = bumpWake;

    const ValSvc = struct {
        bias: i32,
        pub fn add(self: @This(), a: i32, b: i32) i32 {
            return self.bias + a + b;
        }
    };
    const ConstSvc = struct {
        prefix: []const u8,
        pub fn label(self: *const @This(), call: *rpc.Call, name: []const u8) ![]const u8 {
            const tmp = try call.arena.alloc(u32, 16);
            @memset(tmp, 9);
            return std.fmt.allocPrint(call.arena, "{s}:{s}:{d}", .{ self.prefix, name, tmp[0] });
        }
    };
    const MutSvc = struct {
        total: i32 = 0,
        pub fn bump(self: *@This(), delta: i32) void {
            self.total += delta;
        }
        pub fn checked(self: *@This(), limit: i32) !i32 {
            return if (self.total > limit) error.LimitExceeded else self.total;
        }
    };

    var val_svc: ValSvc = .{ .bias = 10 };
    const const_svc: ConstSvc = .{ .prefix = "user" };
    var mut_svc: MutSvc = .{};
    try rpc.bind(&val_svc);
    try rpc.bind(&const_svc);
    try rpc.bind(&mut_svc);

    const r1 = try callJson("ValSvc.add", "[3,4]");
    try std.testing.expect(r1.ok and (try js.asInt(i32, r1.handle)) == 17);
    r1.handle.release();

    const r2 = try callJson("ConstSvc.label", "[\"Ada\"]");
    try std.testing.expect(r2.ok);
    const lbl = try js.readString(r2.handle, gpa);
    defer gpa.free(lbl);
    r2.handle.release();
    try std.testing.expectEqualStrings("user:Ada:9", lbl);

    const r3 = try callJson("MutSvc.bump", "[12]");
    try std.testing.expect(r3.ok and r3.handle == .undef and mut_svc.total == 12 and wake_count == 3);

    const a4 = try js.parseJson("[5]");
    try expectDispatchErr(gpa, "MutSvc.checked", a4, "MutSvc.checked: LimitExceeded");
    a4.release();
    try std.testing.expectEqual(@as(u32, 3), wake_count);
    try assertClean();
}

test "structured JSON types: nested structs, optionals, enums, tagged unions, and slices" {
    defer resetAll();
    const gpa = std.testing.allocator;
    const Role = enum { viewer, editor, owner };
    const Meta = struct { tags: []const []const u8, note: ?[]const u8 };
    const Step = union(enum) { idle: void, wait_ms: u32, annotate: Meta };
    const Doc = struct { id: u32, role: Role, meta: ?Meta, steps: []const Step };
    const DocSvc = struct {
        pub fn transform(_: *const @This(), call: *rpc.Call, doc: Doc, extra_wait: ?u32) !Doc {
            const steps = try call.arena.alloc(Step, doc.steps.len + 1);
            @memcpy(steps[0..doc.steps.len], doc.steps);
            steps[doc.steps.len] = if (extra_wait) |w| .{ .wait_ms = w } else .idle;
            return .{ .id = doc.id + 1, .role = if (doc.role == .viewer) .editor else doc.role, .meta = doc.meta, .steps = steps };
        }
    };

    const svc: DocSvc = .{};
    try rpc.bind(&svc);
    const in_doc: Doc = .{
        .id = 10,
        .role = .viewer,
        .meta = .{ .tags = &.{ "alpha", "beta" }, .note = null },
        .steps = &.{ .idle, .{ .wait_ms = 50 }, .{ .annotate = .{ .tags = &.{"v1"}, .note = "ok" } } },
    };
    const args = try js.array();
    const doc_h = try rpc.encodeToHandle(Doc, gpa, in_doc);
    try js.setIndex(args, 0, .{ .handle = doc_h });
    try js.setIndex(args, 1, .null);
    doc_h.release();
    const res = rpc.dispatch("DocSvc.transform", args);
    args.release();
    try std.testing.expect(res.ok);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const out = try rpc.decodeFromHandle(Doc, arena.allocator(), res.handle);
    res.handle.release();
    try std.testing.expect(out.id == 11 and out.role == .editor and out.meta.?.note == null);
    try std.testing.expectEqualStrings("beta", out.meta.?.tags[1]);
    try std.testing.expect(out.steps.len == 4 and out.steps[0] == .idle and out.steps[3] == .idle);
    try std.testing.expectEqual(@as(u32, 50), out.steps[1].wait_ms);
    try std.testing.expectEqualStrings("ok", out.steps[2].annotate.note.?);
    try assertClean();
}

test "hybrid Layer 1 types: top-level rpc.Bytes and js.Handle passthrough without leaks" {
    defer resetAll();
    const gpa = std.testing.allocator;
    const HybridSvc = struct {
        pub fn xorBytes(_: *const @This(), call: *rpc.Call, raw: rpc.Bytes, mask: u8) !rpc.Bytes {
            const out = try call.arena.alloc(u8, raw.data.len);
            for (raw.data, 0..) |b, i| out[i] = b ^ mask;
            return .init(out);
        }
        pub fn readProp(_: *const @This(), h: js.Handle) !i32 {
            const v = try js.get(h, "secret");
            defer v.release();
            return js.asInt(i32, v);
        }
        pub fn echoHandle(_: *const @This(), h: js.Handle) js.Handle {
            return h;
        }
        pub fn makeHandle(_: *const @This()) !js.Handle {
            const o = try js.object();
            try js.set(o, "fresh", .from(true));
            return o;
        }
    };
    const svc: HybridSvc = .{};
    try rpc.bind(&svc);

    const args_b = try js.array();
    const in_bh = try js.bytes(&.{ 0x00, 0xAA, 0xFF });
    try js.setIndex(args_b, 0, .{ .handle = in_bh });
    try js.setIndex(args_b, 1, .from(@as(u8, 0xFF)));
    in_bh.release();
    const rb = rpc.dispatch("HybridSvc.xorBytes", args_b);
    args_b.release();
    try std.testing.expect(rb.ok and (try js.isBytes(rb.handle)));
    const xored = try js.readBytes(rb.handle, gpa);
    defer gpa.free(xored);
    rb.handle.release();
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x55, 0x00 }, xored);

    const caller_obj = try js.object();
    try js.set(caller_obj, "secret", .from(321));
    const args_h = try js.array();
    try js.setIndex(args_h, 0, .{ .handle = caller_obj });
    const r_read = rpc.dispatch("HybridSvc.readProp", args_h);
    try std.testing.expect(r_read.ok and (try js.asInt(i32, r_read.handle)) == 321);
    r_read.handle.release();

    const r_echo = rpc.dispatch("HybridSvc.echoHandle", args_h);
    try std.testing.expect(r_echo.ok);
    const echo_v = try js.get(r_echo.handle, "secret");
    try std.testing.expectEqual(@as(i32, 321), try js.asInt(i32, echo_v));
    echo_v.release();
    r_echo.handle.release();
    args_h.release();

    const still_v = try js.get(caller_obj, "secret");
    try std.testing.expectEqual(@as(i32, 321), try js.asInt(i32, still_v));
    still_v.release();
    caller_obj.release();

    const r_make = try callJson("HybridSvc.makeHandle", "[]");
    try std.testing.expect(r_make.ok);
    const fresh_v = try js.get(r_make.handle, "fresh");
    try std.testing.expectEqual(true, try js.asBool(fresh_v));
    fresh_v.release();
    r_make.handle.release();
    try assertClean();
}

test "dispatch error cases: unknown service/method, bad format, arity, and type mismatch" {
    defer resetAll();
    const gpa = std.testing.allocator;
    const Calc = struct {
        pub fn pair(_: *const @This(), a: i32, b: struct { ok: bool }) i32 {
            return if (b.ok) a else -a;
        }
    };
    const calc: Calc = .{};
    try rpc.bind(&calc);

    const empty = try js.array();
    for ([_][2][]const u8{
        .{ "Missing.foo", "Missing.foo: UnknownService" },
        .{ "Calc.nope", "Calc.nope: UnknownMethod" },
        .{ "NoDot", "NoDot: UnknownMethod" },
        .{ "Calc.pair", "Calc.pair: MissingArgument" },
    }) |c| try expectDispatchErr(gpa, c[0], empty, c[1]);
    empty.release();

    for ([_][2][]const u8{
        .{ "[1,{\"ok\":true},3]", "Calc.pair: TooManyArguments" },
        .{ "[\"not_int\",{\"ok\":true}]", "Calc.pair: InvalidArgument" },
    }) |c| {
        const bad = try js.parseJson(c[0]);
        try expectDispatchErr(gpa, "Calc.pair", bad, c[1]);
        bad.release();
    }

    const bytes_for_struct = try js.array();
    const bh = try js.bytes(&.{ 1, 2 });
    try js.setIndex(bytes_for_struct, 0, .from(5));
    try js.setIndex(bytes_for_struct, 1, .{ .handle = bh });
    bh.release();
    try expectDispatchErr(gpa, "Calc.pair", bytes_for_struct, "Calc.pair: InvalidArgument");
    bytes_for_struct.release();
    try assertClean();
}

test "HostClient callSync: primitives, struct, string, Bytes, void, NoHostBound, and AsyncHostResult" {
    defer resetAll();
    const gpa = std.testing.allocator;
    const Record = struct { id: u32, name: []const u8 };
    const HostApi = struct {
        mul: *const fn (i32, i32) i32,
        fetchRecord: *const fn (u32) Record,
        greet: *const fn ([]const u8) []const u8,
        mirrorBytes: *const fn (rpc.Bytes) rpc.Bytes,
        ping: *const fn () void,
        slowOp: *const fn () u32,
    };
    const MockHost = struct {
        pings: u32 = 0,
        pending: ?js.mock.MockPromise = null,
        pub fn mul(_: *@This(), a: i32, b: i32) i32 {
            return a * b;
        }
        pub fn fetchRecord(_: *@This(), id: u32) Record {
            return .{ .id = id, .name = "rec" };
        }
        pub fn greet(_: *@This(), call: *rpc.Call, who: []const u8) ![]const u8 {
            return std.fmt.allocPrint(call.arena, "hi {s}", .{who});
        }
        pub fn mirrorBytes(_: *@This(), call: *rpc.Call, b: rpc.Bytes) !rpc.Bytes {
            const out = try call.arena.alloc(u8, b.data.len);
            for (b.data, 0..) |v, i| out[b.data.len - 1 - i] = v;
            return .init(out);
        }
        pub fn ping(self: *@This()) void {
            self.pings += 1;
        }
        pub fn slowOp(self: *@This()) !js.Handle {
            self.pending = try js.mock.createPromise();
            return self.pending.?.handle.dup();
        }
    };

    const Client = rpc.HostClient(HostApi);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NoHostBound, Client.callSync(a, .mul, .{ 2, 3 }));

    var host_impl: MockHost = .{};
    try rpc.bindMockHost(HostApi, &host_impl);
    try std.testing.expectEqual(@as(i32, 42), try Client.callSync(a, .mul, .{ 6, 7 }));
    const rec = try Client.callSync(a, .fetchRecord, .{9});
    try std.testing.expect(rec.id == 9 and std.mem.eql(u8, rec.name, "rec"));
    try std.testing.expectEqualStrings("hi Zig", try Client.callSync(a, .greet, .{"Zig"}));
    const rev = try Client.callSync(a, .mirrorBytes, .{rpc.Bytes.init(&.{ 0x00, 0x11, 0xFF })});
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x11, 0x00 }, rev.data);
    try Client.callSync(a, .ping, .{});
    try std.testing.expectEqual(@as(u32, 1), host_impl.pings);
    try std.testing.expectError(error.AsyncHostResult, Client.callSync(a, .slowOp, .{}));
    host_impl.pending.?.release();
    try assertClean();
}

test "HostClient async call: sync return, async resolve, async reject, cancel, and wake_hook" {
    defer resetAll();
    const gpa = std.testing.allocator;
    wake_count = 0;
    js.wake_hook = bumpWake;

    const Bundle = struct { title: []const u8, nums: []const i32 };
    const AsyncHost = struct {
        syncEcho: *const fn ([]const u8) []const u8,
        loadBundle: *const fn (u32) Bundle,
        loadBytes: *const fn () rpc.Bytes,
    };
    const MockAsyncHost = struct {
        pending: ?js.mock.MockPromise = null,
        fn nextPromise(self: *@This()) !js.Handle {
            self.pending = try js.mock.createPromise();
            return self.pending.?.handle.dup();
        }
        pub fn syncEcho(_: *@This(), s: []const u8) ![]const u8 {
            return if (std.mem.eql(u8, s, "fail")) error.SyncBoom else s;
        }
        pub fn loadBundle(self: *@This(), _: u32) !js.Handle {
            return self.nextPromise();
        }
        pub fn loadBytes(self: *@This()) !js.Handle {
            return self.nextPromise();
        }
    };

    var mock_host: MockAsyncHost = .{};
    try rpc.bindMockHost(AsyncHost, &mock_host);
    const Client = rpc.HostClient(AsyncHost);
    const State = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,
        sum: i32 = 0,
        called: u32 = 0,
        fn save(self: *@This(), src: []const u8) void {
            self.len = src.len;
            @memcpy(self.buf[0..src.len], src);
        }
        fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
        fn onEcho(self: *@This(), out: rpc.Outcome([]const u8)) void {
            self.called += 1;
            self.save(if (out == .ok) out.ok else out.err);
        }
        fn onBundle(self: *@This(), out: rpc.Outcome(Bundle)) void {
            self.called += 1;
            if (out == .err) return self.save(out.err);
            self.save(out.ok.title);
            self.sum = 0;
            for (out.ok.nums) |n| self.sum += n;
        }
        fn onBytes(self: *@This(), out: rpc.Outcome(rpc.Bytes)) void {
            self.called += 1;
            if (out == .ok) self.save(out.ok.data);
        }
    };

    var st: State = .{};
    _ = try Client.call(.syncEcho, .{"instant"}, &st, State.onEcho);
    try std.testing.expect(std.mem.eql(u8, st.slice(), "instant") and wake_count == 1);
    _ = try Client.call(.syncEcho, .{"fail"}, &st, State.onEcho);
    try std.testing.expect(std.mem.eql(u8, st.slice(), "SyncBoom") and wake_count == 2);

    _ = try Client.call(.loadBundle, .{1}, &st, State.onBundle);
    try std.testing.expectEqual(@as(u32, 2), wake_count);
    const bh = try rpc.encodeToHandle(Bundle, gpa, .{ .title = "pack", .nums = &.{ 10, 20, 30 } });
    mock_host.pending.?.resolve(.{ .handle = bh });
    bh.release();
    mock_host.pending.?.release();
    try std.testing.expect(std.mem.eql(u8, st.slice(), "pack") and st.sum == 60 and wake_count == 3);

    _ = try Client.call(.loadBytes, .{}, &st, State.onBytes);
    mock_host.pending.?.resolve(.{ .bytes = &.{ 0x00, 0xFE } });
    mock_host.pending.?.release();
    try std.testing.expect(std.mem.eql(u8, st.slice(), &.{ 0x00, 0xFE }) and wake_count == 4);

    _ = try Client.call(.loadBundle, .{2}, &st, State.onBundle);
    mock_host.pending.?.reject("disk full");
    mock_host.pending.?.release();
    try std.testing.expect(std.mem.eql(u8, st.slice(), "disk full") and wake_count == 5);

    const calls_before = st.called;
    const cb_id = try Client.call(.loadBundle, .{3}, &st, State.onBundle);
    js.cancel(cb_id);
    const ignored = try rpc.encodeToHandle(Bundle, gpa, .{ .title = "never", .nums = &.{1} });
    mock_host.pending.?.resolve(.{ .handle = ignored });
    ignored.release();
    mock_host.pending.?.release();
    try std.testing.expect(st.called == calls_before and wake_count == 5);
    try assertClean();
}

test "Event emit (structured and void) via setEmitter and Schema.dts generation" {
    defer resetAll();
    const Kind = enum { info, warn };
    const Notice = struct { code: u32, kind: Kind, msg: []const u8 };
    const NoticeEv = rpc.Event("sys-notice", Notice);
    const ResetEv = rpc.Event("sys-reset", void);
    try NoticeEv.emit(.{ .code = 1, .kind = .info, .msg = "noop" });

    const Capture = struct {
        events: u32 = 0,
        last_code: u32 = 0,
        saw_void: bool = false,
        fn onEmit(raw_ctx: ?*anyopaque, _: js.Handle, args: []const js.Arg) js.mock.MockReturn {
            const cap: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            cap.events += 1;
            if (std.mem.eql(u8, args[0].string, "sys-notice")) {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const n = rpc.decodeFromHandle(Notice, arena.allocator(), args[1].handle) catch return .{ .throw = "decode" };
                cap.last_code = n.code;
            } else if (std.mem.eql(u8, args[0].string, "sys-reset")) cap.saw_void = (args[1].handle == .undef);
            return .{ .arg = .undef };
        }
    };
    var cap: Capture = .{};
    const emit_fn = try js.mock.func(&cap, Capture.onEmit);
    rpc.setEmitter(emit_fn);
    emit_fn.release();

    try NoticeEv.emit(.{ .code = 204, .kind = .warn, .msg = "ready" });
    try ResetEv.emit({});
    try std.testing.expect(cap.events == 2 and cap.last_code == 204 and cap.saw_void);

    const LogSvc = struct {
        pub fn send(_: *const @This(), _: *rpc.Call, n: Notice, blob: rpc.Bytes) void {
            _ = .{ n, blob };
        }
    };
    const LogHost = struct { archive: *const fn (Notice) bool };
    const BundleSchema = rpc.Schema(.{ .services = &.{LogSvc}, .hosts = &.{LogHost}, .events = &.{ NoticeEv.web_event, ResetEv.web_event } });
    for ([_][]const u8{
        "export interface Notice {",
        "export type Kind = \"info\" | \"warn\";",
        "export interface LogHost {",
        "send(arg0: Notice, arg1: Uint8Array): Promise<void>;",
        "onSysNotice(listener: (payload: Notice) => void): () => void;",
        "onSysReset(listener: (payload: void) => void): () => void;",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, BundleSchema.dts, needle) != null);
    try assertClean();
}

test "omitted optional struct fields without default value decode as null" {
    defer resetAll();
    const Draft = struct { id: u32, note: ?[]const u8, tag: ?u32 };
    const Action = union(enum) { save: Draft, clear: void };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const omitted_h = try js.parseJson("{\"save\":{\"id\":42}}");
    const act = try rpc.decodeFromHandle(Action, arena.allocator(), omitted_h);
    omitted_h.release();
    try std.testing.expectEqual(@as(u32, 42), act.save.id);
    try std.testing.expect(act.save.note == null and act.save.tag == null);

    const missing_req = try js.parseJson("{\"note\":\"hi\"}");
    try std.testing.expectError(error.InvalidArgument, rpc.decodeFromHandle(Draft, arena.allocator(), missing_req));
    missing_req.release();
    try assertClean();
}
