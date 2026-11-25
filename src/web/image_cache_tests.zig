//! Unit and `ui.Tester` widget tests for `ImageCache` and `MockHost` (native + Wasmtime).
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const ic = @import("image_cache.zig");
const host = @import("image_cache_host.zig");
const ImageCache = ic.ImageCache;

fn findFirstTexture(c: *const ui.Context) ?struct { rect: ui.Rect, uv: [4]f32, opacity: f32 } {
    for (c.nodes.items) |n| if (n.content == .texture) {
        return .{ .rect = n.rect, .uv = n.content.texture.uv, .opacity = n.content.texture.opacity };
    };
    return null;
}

fn countIconsNamed(c: *const ui.Context, name: []const u8) usize {
    var count: usize = 0;
    for (c.nodes.items) |n| if (n.content == .icon and std.mem.eql(u8, n.content.icon.name, name)) {
        count += 1;
    };
    return count;
}

fn pixelAt(pix: anytype, x: usize, y: usize) [4]u8 {
    return pix.bytes[(y * pix.width + x) * 4 ..][0..4].*;
}

test "in-flight deduplication across rows and frames, custom cache keys, size buckets, and empty URL" {
    const gpa = testing.allocator;
    var cache = ImageCache.initMock(gpa, .{});
    defer cache.deinit();

    const State = struct {
        cache: *ImageCache,
        mode: enum { dup, keys_and_buckets } = .dup,
        dup_states: [10]ic.State = @splat(.failed),
        empty_state: ic.State = .loading,
        sig1_state: ic.State = .loading,
        sig2_state: ic.State = .loading,
        small_state: ic.State = .loading,
        large_state: ic.State = .loading,

        pub fn build(s: *@This(), c: *ui.Context) void {
            s.empty_state = s.cache.get(c, "");
            switch (s.mode) {
                .dup => for (0..10) |i| {
                    ui.keyInt(c, i);
                    s.dup_states[i] = s.cache.get(c, "https://cdn.example/avatar.png");
                },
                .keys_and_buckets => {
                    s.sig1_state = s.cache.getWith(c, "https://cdn/img.png?sig=1", .{ .key = "asset:42" });
                    s.sig2_state = s.cache.getWith(c, "https://cdn/img.png?sig=2", .{ .key = "asset:42" });
                    s.small_state = s.cache.getWith(c, "https://cdn/photo.jpg", .{ .max_width = 64, .max_height = 64 });
                    s.large_state = s.cache.getWith(c, "https://cdn/photo.jpg", .{ .max_width = 256, .max_height = 256 });
                },
            }
        }
    };

    var app: State = .{ .cache = &cache };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&app, State.build), .{ .width = 200, .height = 120 });
    defer t.deinit();

    for (0..3) |_| t.frame();
    try testing.expect(app.empty_state == .failed);
    for (app.dup_states) |st| try testing.expect(st == .loading);
    try testing.expect(cache.loadingCount() == 1 and cache.entryCount() == 1);
    try testing.expect(cache.mockStats().request_count == 1 and cache.mockStats().pending_count == 1);

    app.mode = .keys_and_buckets;
    t.frame();
    t.frame();
    try testing.expect(app.sig1_state == .loading and app.sig2_state == .loading);
    try testing.expect(app.small_state == .loading and app.large_state == .loading);
    // 1 earlier avatar + 1 shared key ("asset:42") + 2 size buckets = 4 requests total.
    try testing.expect(cache.mockStats().request_count == 4 and cache.mockStats().pending_count == 4 and cache.entryCount() == 4);

    try testing.expect(cache.mockResolve("asset:42", .{ .width = 40, .height = 30 }));
    try testing.expect(cache.mockResolveSized("https://cdn/photo.jpg", 64, 64, .{ .width = 64, .height = 48 }));
    t.frame();
    try testing.expect(app.sig1_state == .ready and app.sig2_state == .ready);
    try testing.expectEqual(@as(u32, 40), app.sig1_state.ready.width);
    try testing.expectEqual(app.sig1_state.ready.web_texture, app.sig2_state.ready.web_texture);
    try testing.expect(app.small_state == .ready and app.large_state == .loading);
    try testing.expect(app.small_state.ready.width == 64 and app.small_state.ready.height == 48);

    try testing.expect(cache.mockResolveSized("https://cdn/photo.jpg", 256, 256, .{ .width = 256, .height = 192 }));
    t.frame();
    try testing.expect(app.large_state == .ready);
    try testing.expect(app.large_state.ready.width == 256 and app.large_state.ready.height == 192);
    try testing.expectEqual(@as(u32, 64), app.small_state.ready.width);
    try testing.expect(app.small_state.ready.web_texture != app.large_state.ready.web_texture);
}

test "LRU eviction by max_entries, by max_bytes, and immediate dynamic setLimits shrink" {
    const gpa = testing.allocator;
    const UrlView = struct {
        cache: *ImageCache,
        urls: []const []const u8,
        states: [4]ic.State = @splat(.loading),
        pub fn build(s: *@This(), c: *ui.Context) void {
            for (s.urls, 0..) |u, i| s.states[i] = s.cache.get(c, u);
        }
    };

    // 1. Entry budget (max_entries = 3): B becomes LRU oldest after touching A.
    {
        var cache = ImageCache.initMock(gpa, .{ .max_entries = 3, .max_bytes = 64 * 1024 });
        defer cache.deinit();
        var app: UrlView = .{ .cache = &cache, .urls = &.{ "https://ex/A.png", "https://ex/B.png", "https://ex/C.png" } };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&app, UrlView.build), .{ .width = 160, .height = 100 });
        defer t.deinit();

        for (app.urls) |u| try testing.expect(cache.mockResolve(u, .{ .width = 8, .height = 8, .byte_len = 256 }));
        try testing.expectEqual(@as(usize, 3), cache.readyCount());

        // Advance past the 2-frame pin window, touch A so LRU order is B -> C -> A.
        app.urls = &.{};
        t.frame();
        app.urls = &.{"https://ex/A.png"};
        t.frame();
        try testing.expect(app.states[0] == .ready);

        app.urls = &.{};
        t.frame();
        app.urls = &.{"https://ex/D.png"};
        t.frame();
        try testing.expect(cache.mockResolve("https://ex/D.png", .{ .width = 8, .height = 8, .byte_len = 256 }));
        try testing.expect(cache.mockStats().release_count == 1 and cache.readyCount() == 3 and cache.mockStats().active_handles == 3);

        app.urls = &.{ "https://ex/A.png", "https://ex/C.png", "https://ex/D.png" };
        t.frame();
        try testing.expect(app.states[0] == .ready and app.states[1] == .ready and app.states[2] == .ready);
        try testing.expectEqual(@as(usize, 4), cache.mockStats().request_count);

        app.urls = &.{"https://ex/B.png"};
        t.frame();
        try testing.expect(app.states[0] == .loading and cache.mockStats().request_count == 5);
    }

    // 2. Byte budget (max_entries = 100, max_bytes = 2000) + dynamic setLimits(1, 800).
    {
        var cache = ImageCache.initMock(gpa, .{ .max_entries = 100, .max_bytes = 2000 });
        defer cache.deinit();
        var app: UrlView = .{ .cache = &cache, .urls = &.{"https://ex/b1.png"} };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&app, UrlView.build), .{ .width = 160, .height = 100 });
        defer t.deinit();

        try testing.expect(cache.mockResolve("https://ex/b1.png", .{ .width = 10, .height = 20, .byte_len = 800 }));
        app.urls = &.{};
        t.frame();
        app.urls = &.{"https://ex/b2.png"};
        t.frame();
        try testing.expect(cache.mockResolve("https://ex/b2.png", .{ .width = 10, .height = 20, .byte_len = 800 }));
        try testing.expect(cache.totalBytes() == 1600 and cache.mockStats().active_handles == 2);

        app.urls = &.{};
        t.frame();
        app.urls = &.{"https://ex/b3.png"};
        t.frame();
        try testing.expect(cache.mockResolve("https://ex/b3.png", .{ .width = 10, .height = 20, .byte_len = 800 }));
        try testing.expect(cache.totalBytes() == 1600 and cache.readyCount() == 2);
        try testing.expect(cache.mockStats().active_handles == 2 and cache.mockStats().release_count == 1);

        // b2 was loaded 2 frames before b3 so b2 is unpinned; setLimits(1, 800) shrinks immediately.
        cache.setLimits(1, 800);
        try testing.expect(cache.readyCount() == 1 and cache.totalBytes() == 800);
        try testing.expect(cache.mockStats().active_handles == 1 and cache.mockStats().release_count == 2);

        app.urls = &.{"https://ex/b3.png"};
        t.frame();
        try testing.expect(app.states[0] == .ready);
    }
}

test "virtualized ui.list two-frame pin safety, zero stationary thrash, scroll eviction, multi-pass rebuild, and transient cancel" {
    const gpa = testing.allocator;
    var cache = ImageCache.initMock(gpa, .{ .max_entries = 6 });
    var cache_alive = true;
    defer if (cache_alive) cache.deinit();

    const ListApp = struct {
        cache: *ImageCache,
        scroll_to: ?f32 = null,
        repass_once: bool = false,
        built_rows: usize = 0,
        ready_rows: usize = 0,

        pub fn build(s: *@This(), c: *ui.Context) void {
            s.built_rows = 0;
            s.ready_rows = 0;
            var rows = ui.list(c, .{ .count = 200, .row_height = 24, .overscan = 2, .scroll_to = s.scroll_to });
            s.scroll_to = null;
            while (rows.next()) |i| {
                s.built_rows += 1;
                ui.row(c, .{ .width = .fill, .height = .{ .px = 24 }, .align_items = .center });
                defer ui.end(c);
                const url = c.print("https://cdn.example/item-{d}.jpg", .{i});
                if (s.cache.image(c, url, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .fade_duration = 0 }) == .ready) {
                    s.ready_rows += 1;
                }
            }
            rows.end();
            if (s.repass_once) {
                s.repass_once = false;
                s.scroll_to = 72;
                c.changed = true;
            }
        }
    };

    const resolveAllPending = struct {
        fn run(gpa_alloc: std.mem.Allocator, ic_ptr: *ImageCache) !void {
            while (ic_ptr.mock.pending.items.len > 0) {
                const url = try gpa_alloc.dupe(u8, ic_ptr.mock.pending.items[0].url);
                defer gpa_alloc.free(url);
                try testing.expect(ic_ptr.mockResolve(url, .{ .width = 16, .height = 16, .byte_len = 256 }));
            }
        }
    }.run;

    var app: ListApp = .{ .cache = &cache };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&app, ListApp.build), .{ .width = 240, .height = 120 });
    defer t.deinit();

    // (a) Tight max_entries = 6 < ~8..10 visible+overscan rows: stationary frames never thrash.
    const top_rows = app.built_rows;
    try testing.expect(top_rows > cache.options.max_entries);
    try resolveAllPending(gpa, &cache);
    t.frame();
    try testing.expect(app.ready_rows == top_rows and cache.readyCount() >= top_rows);
    const reqs_at_top = cache.mockStats().request_count;
    for (0..5) |_| {
        t.frame();
        try testing.expectEqual(top_rows, app.ready_rows);
    }
    try testing.expect(cache.mockStats().request_count == reqs_at_top and cache.mockStats().release_count == 0);

    // (c) Same-frame multi-pass rebuild (c.changed = true on pass 0): pass 0 and pass 1 stay pinned.
    app.scroll_to = 0;
    t.frame();
    try resolveAllPending(gpa, &cache);
    const releases_before_repass = cache.mockStats().release_count;
    app.repass_once = true;
    t.frame();
    try testing.expectEqual(@as(u32, 2), t.ctx.stats.passes);
    try resolveAllPending(gpa, &cache);
    try testing.expectEqual(releases_before_repass, cache.mockStats().release_count);

    // (b) Scroll down through 60 rows over sequential frames (wheel scroll + scroll_to), resolving new rows.
    for (0..15) |_| {
        t.scroll(120, 60, -48);
        try resolveAllPending(gpa, &cache);
        try testing.expectEqual(cache.readyCount(), cache.mockStats().active_handles);
    }
    var step: usize = 16;
    while (step <= 30) : (step += 1) {
        app.scroll_to = @floatFromInt(step * 48);
        t.frame();
        try resolveAllPending(gpa, &cache);
        try testing.expectEqual(cache.readyCount(), cache.mockStats().active_handles);
    }
    try testing.expect(cache.mockStats().release_count >= 50);
    try testing.expect(cache.readyCount() <= @max(cache.options.max_entries, app.built_rows + 2));
    try testing.expectEqual(cache.readyCount(), cache.mockStats().active_handles);

    // When visible+overscan rows fit within max_entries (height = 24), readyCount drops to <= max_entries.
    t.resize(240, 24);
    t.frame();
    app.scroll_to = @floatFromInt(32 * 48);
    t.frame();
    try resolveAllPending(gpa, &cache);
    t.frame();
    cache.setLimits(cache.options.max_entries, cache.options.max_bytes);
    try testing.expect(cache.readyCount() <= cache.options.max_entries);
    try testing.expectEqual(cache.readyCount(), cache.mockStats().active_handles);
    t.resize(240, 120);

    // (d) Rapid scroll creating > max_transient (64) unpinned .loading entries cancels evicted requests.
    var jump_idx: usize = 0;
    while (jump_idx < 16) : (jump_idx += 1) {
        app.scroll_to = @floatFromInt((35 + jump_idx * 10) * 24);
        t.frame();
    }
    try testing.expect(cache.mockStats().cancel_count > 0 and cache.loadingCount() <= 64);
    try testing.expectEqual(cache.loadingCount(), cache.mockStats().pending_count);

    cache.deinit();
    cache_alive = false;
    try testing.expectEqual(@as(usize, 0), cache.mockStats().active_handles);
}

test "webgpuDeviceGeneration loss releases stale handles and transparently recovers visible rows" {
    const gpa = testing.allocator;
    var cache = ImageCache.initMock(gpa, .{});
    defer cache.deinit();

    const GenView = struct {
        cache: *ImageCache,
        urls: []const []const u8,
        states: [4]ic.State = @splat(.loading),
        pub fn build(s: *@This(), c: *ui.Context) void {
            for (s.urls, 0..) |u, i| s.states[i] = s.cache.get(c, u);
        }
    };
    var app: GenView = .{
        .cache = &cache,
        .urls = &.{ "https://ex/off-ready.png", "https://ex/vis-ready.png", "https://ex/vis-loading.png", "https://ex/vis-failed.png" },
    };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&app, GenView.build), .{ .width = 200, .height = 120 });
    defer t.deinit();

    try testing.expect(cache.mockResolve("https://ex/off-ready.png", .{ .width = 16, .height = 16, .byte_len = 1024 }));
    try testing.expect(cache.mockResolve("https://ex/vis-ready.png", .{ .width = 16, .height = 16, .byte_len = 1024 }));
    try testing.expect(cache.mockFail("https://ex/vis-failed.png"));
    try testing.expect(cache.readyCount() == 2 and cache.loadingCount() == 1 and cache.totalBytes() == 2048);
    try testing.expectEqual(@as(usize, 2), cache.mockStats().active_handles);

    app.urls = &.{ "https://ex/vis-ready.png", "https://ex/vis-loading.png", "https://ex/vis-failed.png" };
    cache.mockSetDeviceGeneration(2);
    t.frame();

    try testing.expect(cache.mockStats().active_handles == 0 and cache.totalBytes() == 0 and cache.readyCount() == 0);
    try testing.expectEqual(@as(usize, 3), cache.loadingCount());
    for (app.states[0..3]) |st| try testing.expect(st == .loading);
    try testing.expectEqual(@as(usize, 3), cache.mock.pending.items.len);
    for (cache.mock.pending.items) |p| try testing.expectEqual(@as(u32, 2), p.gen);

    for (app.urls) |u| try testing.expect(cache.mockResolve(u, .{ .width = 16, .height = 16, .byte_len = 512 }));
    t.frame();
    for (app.states[0..3]) |st| try testing.expect(st == .ready);
    try testing.expect(cache.readyCount() == 3 and cache.mockStats().active_handles == 3 and cache.totalBytes() == 1536);
}

test "stale status abort, invalidate cancellation, and late or unregistered orphan handle release" {
    const gpa = testing.allocator;
    var cache = ImageCache.initMock(gpa, .{});
    defer cache.deinit();

    const ViewState = struct {
        cache: *ImageCache,
        url: []const u8 = "https://ex/stale.png",
        state: ic.State = .loading,
        pub fn build(s: *@This(), c: *ui.Context) void {
            s.state = s.cache.get(c, s.url);
        }
    };
    var vs: ViewState = .{ .cache = &cache };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&vs, ViewState.build), .{ .width = 120, .height = 80 });
    defer t.deinit();

    // status = 3 (mockAbortStale) removes .loading cleanly (not .failed), re-requesting next frame.
    try testing.expectEqual(@as(usize, 1), cache.mockStats().request_count);
    try testing.expect(cache.mockAbortStale("https://ex/stale.png"));
    try testing.expectEqual(@as(usize, 0), cache.entryCount());
    t.frame();
    try testing.expect(vs.state == .loading and cache.mockStats().request_count == 2);

    // Direct status = 3 with a non-zero GPU handle releases the handle and still removes cleanly.
    const stale_req = cache.mock.pending.orderedRemove(0);
    gpa.free(stale_req.key);
    gpa.free(stale_req.url);
    const stale_hs = try cache.mock.allocHandle(gpa);
    host.handleComplete(cache.cache_id, stale_req.req_id, stale_hs.handle, stale_hs.serial, 16, 16, 1024, @backingInt(host.Status.stale));
    try testing.expect(cache.mockStats().active_handles == 0 and cache.entryCount() == 0);
    t.frame();
    try testing.expect(vs.state == .loading);
    try testing.expect(cache.mockResolve("https://ex/stale.png", .{ .width = 16, .height = 16 }));
    t.frame();
    try testing.expect(vs.state == .ready);

    // invalidate(url) while .loading cancels request; late onComplete for cancelled/unknown req_id releases handles.
    vs.url = "https://ex/inflight.png";
    t.frame();
    try testing.expect(vs.state == .loading);
    const cancelled_req_id = cache.mock.pending.items[0].req_id;
    cache.invalidate("https://ex/inflight.png");
    try testing.expect(cache.mockStats().cancel_count == 1 and cache.loadingCount() == 0);

    const handles_before = cache.mockStats().active_handles;
    const late_hs = try cache.mock.allocHandle(gpa);
    host.handleComplete(cache.cache_id, cancelled_req_id, late_hs.handle, late_hs.serial, 32, 32, 4096, @backingInt(host.Status.ok));
    try testing.expectEqual(handles_before, cache.mockStats().active_handles);

    const unknown_hs = try cache.mock.allocHandle(gpa);
    try testing.expect(!cache.onComplete(999_999, unknown_hs.handle, unknown_hs.serial, 32, 32, 4096, @backingInt(host.Status.ok)));
    try testing.expectEqual(handles_before, cache.mockStats().active_handles);

    // Late completion arriving for an unregistered/destroyed cache_id or cache_id == 0 releases orphan handles.
    var ephemeral = ImageCache.initMock(gpa, .{});
    const dead_cache_id = ephemeral.cache_id;
    ephemeral.deinit();
    const orphans_before = host.orphanReleaseCount();
    host.handleComplete(dead_cache_id, 1, 77, 4, 16, 16, 1024, @backingInt(host.Status.ok));
    host.handleComplete(0, 1, 78, 5, 16, 16, 1024, @backingInt(host.Status.ok));
    host.handleComplete(dead_cache_id, 1, 0, 0, 0, 0, 0, @backingInt(host.Status.failed));
    try testing.expectEqual(orphans_before + 2, host.orphanReleaseCount());

    // failedCount and retryFailed evict only failed entries while keeping ready entries intact.
    vs.url = "https://ex/fail-retry.png";
    t.frame();
    try testing.expect(cache.mockFail("https://ex/fail-retry.png"));
    t.frame();
    try testing.expect(vs.state == .failed and cache.failedCount() == 1 and cache.readyCount() == 1);
    cache.retryFailed();
    try testing.expect(cache.failedCount() == 0 and cache.readyCount() == 1);
    t.frame();
    try testing.expectEqual(ic.State.loading, vs.state);
    try testing.expect(cache.mockResolve("https://ex/fail-retry.png", .{ .width = 16, .height = 16 }));
    t.frame();
    try testing.expect(vs.state == .ready and cache.readyCount() == 2);
}

test "image widget placeholder, fade-in tween, rendered red pixels, warm mount, failed fallback, and fit modes" {
    const gpa = testing.allocator;
    var cache = ImageCache.initMock(gpa, .{});
    defer cache.deinit();

    const WidgetApp = struct {
        cache: *ImageCache,
        url: []const u8 = "https://ex/red.png",
        fit: ic.Fit = .cover,
        fade_duration: f32 = 0.16,
        show_warm_copy: bool = false,
        state: ic.State = .loading,
        warm_state: ic.State = .loading,

        pub fn build(s: *@This(), c: *ui.Context) void {
            ui.row(c, .{ .width = .fill, .height = .fill });
            defer ui.end(c);
            const opts: ic.WidgetOptions = .{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .radius = 0, .fit = s.fit, .fade_duration = s.fade_duration };
            s.state = s.cache.image(c, s.url, opts);
            if (s.show_warm_copy) {
                ui.key(c, "warm-second");
                s.warm_state = s.cache.image(c, s.url, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .radius = 0, .fit = .contain, .fade_duration = 0.16 });
            }
        }
    };

    var app: WidgetApp = .{ .cache = &cache };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&app, WidgetApp.build), .{ .width = 128, .height = 64, .scale = 1 });
    defer t.deinit();

    try testing.expect(app.state == .loading and !t.ctx.animating and t.ctx.frame_in == null);
    t.frame();
    try testing.expect(app.state == .loading and !t.ctx.animating and t.ctx.frame_in == null);

    // Resolve with bright red premultiplied BGRA { 0, 0, 255, 255 } -> wake, tween, settle, render pixel.
    var red_bgra: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |px_i| red_bgra[px_i * 4 ..][0..4].* = .{ 0, 0, 255, 255 };
    t.woken.store(false, .release);
    try testing.expect(cache.mockResolve("https://ex/red.png", .{ .width = 16, .height = 16, .bgra = &red_bgra }));
    try testing.expect(t.woken.load(.acquire));

    t.frame();
    try testing.expect(app.state == .ready and t.ctx.animating);
    const mid_tex = findFirstTexture(&t.ctx).?;
    try testing.expect(mid_tex.opacity > 0.0 and mid_tex.opacity < 1.0);

    t.settle(0.5);
    try testing.expect(!t.ctx.animating and t.ctx.frame_in == null);
    try testing.expectApproxEqAbs(@as(f32, 1.0), findFirstTexture(&t.ctx).?.opacity, 0.001);

    var red_pix = try t.render(gpa);
    defer red_pix.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &pixelAt(red_pix, 16, 16));

    // Mounting a second widget referencing an already-warm .ready URL renders at full opacity with !animating.
    app.show_warm_copy = true;
    t.frame();
    try testing.expect(app.warm_state == .ready and !t.ctx.animating);
    var tex_count: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.content == .texture) {
        tex_count += 1;
        try testing.expectApproxEqAbs(@as(f32, 1.0), n.content.texture.opacity, 0.001);
    };
    try testing.expectEqual(@as(usize, 2), tex_count);

    // .failed renders fallback box + "photo" icon with !animating; retry transitions back to .loading.
    app.show_warm_copy = false;
    app.url = "https://ex/broken.png";
    t.frame();
    try testing.expect(cache.mockFail("https://ex/broken.png"));
    t.frame();
    try testing.expect(app.state == .failed and !t.ctx.animating and countIconsNamed(&t.ctx, "photo") == 1);
    cache.retry("https://ex/red.png"); // warm .ready entry is untouched by retry()
    try testing.expectEqual(@as(usize, 1), cache.readyCount());
    cache.retry("https://ex/broken.png");
    t.frame();
    try testing.expect(app.state == .loading and !t.ctx.animating);

    // Exercise .cover, .contain, and .fill fit modes with non-square 32x16 texture in 32x32 box.
    var wide_bgra: [32 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..32) |x| {
        wide_bgra[(y * 32 + x) * 4 ..][0..4].* = if (x >= 8 and x < 24) .{ 0, 255, 0, 255 } else .{ 255, 0, 0, 255 };
    };
    app.url = "https://ex/wide.png";
    app.fade_duration = 0;
    app.fit = .cover;
    t.frame();
    try testing.expect(cache.mockResolve("https://ex/wide.png", .{ .width = 32, .height = 16, .bgra = &wide_bgra }));

    t.frame();
    const cover_node = findFirstTexture(&t.ctx).?;
    try testing.expect(cover_node.rect.w == 32 and cover_node.rect.h == 32);
    try testing.expectApproxEqAbs(@as(f32, 0.25), cover_node.uv[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), cover_node.uv[2], 0.001);
    var cover_pix = try t.render(gpa);
    defer cover_pix.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &pixelAt(cover_pix, 2, 16));
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &pixelAt(cover_pix, 16, 16));

    app.fit = .contain;
    t.frame();
    const contain_node = findFirstTexture(&t.ctx).?;
    try testing.expect(contain_node.rect.w == 32 and contain_node.rect.h == 16 and contain_node.rect.y == 8);
    var contain_pix = try t.render(gpa);
    defer contain_pix.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &pixelAt(contain_pix, 2, 16));
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &pixelAt(contain_pix, 16, 16));
    const top_bar = pixelAt(contain_pix, 16, 2);
    try testing.expect(!(top_bar[0] == 255 and top_bar[1] == 0) and !(top_bar[1] == 255 and top_bar[0] == 0));

    app.fit = .fill;
    t.frame();
    const fill_node = findFirstTexture(&t.ctx).?;
    try testing.expect(fill_node.rect.w == 32 and fill_node.rect.h == 32);
    try testing.expectApproxEqAbs(@as(f32, 0.0), fill_node.uv[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), fill_node.uv[2], 0.001);
    var fill_pix = try t.render(gpa);
    defer fill_pix.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &pixelAt(fill_pix, 2, 2));
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &pixelAt(fill_pix, 16, 16));
}

test "widget UI key stays sibling-scoped while cache_key controls global deduplication, and OOM rolls back cleanly" {
    const gpa = testing.allocator;

    // 1. Multiple list rows sharing `.key = "avatar"` fetch distinct URLs independently, while `.cache_key` deduplicates.
    {
        var cache = ImageCache.initMock(gpa, .{});
        defer cache.deinit();
        const RowView = struct {
            cache: *ImageCache,
            s0: ic.State = .loading,
            s1: ic.State = .loading,
            s2: ic.State = .loading,
            pub fn build(s: *@This(), c: *ui.Context) void {
                ui.key(c, "row-0");
                ui.row(c, .{});
                s.s0 = s.cache.image(c, "https://ex/u0.png", .{ .key = "avatar", .fade_duration = 0 });
                ui.end(c);
                ui.key(c, "row-1");
                ui.row(c, .{});
                s.s1 = s.cache.image(c, "https://ex/u1.png", .{ .key = "avatar", .fade_duration = 0 });
                ui.end(c);
                ui.key(c, "row-2");
                ui.row(c, .{});
                s.s2 = s.cache.image(c, "https://ex/u0.png?token=2", .{ .key = "avatar", .cache_key = "https://ex/u0.png", .fade_duration = 0 });
                ui.end(c);
            }
        };
        var app: RowView = .{ .cache = &cache };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&app, RowView.build), .{ .width = 128, .height = 128 });
        defer t.deinit();

        try testing.expectEqual(@as(usize, 2), cache.mockStats().request_count);
        try testing.expect(cache.mockResolve("https://ex/u0.png", .{ .width = 12, .height = 12 }));
        try testing.expect(cache.mockResolve("https://ex/u1.png", .{ .width = 24, .height = 24 }));
        t.frame();
        try testing.expect(app.s0 == .ready and app.s1 == .ready and app.s2 == .ready);
        try testing.expect(app.s0.ready.web_texture != app.s1.ready.web_texture);
        try testing.expectEqual(app.s0.ready.web_texture, app.s2.ready.web_texture);
    }

    // 2. Every allocation point inside `getWith` unwinds cleanly under OOM without leaks or stale map entries.
    var t_ctx: ui.Tester = undefined;
    const Dummy = struct {
        pub fn build(_: *@This(), _: *ui.Context) void {}
    };
    var dummy: Dummy = .{};
    try t_ctx.init(gpa, ui.View.init(&dummy, Dummy.build), .{ .width = 64, .height = 64 });
    defer t_ctx.deinit();

    for (0..8) |fail_idx| {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_idx });
        var cache = ImageCache.initMock(failing.allocator(), .{});
        defer cache.deinit();
        const st = cache.get(&t_ctx.ctx, "https://ex/oom.png");
        if (failing.has_induced_failure) {
            try testing.expect(st == .failed);
            try testing.expect(cache.entryCount() == 0 and cache.map.count() == 0 and cache.by_req.count() == 0);
        } else {
            try testing.expect(st == .loading and cache.entryCount() == 1);
            break;
        }
    }
}
