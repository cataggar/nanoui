//! Bounded async URL image cache for browser WebGPU/WebGL2 surfaces, with a
//! deterministic headless mock host for `ui.Tester`, Wasmtime, and native tests.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const host = @import("image_cache_host.zig");

pub const Options = struct {
    max_entries: usize = 256,
    max_bytes: usize = 64 * 1024 * 1024,
    max_concurrent: u32 = 6,
    max_dimension: u32 = 0,
};

pub const RequestOptions = struct { key: ?[]const u8 = null, max_width: u32 = 0, max_height: u32 = 0 };
pub const State = union(enum) { loading, ready: ui.Texture, failed };
pub const Fit = enum { cover, contain, fill };

pub const WidgetOptions = struct {
    /// Sibling-scoped UI node key passed to `Context.open`.
    key: ?[]const u8 = null,
    /// Optional global cache key (defaults to `url`, e.g. for expiring presigned URLs).
    cache_key: ?[]const u8 = null,
    width: ui.Length = .{ .px = 64 },
    height: ui.Length = .{ .px = 64 },
    radius: f32 = 8,
    fit: Fit = .cover,
    placeholder_bg: ?ui.Color = null,
    failed_bg: ?ui.Color = null,
    failed_icon: ?[]const u8 = "photo",
    icon_size: f32 = 18,
    fade_duration: f32 = 0.16,
    max_width: u32 = 0,
    max_height: u32 = 0,
    opacity: f32 = 1.0,
};

pub const MockImage = struct { width: u32 = 64, height: u32 = 64, bgra: []const u8 = &.{}, byte_len: ?usize = null };
pub const MockStats = host.MockStats;

const none: u32 = std.math.maxInt(u32);
const LookupKey = struct { key: []const u8, max_w: u32, max_h: u32 };

const LookupContext = struct {
    pub fn hash(_: LookupContext, k: LookupKey) u64 {
        var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
        h.update(k.key);
        h.update(std.mem.asBytes(&k.max_w));
        h.update(std.mem.asBytes(&k.max_h));
        return h.final();
    }
    pub fn eql(_: LookupContext, a: LookupKey, b: LookupKey) bool {
        return a.max_w == b.max_w and a.max_h == b.max_h and std.mem.eql(u8, a.key, b.key);
    }
};

const EntryStatus = enum { free, loading, ready, failed };
const Entry = struct {
    status: EntryStatus = .free,
    key: []u8 = &.{},
    url: []u8 = &.{},
    mock_bgra: []u8 = &.{},
    max_w: u32 = 0,
    max_h: u32 = 0,
    req_id: u32 = 0,
    handle: u32 = 0,
    serial: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    byte_len: usize = 0,
    pin_token: u64 = 0,
    prev: u32 = none,
    next: u32 = none,
};

const mod = @This();

/// Keep `ImageCache` at a stable memory address while requests are in flight
/// (from its first `get`/`getWith`/`image` call until `clear()` or `deinit()`).
pub const ImageCache = struct {
    pub const Options = mod.Options;
    pub const RequestOptions = mod.RequestOptions;
    pub const State = mod.State;
    pub const Fit = mod.Fit;
    pub const WidgetOptions = mod.WidgetOptions;
    pub const MockImage = mod.MockImage;
    pub const MockStats = mod.MockStats;

    gpa: std.mem.Allocator,
    options: mod.Options,
    cache_id: u32,
    is_mock: bool,
    device_generation: u64 = 0,
    active_pin_token: u64 = 0,
    ready_count: usize = 0,
    loading_count: usize = 0,
    failed_count: usize = 0,
    total_bytes: usize = 0,
    lru_head: u32 = none,
    lru_tail: u32 = none,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    map: std.HashMapUnmanaged(LookupKey, u32, LookupContext, 80) = .empty,
    by_req: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    mock: host.MockHost = .{},

    pub fn init(gpa: std.mem.Allocator, options: mod.Options) ImageCache {
        return initMode(gpa, options, !host.has_browser_host);
    }

    pub fn initMock(gpa: std.mem.Allocator, options: mod.Options) ImageCache {
        return initMode(gpa, options, true);
    }

    fn initMode(gpa: std.mem.Allocator, options: mod.Options, use_mock: bool) ImageCache {
        var out: ImageCache = .{ .gpa = gpa, .options = options, .cache_id = host.reserveSlot(), .is_mock = use_mock, .device_generation = if (use_mock) 1 else ui.webgpuDeviceGeneration() };
        if (use_mock) out.mock.max_concurrent = options.max_concurrent else {
            host.activateBrowserHost();
            host.browserSetConcurrency(options.max_concurrent);
        }
        return out;
    }

    pub fn deinit(self: *ImageCache) void {
        self.clear();
        self.entries.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
        self.map.deinit(self.gpa);
        self.by_req.deinit(self.gpa);
        self.mock.deinit(self.gpa);
        host.unregister(self.cache_id);
        self.cache_id = 0;
    }

    fn useMock(self: *const ImageCache) bool {
        return self.is_mock or !host.has_browser_host;
    }

    fn syncGeneration(self: *ImageCache) void {
        const gen = if (self.useMock()) self.mock.device_generation else ui.webgpuDeviceGeneration();
        if (gen != self.device_generation) {
            self.clear();
            self.device_generation = gen;
        }
    }

    pub fn get(self: *ImageCache, c: *ui.Context, url: []const u8) mod.State {
        return self.getWith(c, url, .{});
    }

    pub fn getWith(self: *ImageCache, c: *ui.Context, url: []const u8, req_opts: mod.RequestOptions) mod.State {
        host.bind(self.cache_id, self, onCompleteThunk, self.by_req.count() > 0);
        self.syncGeneration();
        if (self.useMock()) self.mock.waker = c.waker;
        if (url.len == 0) return .failed;

        const token = c.frame +% 1;
        self.active_pin_token = token;
        const max_w = if (req_opts.max_width != 0) req_opts.max_width else self.options.max_dimension;
        const max_h = if (req_opts.max_height != 0) req_opts.max_height else self.options.max_dimension;
        const base_key = req_opts.key orelse url;
        const lk: LookupKey = .{ .key = base_key, .max_w = max_w, .max_h = max_h };

        if (self.map.get(lk)) |idx| {
            self.touch(idx);
            self.entries.items[idx].pin_token = token;
            return entryState(&self.entries.items[idx]);
        }

        _ = self.insertLoadingEntry(base_key, url, max_w, max_h, token) catch return .failed;
        return .loading;
    }

    fn insertLoadingEntry(self: *ImageCache, base_key: []const u8, url: []const u8, max_w: u32, max_h: u32, token: u64) !u32 {
        const dup_key = try self.gpa.dupe(u8, base_key);
        errdefer self.gpa.free(dup_key);
        const dup_url = try self.gpa.dupe(u8, url);
        errdefer self.gpa.free(dup_url);

        var from_free_list = false;
        const idx: u32 = if (self.free_list.pop()) |reused| blk: {
            from_free_list = true;
            break :blk reused;
        } else blk: {
            const n: u32 = @intCast(self.entries.items.len);
            try self.entries.append(self.gpa, .{});
            break :blk n;
        };
        errdefer {
            if (from_free_list) self.free_list.appendAssumeCapacity(idx) else _ = self.entries.pop();
        }

        const lk: LookupKey = .{ .key = dup_key, .max_w = max_w, .max_h = max_h };
        try self.map.put(self.gpa, lk, idx);
        errdefer _ = self.map.remove(lk);

        const req_id = host.nextReqId();
        try self.by_req.put(self.gpa, req_id, idx);
        errdefer _ = self.by_req.remove(req_id);

        if (self.useMock()) try self.mock.request(self.gpa, req_id, dup_key, dup_url, max_w, max_h, @truncate(self.device_generation));

        self.entries.items[idx] = .{ .status = .loading, .key = dup_key, .url = dup_url, .max_w = max_w, .max_h = max_h, .req_id = req_id, .pin_token = token };
        self.loading_count += 1;
        self.linkTail(idx);
        self.evictIfNeeded();

        if (!self.useMock()) host.browserRequest(self.cache_id, req_id, dup_url, max_w, max_h, @truncate(self.device_generation));
        return idx;
    }

    fn entryState(e: *const Entry) mod.State {
        return switch (e.status) {
            .loading, .free => .loading,
            .failed => .failed,
            .ready => .{ .ready = .{ .width = e.width, .height = e.height, .web_texture = e.handle, .bgra = e.mock_bgra, .format = .bgra8, .encoding = .display_sdr } },
        };
    }

    fn isPinned(self: *const ImageCache, e: *const Entry) bool {
        return e.pin_token != 0 and self.active_pin_token != 0 and e.pin_token +| 1 >= self.active_pin_token;
    }

    fn onCompleteThunk(ctx: *anyopaque, req_id: u32, handle: u32, serial: u32, width: u32, height: u32, byte_len: u32, status: u32) bool {
        const self: *ImageCache = @ptrCast(@alignCast(ctx));
        return self.onComplete(req_id, handle, serial, width, height, byte_len, status);
    }

    pub fn onComplete(self: *ImageCache, req_id: u32, handle: u32, serial: u32, width: u32, height: u32, byte_len: u32, status: u32) bool {
        const kv = self.by_req.fetchRemove(req_id) orelse {
            if (handle != 0) self.releaseHandle(handle, serial);
            return false;
        };
        const idx = kv.value;
        const e = &self.entries.items[idx];
        if (e.status != .loading) {
            if (handle != 0) self.releaseHandle(handle, serial);
            return false;
        }
        e.req_id = 0;

        switch (@as(host.Status, @fromBackingInt(@intCast(status)))) {
            .ok => {
                if (handle == 0 or width == 0 or height == 0) return self.markFailed(e, handle, serial);
                const bytes = if (byte_len != 0) @as(usize, byte_len) else @as(usize, width) * @as(usize, height) * 4;
                self.loading_count -= 1;
                self.ready_count += 1;
                self.total_bytes += bytes;
                e.status = .ready;
                e.handle = handle;
                e.serial = serial;
                e.width = width;
                e.height = height;
                e.byte_len = bytes;
                self.evictIfNeeded();
                return true;
            },
            .stale => {
                if (handle != 0) self.releaseHandle(handle, serial);
                self.removeEntryAt(idx);
                return true;
            },
            .failed, _ => return self.markFailed(e, handle, serial),
        }
    }

    fn markFailed(self: *ImageCache, e: *Entry, handle: u32, serial: u32) bool {
        if (handle != 0) self.releaseHandle(handle, serial);
        self.loading_count -= 1;
        self.failed_count += 1;
        e.status = .failed;
        return true;
    }

    fn evictIfNeeded(self: *ImageCache) void {
        const max_transient = @max(self.options.max_entries *| 2, 64);
        var cur = self.lru_head;
        while (cur != none) {
            const e = &self.entries.items[cur];
            const next = e.next;
            const over_ready = self.ready_count > self.options.max_entries or self.total_bytes > self.options.max_bytes;
            const over_transient = (self.loading_count + self.failed_count) > max_transient;
            if (!over_ready and !over_transient) break;
            if (!self.isPinned(e)) {
                if (e.status == .ready and over_ready) self.removeEntryAt(cur) else if ((e.status == .loading or e.status == .failed) and over_transient) self.removeEntryAt(cur);
            }
            cur = next;
        }
    }

    fn removeEntryAt(self: *ImageCache, idx: u32) void {
        const e = &self.entries.items[idx];
        if (e.status == .free) return;
        _ = self.map.remove(.{ .key = e.key, .max_w = e.max_w, .max_h = e.max_h });
        if (e.req_id != 0) {
            _ = self.by_req.remove(e.req_id);
            self.cancelRequest(e.req_id);
        }
        switch (e.status) {
            .ready => {
                self.releaseHandle(e.handle, e.serial);
                self.ready_count -= 1;
                self.total_bytes -= e.byte_len;
            },
            .loading => self.loading_count -= 1,
            .failed => self.failed_count -= 1,
            .free => {},
        }
        self.unlink(idx);
        self.gpa.free(e.key);
        self.gpa.free(e.url);
        if (e.mock_bgra.len > 0) self.gpa.free(e.mock_bgra);
        e.* = .{};
        self.free_list.append(self.gpa, idx) catch {};
    }

    fn releaseHandle(self: *ImageCache, handle: u32, serial: u32) void {
        if (handle == 0) return;
        if (self.useMock()) self.mock.release(handle, serial) else host.browserRelease(handle, serial);
    }

    fn cancelRequest(self: *ImageCache, req_id: u32) void {
        if (req_id == 0) return;
        if (self.useMock()) self.mock.cancel(self.gpa, req_id) else host.browserCancel(req_id);
    }

    fn linkTail(self: *ImageCache, idx: u32) void {
        const e = &self.entries.items[idx];
        e.prev = self.lru_tail;
        e.next = none;
        if (self.lru_tail != none) self.entries.items[self.lru_tail].next = idx else self.lru_head = idx;
        self.lru_tail = idx;
    }

    fn unlink(self: *ImageCache, idx: u32) void {
        const e = &self.entries.items[idx];
        if (e.prev != none) self.entries.items[e.prev].next = e.next else if (self.lru_head == idx) self.lru_head = e.next;
        if (e.next != none) self.entries.items[e.next].prev = e.prev else if (self.lru_tail == idx) self.lru_tail = e.prev;
        e.prev = none;
        e.next = none;
    }

    fn touch(self: *ImageCache, idx: u32) void {
        if (self.lru_tail == idx) return;
        self.unlink(idx);
        self.linkTail(idx);
    }

    pub fn setLimits(self: *ImageCache, max_entries: usize, max_bytes: usize) void {
        self.options.max_entries = max_entries;
        self.options.max_bytes = max_bytes;
        self.evictIfNeeded();
    }

    pub fn invalidate(self: *ImageCache, key_or_url: []const u8) void {
        self.removeMatching(key_or_url, false);
    }

    pub fn retry(self: *ImageCache, key_or_url: []const u8) void {
        self.removeMatching(key_or_url, true);
    }

    fn removeMatching(self: *ImageCache, key_or_url: []const u8, failed_only: bool) void {
        var cur = self.lru_head;
        while (cur != none) {
            const e = &self.entries.items[cur];
            const next = e.next;
            if ((!failed_only or e.status == .failed) and (std.mem.eql(u8, e.key, key_or_url) or std.mem.eql(u8, e.url, key_or_url))) {
                self.removeEntryAt(cur);
            }
            cur = next;
        }
    }

    pub fn clear(self: *ImageCache) void {
        var cur = self.lru_head;
        while (cur != none) {
            const next = self.entries.items[cur].next;
            self.removeEntryAt(cur);
            cur = next;
        }
    }

    pub fn entryCount(self: *const ImageCache) usize {
        return self.ready_count + self.loading_count + self.failed_count;
    }
    pub fn readyCount(self: *const ImageCache) usize {
        return self.ready_count;
    }
    pub fn loadingCount(self: *const ImageCache) usize {
        return self.loading_count;
    }
    pub fn totalBytes(self: *const ImageCache) usize {
        return self.total_bytes;
    }
    pub fn mockStats(self: *const ImageCache) mod.MockStats {
        return self.mock.stats();
    }
    pub fn mockSetDeviceGeneration(self: *ImageCache, gen: u64) void {
        self.mock.device_generation = gen;
    }
    pub fn mockResolve(self: *ImageCache, key_or_url: []const u8, img: mod.MockImage) bool {
        return self.resolveMockInternal(key_or_url, null, .ok, img);
    }
    pub fn mockResolveSized(self: *ImageCache, key_or_url: []const u8, max_w: u32, max_h: u32, img: mod.MockImage) bool {
        return self.resolveMockInternal(key_or_url, .{ max_w, max_h }, .ok, img);
    }
    pub fn mockFail(self: *ImageCache, key_or_url: []const u8) bool {
        return self.resolveMockInternal(key_or_url, null, .failed, .{});
    }
    pub fn mockAbortStale(self: *ImageCache, key_or_url: []const u8) bool {
        return self.resolveMockInternal(key_or_url, null, .stale, .{});
    }

    fn resolveMockInternal(self: *ImageCache, key_or_url: []const u8, dims: ?[2]u32, status: host.Status, img: mod.MockImage) bool {
        if (!self.useMock()) return false;
        host.bind(self.cache_id, self, onCompleteThunk, self.by_req.count() > 0);
        var matched = false;
        var i: usize = 0;
        while (i < self.mock.pending.items.len) {
            const p = self.mock.pending.items[i];
            const name_ok = std.mem.eql(u8, p.key, key_or_url) or std.mem.eql(u8, p.url, key_or_url);
            const dims_ok = if (dims) |d| (p.max_w == d[0] and p.max_h == d[1]) else true;
            if (!name_ok or !dims_ok) {
                i += 1;
                continue;
            }
            const removed = self.mock.pending.orderedRemove(i);
            self.gpa.free(removed.key);
            self.gpa.free(removed.url);

            if (status == .ok) {
                const hs = self.mock.allocHandle(self.gpa) catch continue;
                if (img.bgra.len > 0) if (self.by_req.get(removed.req_id)) |idx| if (self.gpa.dupe(u8, img.bgra)) |dup| {
                    if (self.entries.items[idx].mock_bgra.len > 0) self.gpa.free(self.entries.items[idx].mock_bgra);
                    self.entries.items[idx].mock_bgra = dup;
                } else |_| {};
                const raw_bytes = img.byte_len orelse (@as(usize, img.width) * @as(usize, img.height) * 4);
                host.handleComplete(self.cache_id, removed.req_id, hs.handle, hs.serial, img.width, img.height, @intCast(@min(raw_bytes, std.math.maxInt(u32))), @backingInt(status));
            } else host.handleComplete(self.cache_id, removed.req_id, 0, 0, 0, 0, 0, @backingInt(status));
            matched = true;
        }
        if (matched) self.mock.wake();
        return matched;
    }

    pub fn image(self: *ImageCache, c: *ui.Context, url: []const u8, opts: mod.WidgetOptions) mod.State {
        const state = self.getWith(c, url, .{ .key = opts.cache_key, .max_width = opts.max_width, .max_height = opts.max_height });
        const eff_w = if (opts.max_width != 0) opts.max_width else self.options.max_dimension;
        const eff_h = if (opts.max_height != 0) opts.max_height else self.options.max_dimension;
        const box_id = c.peekId(opts.key);
        const salt = urlSalt(opts.cache_key orelse url, eff_w, eff_h);
        const opacity = std.math.clamp(opts.opacity, 0.0, 1.0);
        const ph_color = opts.placeholder_bg orelse c.theme.surface_hover;

        switch (state) {
            .loading, .failed => {
                if (opts.fade_duration > 0) ui.jump(c, box_id, salt, 0.0);
                const bg = if (state == .failed) (opts.failed_bg orelse c.theme.surface_hover) else ph_color;
                _ = c.open(.{ .width = opts.width, .height = opts.height, .radius = opts.radius, .clip = true, .align_items = .center, .justify = .center, .background = bg.alpha(opacity) }, opts.key);
                if (state == .failed) {
                    if (opts.failed_icon) |ic| if (ic.len > 0) ui.icon(c, ic, .{ .size = opts.icon_size, .color = c.theme.muted.alpha(opacity) });
                }
                c.end();
            },
            .ready => |tex| {
                const fade = if (opts.fade_duration > 0) std.math.clamp(ui.tween(c, box_id, salt, 1.0, opts.fade_duration, .ease_out), 0.0, 1.0) else 1.0;
                const alpha = fade * opacity;
                const bg: ?ui.Color = if (fade < 0.999) ph_color.alpha((1.0 - fade) * opacity) else null;
                const idx = c.open(.{ .width = opts.width, .height = opts.height, .radius = opts.radius, .clip = true, .align_items = .center, .justify = .center, .background = bg }, opts.key);
                if (opts.fit != .fill and (opts.width != .px or opts.height != .px)) c.node(idx).layout_dependent = true;
                const box_sz = resolveBoxSize(c, box_id, opts.width, opts.height, tex.width, tex.height);
                switch (opts.fit) {
                    .fill => ui.texture(c, .{ .width = .fill, .height = .fill, .radius = opts.radius }, tex, .{ 0, 0, 1, 1 }, alpha),
                    .cover => ui.texture(c, .{ .width = .fill, .height = .fill, .radius = opts.radius }, tex, coverUv(tex.width, tex.height, box_sz[0], box_sz[1]), alpha),
                    .contain => {
                        const tw: f32 = @floatFromInt(@max(tex.width, 1));
                        const th: f32 = @floatFromInt(@max(tex.height, 1));
                        const s = @min(@max(box_sz[0], 1) / tw, @max(box_sz[1], 1) / th);
                        ui.texture(c, .{ .width = .{ .px = tw * s }, .height = .{ .px = th * s } }, tex, .{ 0, 0, 1, 1 }, alpha);
                    },
                }
                c.end();
            },
        }
        return state;
    }
};

fn urlSalt(label: []const u8, max_w: u32, max_h: u32) u32 {
    var h = std.hash.Wyhash.init(0x517cc1b727220a95);
    h.update(label);
    h.update(std.mem.asBytes(&max_w));
    h.update(std.mem.asBytes(&max_h));
    const v: u32 = @truncate(h.final());
    return if (v == 0) 1 else v;
}

fn resolveBoxSize(c: *const ui.Context, id: u64, w_len: ui.Length, h_len: ui.Length, tw: u32, th: u32) [2]f32 {
    if (c.rects.get(id)) |r| if (r.w > 0 and r.h > 0) return .{ r.w, r.h };
    const w: f32 = if (w_len == .px) w_len.px else @floatFromInt(@max(tw, 1));
    const h: f32 = if (h_len == .px) h_len.px else @floatFromInt(@max(th, 1));
    return .{ @max(w, 1), @max(h, 1) };
}

fn coverUv(tw_u: u32, th_u: u32, bw: f32, bh: f32) [4]f32 {
    const tw: f32 = @floatFromInt(@max(tw_u, 1));
    const th: f32 = @floatFromInt(@max(th_u, 1));
    const tex_aspect = tw / th;
    const box_aspect = @max(bw, 1) / @max(bh, 1);
    if (tex_aspect > box_aspect) {
        const pad = (1.0 - box_aspect / tex_aspect) * 0.5;
        return .{ pad, 0, 1.0 - pad, 1 };
    } else if (box_aspect > tex_aspect) {
        const pad = (1.0 - tex_aspect / box_aspect) * 0.5;
        return .{ 0, pad, 1, 1.0 - pad };
    }
    return .{ 0, 0, 1, 1 };
}

test {
    _ = .{ host, @import("image_cache_tests.zig") };
}
