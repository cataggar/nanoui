//! Browser Wasm host bridge (`"nanoui_images"`), generation-tagged cache
//! slot registry, and deterministic headless `MockHost` stub for `ImageCache`.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const ui = @import("../ui/ui.zig");

pub const has_browser_host = builtin.os.tag == .wasi and
    (backend.current == .auto or backend.current == .webgpu) and
    !builtin.is_test;

pub const Status = enum(u32) { ok = 1, failed = 2, stale = 3, _ };

const raw = struct {
    pub extern "nanoui_images" fn request(cache_id: u32, req_id: u32, url_ptr: [*]const u8, url_len: usize, max_w: u32, max_h: u32, gen: u32) void;
    pub extern "nanoui_images" fn cancel(req_id: u32) void;
    pub extern "nanoui_images" fn release(handle: u32, serial: u32) void;
    pub extern "nanoui_images" fn set_concurrency(max_concurrent: u32) void;
};

pub const max_slots = 64;
pub const CompleteFn = *const fn (ctx: *anyopaque, req_id: u32, handle: u32, serial: u32, width: u32, height: u32, byte_len: u32, status: u32) bool;

const Slot = struct { ptr: ?*anyopaque = null, on_complete: ?CompleteFn = null, gen: u16 = 1, in_use: bool = false };

var slots: [max_slots]Slot = @splat(.{});
var next_req_id: u32 = 1;
var release_orphan: ?*const fn (u32, u32) void = null;
var orphan_releases: usize = 0;

pub fn activateBrowserHost() void {
    if (comptime has_browser_host) release_orphan = &browserRelease;
}

pub fn browserRequest(cache_id: u32, req_id: u32, url: []const u8, max_w: u32, max_h: u32, gen: u32) void {
    if (comptime has_browser_host) raw.request(cache_id, req_id, url.ptr, url.len, max_w, max_h, gen);
}

pub fn browserCancel(req_id: u32) void {
    if (comptime has_browser_host) if (req_id != 0) raw.cancel(req_id);
}

pub fn browserRelease(handle: u32, serial: u32) void {
    if (comptime has_browser_host) if (handle != 0) raw.release(handle, serial);
}

pub fn browserSetConcurrency(max_concurrent: u32) void {
    if (comptime has_browser_host) raw.set_concurrency(max_concurrent);
}

pub fn reserveSlot() u32 {
    for (&slots, 0..) |*slot, idx| {
        if (!slot.in_use) {
            slot.in_use = true;
            slot.ptr = null;
            slot.on_complete = null;
            return (@as(u32, slot.gen) << 16) | @as(u32, @intCast(idx));
        }
    }
    return 0;
}

pub fn bind(cache_id: u32, ptr: *anyopaque, on_complete: CompleteFn, has_in_flight: bool) void {
    const idx = cache_id & 0xFFFF;
    const gen: u16 = @truncate(cache_id >> 16);
    if (gen == 0 or idx >= max_slots) return;
    const slot = &slots[idx];
    if (!slot.in_use or slot.gen != gen) return;
    if (has_in_flight) std.debug.assert(slot.ptr == null or slot.ptr.? == ptr);
    slot.ptr = ptr;
    slot.on_complete = on_complete;
}

pub fn unregister(cache_id: u32) void {
    const idx = cache_id & 0xFFFF;
    const gen: u16 = @truncate(cache_id >> 16);
    if (gen == 0 or idx >= max_slots) return;
    const slot = &slots[idx];
    if (!slot.in_use or slot.gen != gen) return;
    slot.* = .{ .gen = if (slot.gen == std.math.maxInt(u16)) 1 else slot.gen + 1 };
}

pub fn nextReqId() u32 {
    const id = next_req_id;
    next_req_id = if (id == std.math.maxInt(u32)) 1 else id + 1;
    return id;
}

pub fn orphanReleaseCount() usize {
    return orphan_releases;
}

fn dispatchComplete(cache_id: u32, req_id: u32, handle: u32, serial: u32, width: u32, height: u32, byte_len: u32, status: u32) bool {
    const idx = cache_id & 0xFFFF;
    const gen: u16 = @truncate(cache_id >> 16);
    if (gen == 0 or idx >= max_slots) {
        releaseOrphan(handle, serial);
        return false;
    }
    const slot = &slots[idx];
    if (!slot.in_use or slot.gen != gen or slot.ptr == null or slot.on_complete == null) {
        releaseOrphan(handle, serial);
        return false;
    }
    return slot.on_complete.?(slot.ptr.?, req_id, handle, serial, width, height, byte_len, status);
}

pub fn handleComplete(cache_id: u32, req_id: u32, handle: u32, serial: u32, width: u32, height: u32, byte_len: u32, status: u32) void {
    _ = dispatchComplete(cache_id, req_id, handle, serial, width, height, byte_len, status);
}

fn releaseOrphan(handle: u32, serial: u32) void {
    if (handle == 0) return;
    orphan_releases += 1;
    if (release_orphan) |rel| rel(handle, serial);
}

/// Referenced only from `src/web/web.zig` on WASI so standalone WASI tools
/// (`check`, `bench`) never pull in browser-only exports or imports.
pub const exports = struct {
    pub export fn nanoui_web_image_complete(cache_id: u32, req_id: u32, handle: u32, serial: u32, width: u32, height: u32, byte_len: u32, status: u32) void {
        if (dispatchComplete(cache_id, req_id, handle, serial, width, height, byte_len, status)) {
            if (comptime (builtin.os.tag == .wasi and !backend.is_embed)) {
                if (@import("web.zig").active) |s| s.requestFrame();
            }
        }
    }
};

pub const MockStats = struct {
    request_count: usize = 0,
    release_count: usize = 0,
    cancel_count: usize = 0,
    active_handles: usize = 0,
    pending_count: usize = 0,
    max_concurrent: u32 = 0,
};

pub const PendingRequest = struct { req_id: u32, key: []u8, url: []u8, max_w: u32, max_h: u32, gen: u32 };

pub const MockHost = struct {
    device_generation: u64 = 1,
    request_count: usize = 0,
    release_count: usize = 0,
    cancel_count: usize = 0,
    max_concurrent: u32 = 0,
    next_handle: u32 = 1,
    next_serial: u32 = 1,
    handles: std.AutoHashMapUnmanaged(u64, void) = .empty,
    pending: std.ArrayListUnmanaged(PendingRequest) = .empty,
    waker: ?ui.Waker = null,

    pub fn deinit(self: *MockHost, gpa: std.mem.Allocator) void {
        for (self.pending.items) |p| {
            gpa.free(p.key);
            gpa.free(p.url);
        }
        self.pending.deinit(gpa);
        self.handles.deinit(gpa);
        self.* = .{};
    }

    pub fn request(self: *MockHost, gpa: std.mem.Allocator, req_id: u32, key: []const u8, url: []const u8, max_w: u32, max_h: u32, gen: u32) !void {
        const dup_key = try gpa.dupe(u8, key);
        errdefer gpa.free(dup_key);
        const dup_url = try gpa.dupe(u8, url);
        errdefer gpa.free(dup_url);
        try self.pending.append(gpa, .{ .req_id = req_id, .key = dup_key, .url = dup_url, .max_w = max_w, .max_h = max_h, .gen = gen });
        self.request_count += 1;
    }

    pub fn cancel(self: *MockHost, gpa: std.mem.Allocator, req_id: u32) void {
        if (req_id == 0) return;
        self.cancel_count += 1;
        for (self.pending.items, 0..) |p, i| {
            if (p.req_id == req_id) {
                _ = self.pending.orderedRemove(i);
                gpa.free(p.key);
                gpa.free(p.url);
                return;
            }
        }
    }

    pub fn allocHandle(self: *MockHost, gpa: std.mem.Allocator) !struct { handle: u32, serial: u32 } {
        const h = self.next_handle;
        self.next_handle = if (h == std.math.maxInt(u32)) 1 else h + 1;
        const s = self.next_serial;
        self.next_serial = if (s == std.math.maxInt(u32)) 1 else s + 1;
        try self.handles.put(gpa, (@as(u64, s) << 32) | h, {});
        return .{ .handle = h, .serial = s };
    }

    pub fn release(self: *MockHost, handle: u32, serial: u32) void {
        if (handle == 0) return;
        self.release_count += 1;
        _ = self.handles.remove((@as(u64, serial) << 32) | handle);
    }

    pub fn wake(self: *const MockHost) void {
        if (self.waker) |w| w.wake(w.ctx);
    }

    pub fn stats(self: *const MockHost) MockStats {
        return .{
            .request_count = self.request_count,
            .release_count = self.release_count,
            .cancel_count = self.cancel_count,
            .active_handles = self.handles.count(),
            .pending_count = self.pending.items.len,
            .max_concurrent = self.max_concurrent,
        };
    }
};

test "slot registry generation tags and orphan handle release" {
    const Hook = struct {
        var last_handle: u32 = 0;
        var last_serial: u32 = 0;
        fn onOrphan(h: u32, s: u32) void {
            last_handle = h;
            last_serial = s;
        }
    };
    const prev_hook = release_orphan;
    defer release_orphan = prev_hook;
    release_orphan = &Hook.onOrphan;

    const id1 = reserveSlot();
    try std.testing.expect(id1 != 0);
    unregister(id1);
    const id2 = reserveSlot();
    defer unregister(id2);
    try std.testing.expect((id1 & 0xFFFF) == (id2 & 0xFFFF) and id1 != id2);

    const before = orphanReleaseCount();
    handleComplete(id1, 99, 42, 7, 64, 64, 0, @backingInt(Status.ok));
    try std.testing.expectEqual(before + 1, orphanReleaseCount());
    try std.testing.expectEqual(@as(u32, 42), Hook.last_handle);
    try std.testing.expectEqual(@as(u32, 7), Hook.last_serial);
}
