//! Shared RPC schema, host contracts, events, and services for web E2E suites.
const std = @import("std");
const nanoui = @import("nanoui");
const js = nanoui.web.js;
const rpc = nanoui.web.rpc;

pub const MathOp = enum { add, sub, mul, div };

pub const MetricEntry = struct {
    label: []const u8,
    value: f64,
    note: ?[]const u8 = null,
};

pub const JobState = union(enum) {
    idle: void,
    running: u32,
    completed: MetricEntry,
    failed: []const u8,
};

pub const BatchRequest = struct {
    op: MathOp,
    base: i32,
    entries: []const MetricEntry,
    state: JobState,
    tag: ?[]const u8,
};

pub const BatchReport = struct {
    total: f64,
    count: u32,
    summary: []const u8,
    next: JobState,
};

pub const CounterEvent = struct {
    count: i32,
    source: []const u8,
};

pub const FetchReport = struct {
    done: bool,
    status: u32,
    byte_len: u32,
    has_webruntime: bool,
};

pub const AsyncSnapshot = struct {
    settled: u32,
    ok: bool,
    value: f64,
    label: []const u8,
    byte_sum: u32,
};

pub const CounterChanged = rpc.Event("counter-changed", CounterEvent);
pub const DemoUpdated = rpc.Event("demo-updated", CounterEvent);

pub const CheckHost = struct {
    syncFormat: *const fn ([]const u8, i32) []const u8,
    asyncCompute: *const fn (MetricEntry) MetricEntry,
    transformBytes: *const fn (rpc.Bytes) rpc.Bytes,
    inspectHandle: *const fn (js.Handle) []const u8,
};

pub const DemoHost = struct {
    delayedColor: *const fn (u32, u32) u32,
    readBanner: *const fn ([]const u8) ?[]const u8,
};

fn foldEntries(req: BatchRequest) !f64 {
    var total: f64 = @floatFromInt(req.base);
    for (req.entries) |entry| switch (req.op) {
        .add => total += entry.value,
        .sub => total -= entry.value,
        .mul => total *= entry.value,
        .div => {
            if (entry.value == 0) return error.DivisionByZero;
            total /= entry.value;
        },
    };
    return total;
}

fn nextJobState(arena: std.mem.Allocator, state: JobState, count: u32, total: f64) !JobState {
    return switch (state) {
        .idle => .{ .running = count },
        .running => |step| .{ .completed = .{
            .label = try std.fmt.allocPrint(arena, "step-{d}", .{step + 1}),
            .value = total,
            .note = "done",
        } },
        .completed => .{ .idle = {} },
        .failed => |reason| .{ .failed = try arena.dupe(u8, reason) },
    };
}

pub const MathService = struct {
    counter: i32 = 0,
    settled_count: u32 = 0,
    last_ok: bool = false,
    last_val: f64 = 0,
    last_byte_sum: u32 = 0,
    last_text_buf: [192]u8 = @splat(0),
    last_text_len: usize = 0,

    fn saveText(self: *MathService, text: []const u8) void {
        const n = @min(text.len, self.last_text_buf.len);
        @memcpy(self.last_text_buf[0..n], text[0..n]);
        self.last_text_len = n;
    }

    pub fn divide(_: *const @This(), a: f64, b: f64) !f64 {
        if (b == 0) return error.DivisionByZero;
        return a / b;
    }

    pub fn computeBatch(self: *@This(), call: *rpc.Call, req: BatchRequest) !BatchReport {
        const total = try foldEntries(req);
        const count: u32 = @intCast(req.entries.len);
        const tag = req.tag orelse "batch";
        self.counter += 1;
        try CounterChanged.emit(.{ .count = self.counter, .source = tag });
        return .{
            .total = total,
            .count = count,
            .summary = try std.fmt.allocPrint(call.arena, "{s}:{d}:{d:.2}", .{ tag, count, total }),
            .next = try nextJobState(call.arena, req.state, count, total),
        };
    }

    pub fn echoBytes(_: *const @This(), call: *rpc.Call, payload: rpc.Bytes, xor_mask: u8) !rpc.Bytes {
        const out = try call.arena.alloc(u8, payload.data.len);
        for (payload.data, 0..) |b, i| out[i] = b ^ xor_mask;
        return rpc.Bytes.init(out);
    }

    pub fn fnv1a32(_: *const @This(), payload: rpc.Bytes) u32 {
        return std.hash.Fnv1a_32.hash(payload.data);
    }

    pub fn passthroughHandle(_: *const @This(), handle: js.Handle, tag: []const u8) !js.Handle {
        try js.set(handle, "zigTag", .from(tag));
        return handle;
    }

    pub fn emitCounter(self: *@This(), delta: i32, source: []const u8) !i32 {
        self.counter += delta;
        try CounterChanged.emit(.{ .count = self.counter, .source = source });
        return self.counter;
    }

    pub fn callHostSync(_: *const @This(), call: *rpc.Call, prefix: []const u8, value: i32) ![]const u8 {
        return rpc.HostClient(CheckHost).callSync(call.arena, .syncFormat, .{ prefix, value });
    }

    pub fn callHostHandleSync(_: *const @This(), call: *rpc.Call, handle: js.Handle) ![]const u8 {
        return rpc.HostClient(CheckHost).callSync(call.arena, .inspectHandle, .{handle});
    }

    pub fn callHostAsyncInSync(_: *const @This(), call: *rpc.Call, entry: MetricEntry) !MetricEntry {
        return rpc.HostClient(CheckHost).callSync(call.arena, .asyncCompute, .{entry});
    }

    fn onComputeSettle(self: *MathService, outcome: rpc.Outcome(MetricEntry)) void {
        self.settled_count += 1;
        switch (outcome) {
            .ok => |entry| {
                self.last_ok = true;
                self.last_val = entry.value;
                self.saveText(entry.note orelse entry.label);
            },
            .err => |msg| {
                self.last_ok = false;
                self.last_val = -1;
                self.saveText(msg);
            },
        }
    }

    fn onBytesSettle(self: *MathService, outcome: rpc.Outcome(rpc.Bytes)) void {
        self.settled_count += 1;
        switch (outcome) {
            .ok => |bytes| {
                self.last_ok = true;
                var sum: u32 = 0;
                for (bytes.data) |b| sum +%= b;
                self.last_byte_sum = sum;
                self.saveText("bytes-ok");
            },
            .err => |msg| {
                self.last_ok = false;
                self.last_byte_sum = 0;
                self.saveText(msg);
            },
        }
    }

    pub fn startHostCompute(self: *@This(), entry: MetricEntry) !u32 {
        const id = try rpc.HostClient(CheckHost).call(.asyncCompute, .{entry}, self, onComputeSettle);
        return @backingInt(id);
    }

    pub fn startHostBytes(self: *@This(), payload: rpc.Bytes) !u32 {
        const id = try rpc.HostClient(CheckHost).call(.transformBytes, .{payload}, self, onBytesSettle);
        return @backingInt(id);
    }

    pub fn pollAsync(self: *const @This(), call: *rpc.Call) !AsyncSnapshot {
        return .{
            .settled = self.settled_count,
            .ok = self.last_ok,
            .value = self.last_val,
            .label = try call.arena.dupe(u8, self.last_text_buf[0..self.last_text_len]),
            .byte_sum = self.last_byte_sum,
        };
    }

    pub fn growAndEcho(_: *const @This(), call: *rpc.Call, megabytes: u32, label: []const u8, payload: rpc.Bytes) !rpc.Bytes {
        const byte_len: usize = @as(usize, megabytes) * 1024 * 1024;
        if (byte_len > 0) {
            const grown = try std.heap.wasm_allocator.alloc(u8, byte_len);
            defer std.heap.wasm_allocator.free(grown);
            var off: usize = 0;
            while (off < grown.len) : (off += 65536) grown[off] = 0xA5;
        }
        const out = try call.arena.alloc(u8, label.len + 1 + payload.data.len);
        @memcpy(out[0..label.len], label);
        out[label.len] = ':';
        @memcpy(out[label.len + 1 ..], payload.data);
        return rpc.Bytes.init(out);
    }
};

pub const DemoService = struct {
    counter: i32 = 0,
    clicks: i32 = 0,
    reentrant_observed: i32 = -1,
    color_hex: u24 = 0x2563EB,
    fetch_done: bool = false,
    fetch_status: u32 = 0,
    fetch_len: u32 = 0,
    fetch_has_webruntime: bool = false,
    last_click_buf: [64]u8 = @splat(0),
    last_click_len: usize = 0,

    pub fn compute(self: *@This(), call: *rpc.Call, req: BatchRequest) !BatchReport {
        const total = try foldEntries(req);
        const count: u32 = @intCast(req.entries.len);
        const tag = req.tag orelse "demo";
        self.counter += 1;
        self.color_hex = if (@mod(self.counter, 2) == 0) 0x2563EB else 0xD97706;
        try DemoUpdated.emit(.{ .count = self.counter, .source = tag });
        return .{
            .total = total,
            .count = count,
            .summary = try std.fmt.allocPrint(call.arena, "{s}:{d}:{d:.1}", .{ tag, count, total }),
            .next = try nextJobState(call.arena, req.state, count, total),
        };
    }

    pub fn echoBytes(self: *@This(), call: *rpc.Call, payload: rpc.Bytes, xor_mask: u8) !rpc.Bytes {
        self.counter += 1;
        const out = try call.arena.alloc(u8, payload.data.len);
        for (payload.data, 0..) |b, i| out[i] = b ^ xor_mask;
        return rpc.Bytes.init(out);
    }

    pub fn failIfZero(_: *const @This(), divisor: i32) !i32 {
        if (divisor == 0) return error.DivisionByZero;
        return @divTrunc(100, divisor);
    }

    pub fn storageRoundTrip(self: *@This(), call: *rpc.Call, key: []const u8, value: ?[]const u8) !?[]const u8 {
        const storage = try js.get(js.global, "localStorage");
        defer storage.release();
        if (value) |v| {
            const set_res = try js.invoke(storage, "setItem", &.{ .from(key), .from(v) });
            set_res.release();
        }
        const got = try js.invoke(storage, "getItem", &.{.from(key)});
        defer got.release();
        self.counter += 1;
        if (try js.isNullOrUndefined(got)) return null;
        return try js.readString(got, call.arena);
    }

    pub fn createDomButton(_: *const @This(), label: []const u8, variant: []const u8) !js.Handle {
        const doc = try js.get(js.global, "document");
        defer doc.release();
        const btn = try js.invoke(doc, "createElement", &.{.from("button")});
        errdefer btn.release();
        try js.set(btn, "textContent", .from(label));
        const attr_res = try js.invoke(btn, "setAttribute", &.{ .from("data-variant"), .from(variant) });
        attr_res.release();
        return btn;
    }

    pub fn inspectAndClickDom(self: *@This(), call: *rpc.Call, el: js.Handle) !?[]const u8 {
        const role_h = try js.invoke(el, "getAttribute", &.{.from("data-role")});
        defer role_h.release();
        const role: ?[]const u8 = if (try js.isNullOrUndefined(role_h)) null else try js.readString(role_h, call.arena);
        const before_clicks = self.clicks;
        const click_res = try js.invoke(el, "click", &.{});
        click_res.release();
        self.reentrant_observed = self.clicks - before_clicks;
        self.counter += 1;
        return role;
    }

    pub fn recordClick(self: *@This(), source: []const u8, weight: i32) !i32 {
        const n = @min(source.len, self.last_click_buf.len);
        @memcpy(self.last_click_buf[0..n], source[0..n]);
        self.last_click_len = n;
        self.clicks += weight;
        self.counter += 1;
        self.color_hex = 0x7C3AED;
        try DemoUpdated.emit(.{ .count = self.clicks, .source = source });
        return self.clicks;
    }

    pub fn getClickState(self: *const @This(), call: *rpc.Call) !CounterEvent {
        return .{
            .count = self.clicks * 100 + self.reentrant_observed,
            .source = try call.arena.dupe(u8, self.last_click_buf[0..self.last_click_len]),
        };
    }

    fn onFetchBody(self: *DemoService, out: js.Outcome) void {
        switch (out) {
            .resolved => |body_h| {
                const body = js.readString(body_h, std.heap.wasm_allocator) catch return;
                defer std.heap.wasm_allocator.free(body);
                self.fetch_len = @intCast(body.len);
                self.fetch_has_webruntime = std.mem.indexOf(u8, body, "export interface WebRuntime") != null;
                self.color_hex = 0x16A34A;
                self.fetch_done = true;
                self.counter += 1;
                DemoUpdated.emit(.{ .count = self.counter, .source = "fetch" }) catch {};
            },
            .rejected => {
                self.fetch_done = true;
            },
        }
    }

    fn onFetchResponse(self: *DemoService, out: js.Outcome) void {
        switch (out) {
            .resolved => |resp_h| {
                const status_h = js.get(resp_h, "status") catch return;
                defer status_h.release();
                self.fetch_status = js.asInt(u32, status_h) catch 0;
                const text_p = js.invoke(resp_h, "text", &.{}) catch return;
                defer text_p.release();
                _ = js.awaitCallback(DemoService, text_p, self, onFetchBody) catch {};
            },
            .rejected => {
                self.fetch_done = true;
            },
        }
    }

    pub fn startFetchText(self: *@This(), url: []const u8) !void {
        self.fetch_done = false;
        self.fetch_status = 0;
        self.fetch_len = 0;
        self.fetch_has_webruntime = false;
        const p = try js.invoke(js.global, "fetch", &.{.from(url)});
        defer p.release();
        _ = try js.awaitCallback(DemoService, p, self, onFetchResponse);
    }

    pub fn pollFetch(self: *const @This()) FetchReport {
        return .{
            .done = self.fetch_done,
            .status = self.fetch_status,
            .byte_len = self.fetch_len,
            .has_webruntime = self.fetch_has_webruntime,
        };
    }

    fn onDelayedColor(self: *DemoService, outcome: rpc.Outcome(u32)) void {
        if (outcome == .ok) {
            self.color_hex = @truncate(outcome.ok);
            self.counter += 1;
        }
    }

    pub fn awaitDelayedColor(self: *@This(), delay_ms: u32, next_color: u32) !void {
        _ = try rpc.HostClient(DemoHost).call(.delayedColor, .{ delay_ms, next_color }, self, onDelayedColor);
    }

    pub fn readHostBanner(_: *const @This(), call: *rpc.Call, key: []const u8) !?[]const u8 {
        return rpc.HostClient(DemoHost).callSync(call.arena, .readBanner, .{key});
    }

    pub fn makeUncloneableHandle(_: *const @This()) !js.Handle {
        return js.get(js.global, "setTimeout");
    }
};

pub const AppSchema = rpc.Schema(.{
    .services = &.{ MathService, DemoService },
    .hosts = &.{ CheckHost, DemoHost },
    .events = &.{ CounterChanged.web_event, DemoUpdated.web_event },
});

pub const dts = AppSchema.dts;
