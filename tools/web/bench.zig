//! Headless WASI benchmark exercising nanoui's portable UI core (layout, paint,
//! TrueType shaping/rasterization, motion, virtual list, and CPU rasterizer).
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Scene = enum { boxes, text, scroll, list, dashboard, motion };

const Config = struct {
    width: f32 = 800,
    height: f32 = 600,
    scale: f32 = 1.0,
    frames: usize = 20,
    warmup: usize = 4,
    raster: bool = true,
    json: bool = false,
    scenes: []const Scene = std.enums.values(Scene),
};

const SceneStats = struct {
    scene: []const u8,
    frames: usize,
    instances: usize,
    total_ms: f64,
    total_p95_ms: f64,
    ui_ms: f64,
    ui_p95_ms: f64,
    build_ms: f64,
    build_p95_ms: f64,
    layout_ms: f64,
    layout_p95_ms: f64,
    paint_ms: f64,
    paint_p95_ms: f64,
    raster_ms: f64,
    raster_p95_ms: f64,
    pixel_hash: u64,
};

const State = struct {
    scene: Scene,
    frame: usize = 0,
    time: f32 = 0,
    fn view(s: *State, c: *ui.Context) void {
        switch (s.scene) {
            .boxes => boxes(s, c),
            .text => textScene(s, c),
            .scroll => scrollScene(s, c),
            .list => listScene(s, c),
            .dashboard => dashboard(s, c),
            .motion => motionScene(s, c),
        }
    }
};

fn boxes(s: *State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(8), .gap = 4 });
    defer ui.end(c);
    for (0..20) |r| {
        ui.row(c, .{ .gap = 4 });
        defer ui.end(c);
        for (0..25) |col| {
            const i: f32 = @floatFromInt(r * 25 + col);
            _ = c.leaf(.{ .width = .{ .px = 26 }, .height = .{ .px = 22 }, .radius = 6, .background = hsl(@mod(s.time * 60 + i * 3.5, 360)), .shadow = .{ .color = .{ .a = 0.2 }, .blur = 4, .y = 2 }, .offset = .{ .y = 5 * @sin(s.time * 3 + i * 0.12) } }, .none, null);
        }
    }
}

fn textScene(s: *State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 6 });
    defer ui.end(c);
    ui.textf(c, .{ .size = 13, .wrap = true }, "Frame {d}: portable TrueType shaping, kerning, greedy wrapping, and glyph coverage atlas reuse on WebAssembly.", .{s.frame});
    for (0..15) |r| {
        ui.row(c, .{ .gap = 4 });
        defer ui.end(c);
        for (0..16) |col| {
            ui.column(c, .{ .width = .{ .px = 44 } });
            defer ui.end(c);
            ui.textf(c, .{ .size = 12, .weight = if ((r + col) % 4 == 0) .bold else .regular }, "{d}", .{(s.frame * 7 + (r * 16 + col) * 13) % 10000});
        }
    }
}

fn scrollScene(s: *State, c: *ui.Context) void {
    const row_h: f32 = 26;
    const rows = 600;
    ui.column(c, .{ .width = .fill, .height = .fill, .clip = true });
    defer ui.end(c);
    ui.column(c, .{ .width = .fill, .offset = .{ .y = -@mod(s.time * 480, row_h * rows - 560) } });
    defer ui.end(c);
    for (0..rows) |i| {
        ui.row(c, .{ .width = .fill, .height = .{ .px = row_h }, .padding = .xy(12, 0), .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.textf(c, .{ .size = 13 }, "Row {d} - clipped scrolling flex item", .{i});
        ui.spacer(c);
        ui.textf(c, .{ .size = 12 }, "{d}", .{(i * 7 + s.frame) % 100});
    }
}

fn listScene(s: *State, c: *ui.Context) void {
    const rows = 50_000;
    const row = (s.frame * 5) % (rows - 40);
    var it = ui.list(c, .{ .count = rows, .row_height = 28, .scroll_to = @as(f32, @floatFromInt(row)) * 28 });
    while (it.next()) |i| {
        ui.row(c, .{ .width = .fill, .height = .{ .px = 28 }, .padding = .xy(12, 0), .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.textf(c, .{ .size = 13 }, "Virtual row {d} - uniform list", .{i});
        ui.spacer(c);
        ui.textf(c, .{ .size = 12, .weight = .bold }, "#{x:0>4}", .{i});
    }
    it.end();
}

fn dashboard(s: *State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12 });
    defer ui.end(c);
    ui.heading(c, "Runtime Telemetry");
    for (0..3) |r| {
        ui.row(c, .{ .gap = 12 });
        defer ui.end(c);
        for (0..4) |col| {
            const i = r * 4 + col;
            const v = 0.5 + 0.5 * @sin(s.time * 2 + @as(f32, @floatFromInt(i)));
            ui.column(c, .{ .width = .{ .px = 182 }, .padding = .all(12), .gap = 8, .radius = 10, .background = .white, .shadow = .{ .color = .{ .a = 0.12 }, .blur = 12, .y = 4 } });
            defer ui.end(c);
            ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "Metric {d}", .{i});
            ui.textf(c, .{ .size = 24, .weight = .bold }, "{d}", .{@as(u32, @intFromFloat(v * 1000))});
            ui.progress(c, v, .fill);
            ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "frame {d}", .{s.frame});
        }
    }
}

fn motionScene(s: *State, c: *ui.Context) void {
    const pulse = [_]ui.motion.Target{ .{ .scale = 0.92, .opacity = 0.7 }, .{ .scale = 1.06, .opacity = 1.0 } };
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12), .gap = 8 });
    defer ui.end(c);
    if ((s.frame / 4) % 2 == 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 24 }, .radius = 6, .background = .hex(0x0a84ff) }, .none, "banner");
    for (0..6) |r| {
        ui.keyInt(c, 1000 + r);
        ui.row(c, .{ .gap = 8, .settle_y = .{ .response = 0.25, .damping = 0.85 } });
        defer ui.end(c);
        for (0..8) |col| {
            const n = r * 8 + col;
            const fi: f32 = @floatFromInt(n);
            ui.keyInt(c, n);
            const f = if (col == 0) ui.motion.keyframes(c, .{ .values = &pulse, .duration = 0.4, .repeat = null, .yoyo = true }) else ui.motion.frame(c, .{
                .target = .{ .y = 6 * @sin(s.time * 4 + fi * 0.2), .background = hsl(@mod(s.time * 50 + fi * 7, 360)) },
                .transition = if (n % 2 == 0) .{ .spring = .{} } else .{ .tween = .{ .duration = 0.16, .ease = .ease_out } },
            });
            const card = ui.div(c).w(84).h(48).p(8).rounded(8).bg(c.theme.surface).motion(f);
            ui.textf(c, .{ .size = 11, .weight = .bold }, "M{d}", .{n});
            card.end();
        }
    }
}

fn hsl(h: f32) ui.Color {
    const f = struct {
        fn channel(n: f32, hh: f32) f32 {
            const kk = @mod(n + hh / 30, 12);
            return 0.55 - 0.315 * @max(-1, @min(@min(kk - 3, 9 - kk), 1));
        }
    }.channel;
    return .{ .r = f(0, h), .g = f(8, h), .b = f(4, h) };
}

fn nowMs(io: std.Io) f64 {
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds)) / 1_000_000.0;
}

const Dist = struct { med: f64, p95: f64 };

fn statsOf(xs: []f64) Dist {
    if (xs.len == 0) return .{ .med = 0, .p95 = 0 };
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return .{
        .med = xs[xs.len / 2],
        .p95 = xs[((xs.len - 1) * 95) / 100],
    };
}

fn runScene(io: std.Io, gpa: std.mem.Allocator, cfg: Config, scene: Scene) !SceneStats {
    var state: State = .{ .scene = scene };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, State.view), .{ .width = cfg.width, .height = cfg.height, .scale = cfg.scale });
    defer t.deinit();
    t.dt = 1.0 / 60.0;
    var cv: ui.PixelCanvas = .{};
    defer cv.deinit(gpa);
    var samples: [6][]f64 = undefined;
    for (&samples) |*s| s.* = try gpa.alloc(f64, cfg.frames);
    defer for (samples) |s| gpa.free(s);

    for (0..cfg.warmup + cfg.frames) |i| {
        state.frame = i + 1;
        state.time = @as(f32, @floatFromInt(i + 1)) * t.dt;
        t.time = state.time;
        const t0 = nowMs(io);
        t.frame();
        const t1 = nowMs(io);
        if (cfg.raster) cv.draw(gpa, .{ .instances = t.instances.items, .text = &t.text, .clear = t.theme.background, .size = t.size, .scale = t.scale, .textures = t.ctx.textures.items });
        const t2 = nowMs(io);
        if (i >= cfg.warmup) {
            const k = i - cfg.warmup;
            samples[0][k] = t2 - t0;
            samples[1][k] = t1 - t0;
            samples[2][k] = t.ctx.stats.build_ms;
            samples[3][k] = t.ctx.stats.layout_ms;
            samples[4][k] = t.ctx.stats.paint_ms;
            samples[5][k] = if (cfg.raster) t2 - t1 else 0;
        }
    }
    const d0 = statsOf(samples[0]);
    const d1 = statsOf(samples[1]);
    const d2 = statsOf(samples[2]);
    const d3 = statsOf(samples[3]);
    const d4 = statsOf(samples[4]);
    const d5 = statsOf(samples[5]);
    return .{
        .scene = @tagName(scene),
        .frames = cfg.frames,
        .instances = t.instances.items.len,
        .total_ms = d0.med,
        .total_p95_ms = d0.p95,
        .ui_ms = d1.med,
        .ui_p95_ms = d1.p95,
        .build_ms = d2.med,
        .build_p95_ms = d2.p95,
        .layout_ms = d3.med,
        .layout_p95_ms = d3.p95,
        .paint_ms = d4.med,
        .paint_p95_ms = d4.p95,
        .raster_ms = d5.med,
        .raster_p95_ms = d5.p95,
        .pixel_hash = if (cfg.raster) std.hash.Fnv1a_64.hash(cv.bytes) else 0,
    };
}

fn parseConfig(init: std.process.Init) !Config {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var cfg: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) continue;
        if (std.mem.eql(u8, arg, "--no-raster")) cfg.raster = false else if (std.mem.eql(u8, arg, "--json")) cfg.json = true else if (optVal(args, &i, "--scale")) |v| cfg.scale = try std.fmt.parseFloat(f32, v) else if (optVal(args, &i, "--width")) |v| cfg.width = try std.fmt.parseFloat(f32, v) else if (optVal(args, &i, "--height")) |v| cfg.height = try std.fmt.parseFloat(f32, v) else if (optVal(args, &i, "--frames")) |v| cfg.frames = @max(1, try std.fmt.parseInt(usize, v, 10)) else if (optVal(args, &i, "--warmup")) |v| cfg.warmup = try std.fmt.parseInt(usize, v, 10) else if (optVal(args, &i, "--scene")) |v| {
            var list: std.ArrayList(Scene) = .empty;
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |name| try list.append(arena, std.meta.stringToEnum(Scene, name) orelse return error.UnknownScene);
            cfg.scenes = list.items;
        } else return error.InvalidArgument;
    }
    return cfg;
}

fn optVal(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const a = args[i.*];
    if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') return a[name.len + 1 ..];
    if (!std.mem.eql(u8, a, name) or i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

pub fn main(init: std.process.Init) !void {
    _ = ui.registerFont(@embedFile("dejavu_regular"));
    _ = ui.registerFont(@embedFile("dejavu_bold"));
    const cfg = try parseConfig(init);
    const gpa = if (@import("builtin").os.tag == .wasi) std.heap.wasm_allocator else init.gpa;
    const results = try init.arena.allocator().alloc(SceneStats, cfg.scenes.len);
    for (cfg.scenes, 0..) |scene, idx| results[idx] = try runScene(init.io, gpa, cfg, scene);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &w.interface;
    if (cfg.json) {
        const simd128 = comptime (@import("builtin").cpu.arch == .wasm32 and std.Target.wasm.featureSetHas(@import("builtin").cpu.features, .simd128));
        try out.print("{f}\n", .{std.json.fmt(.{ .width = cfg.width, .height = cfg.height, .scale = cfg.scale, .raster = cfg.raster, .simd128 = simd128, .scenes = results }, .{})});
    } else {
        try out.print("nanoui web-bench ({d:.0}x{d:.0} @{d:.1}x, {d} frames, {d} warmup, raster={s})\n", .{ cfg.width, cfg.height, cfg.scale, cfg.frames, cfg.warmup, if (cfg.raster) "on" else "off" });
        try out.print("{s:<10} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>6} {s:>16}\n", .{ "scene", "total", "ui", "build", "layout", "paint", "raster", "inst", "fnv1a64" });
        for (results) |r| try out.print("{s:<10} {d:>7.2}ms {d:>7.2}ms {d:>7.2}ms {d:>7.2}ms {d:>7.2}ms {d:>7.2}ms {d:>6} {x:0>16}\n", .{ r.scene, r.total_ms, r.ui_ms, r.build_ms, r.layout_ms, r.paint_ms, r.raster_ms, r.instances, r.pixel_hash });
    }
    try out.flush();
}
