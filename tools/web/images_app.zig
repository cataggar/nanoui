//! Browser image-cache test application compiled to `zig-out/web/images_test.wasm`.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const is_wasi = builtin.os.tag == .wasi;

const AppState = struct {
    cache: nanoui.web.ImageCache,
    mode: u32 = 0,
    pending_scroll_to: ?f32 = null,
    custom_url_buf: [256]u8 = undefined,
    custom_url_len: usize = 0,
    visible_ready: u32 = 0,
    visible_failed: u32 = 0,
    animating: bool = false,
    deinited: bool = false,

    fn deinit(s: *AppState) void {
        if (s.deinited) return;
        s.deinited = true;
        s.cache.deinit();
    }

    fn slot3Url(s: *const AppState) []const u8 {
        if (s.custom_url_len > 0) return s.custom_url_buf[0..s.custom_url_len];
        return "./test-images/missing-404.png";
    }

    fn recordState(s: *AppState, st: nanoui.web.ImageCache.State) void {
        switch (st) {
            .ready => s.visible_ready += 1,
            .failed => s.visible_failed += 1,
            .loading => {},
        }
    }

    fn view(s: *AppState, c: *ui.Context) void {
        s.visible_ready = 0;
        s.visible_failed = 0;
        if (s.mode == 1) {
            s.viewList(c);
        } else {
            s.viewSlots(c);
        }
        s.animating = c.animating;
    }

    fn viewSlots(s: *AppState, c: *ui.Context) void {
        ui.column(c, .{
            .width = .fill,
            .height = .fill,
            .padding = .all(16),
            .gap = 16,
            .background = .white,
        });
        defer ui.end(c);

        // Primary 4 slots at exact CSS pixel centers (48,48), (128,48), (208,48), (288,48).
        ui.row(c, .{ .gap = 16 });
        s.recordState(s.cache.image(c, "./test-images/solid-red.png", .{
            .width = .{ .px = 64 },
            .height = .{ .px = 64 },
            .radius = 0,
            .fit = .fill,
            .fade_duration = 0.08,
        }));
        s.recordState(s.cache.image(c, "./test-images/translucent-teal.png", .{
            .width = .{ .px = 64 },
            .height = .{ .px = 64 },
            .radius = 0,
            .fit = .fill,
            .fade_duration = 0.08,
        }));
        s.recordState(s.cache.image(c, "./test-images/oversized-blue.png", .{
            .width = .{ .px = 64 },
            .height = .{ .px = 64 },
            .radius = 0,
            .fit = .cover,
            .fade_duration = 0.08,
            .max_width = 64,
            .max_height = 64,
        }));
        s.recordState(s.cache.image(c, s.slot3Url(), .{
            .width = .{ .px = 64 },
            .height = .{ .px = 64 },
            .radius = 0,
            .fit = .fill,
            .fade_duration = 0.08,
        }));
        ui.end(c);

        // Duplicate Slot 0 in the same frame at center (48,128) to test per-frame deduplication.
        ui.row(c, .{ .gap = 16 });
        ui.key(c, "dup-slot-0");
        _ = s.cache.image(c, "./test-images/solid-red.png", .{
            .width = .{ .px = 64 },
            .height = .{ .px = 64 },
            .radius = 0,
            .fit = .fill,
            .fade_duration = 0.08,
        });
        ui.end(c);
    }

    fn viewList(s: *AppState, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .background = .white });
        defer ui.end(c);

        const scroll_target = s.pending_scroll_to;
        s.pending_scroll_to = null;
        var rows = ui.list(c, .{
            .count = 120,
            .row_height = 40,
            .gap = 4,
            .overscan = 2,
            .scroll_to = scroll_target,
        });
        while (rows.next()) |i| {
            ui.row(c, .{ .width = .fill, .height = .{ .px = 40 }, .align_items = .center, .gap = 8 });
            const url = c.print("./test-images/item-{d}.png", .{i});
            const st = s.cache.image(c, url, .{
                .width = .{ .px = 36 },
                .height = .{ .px = 36 },
                .radius = 6,
                .fade_duration = 0.05,
            });
            s.recordState(st);
            ui.textf(c, .{ .size = 13 }, "Item {d}", .{i});
            ui.end(c);
        }
        rows.end();
    }
};

var web_state: ?*AppState = null;

fn wakeWeb() void {
    if (comptime is_wasi) {
        if (nanoui.web.active) |surf| surf.requestFrame();
    }
}

export fn img_test_set_mode(mode: u32) void {
    if (web_state) |s| {
        s.mode = mode;
        wakeWeb();
    }
}

export fn img_test_scroll_to(y: f32) void {
    if (web_state) |s| {
        s.pending_scroll_to = y;
        wakeWeb();
    }
}

export fn img_test_set_custom_url(ptr: [*]const u8, len: usize) void {
    if (web_state) |s| {
        const n = @min(len, s.custom_url_buf.len);
        if (n > 0) @memcpy(s.custom_url_buf[0..n], ptr[0..n]);
        s.custom_url_len = n;
        wakeWeb();
    }
}

export fn img_test_ready_count() u32 {
    return if (web_state) |s| @intCast(s.cache.readyCount()) else 0;
}

export fn img_test_loading_count() u32 {
    return if (web_state) |s| @intCast(s.cache.loadingCount()) else 0;
}

export fn img_test_total_bytes() u32 {
    return if (web_state) |s| @intCast(@min(s.cache.totalBytes(), std.math.maxInt(u32))) else 0;
}

export fn img_test_visible_ready() u32 {
    return if (web_state) |s| s.visible_ready else 0;
}

export fn img_test_visible_failed() u32 {
    return if (web_state) |s| s.visible_failed else 0;
}

export fn img_test_animating() u32 {
    return if (web_state) |s| @intFromBool(s.animating) else 0;
}

export fn img_test_cache_generation() u32 {
    return if (web_state) |s| @truncate(s.cache.device_generation) else 0;
}

export fn img_test_deinit() void {
    if (web_state) |s| {
        s.deinit();
        web_state = null;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = if (comptime is_wasi) std.heap.wasm_allocator else init.gpa;
    var state: AppState = .{
        .cache = nanoui.web.ImageCache.init(gpa, .{
            .max_entries = 12,
            .max_bytes = 256 * 1024,
            .max_concurrent = 4,
        }),
    };
    defer state.deinit();
    if (comptime is_wasi) {
        web_state = &state;
        _ = nanoui.web.registerBundledFonts();
        _ = try nanoui.web.mount(.init(&state, AppState.view), .{
            .width = 420,
            .height = 300,
            .scale = 1,
            .theme = .light,
        });
        nanoui.web.run();
    }
    const app = try nanoui.App.create(init, .{ .name = "ImagesTest" });
    defer app.destroy();
    _ = try app.newWindow(.{
        .title = "ImagesTest",
        .width = 420,
        .height = 300,
        .content = .{ .view = .init(&state, AppState.view) },
    });
    try app.run();
}
