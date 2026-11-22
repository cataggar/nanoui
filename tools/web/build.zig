//! Browser and WASI build helpers for nanoui and downstream applications.
const std = @import("std");

const js_modules = [_][]const u8{
    "gpu.js",
    "gpu_timing.js",
    "webgl2.js",
    "webgl2_pass.js",
    "external.js",
    "wasi.js",
    "nanoui.js",
    "host.js",
    "input.js",
};

/// Upstream Zig 0.17's unpatched `-fno-llvm` Wasm backend has a `v128` layout
/// bug; `wazig` fixes it and advertises `"wazig"` in `zig_version_string`.
pub fn defaultSimd128(use_llvm: ?bool) bool {
    if (use_llvm == false and std.mem.indexOf(u8, @import("builtin").zig_version_string, "wazig") == null) {
        return false;
    }
    return true;
}

/// Target query for single-threaded `wasm32-wasi` with post-MVP features and optional `+simd128`.
pub fn wasmTargetQuery(enable_simd128: bool) std.Target.Query {
    return .{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_features_add = std.Target.wasm.featureSet(if (enable_simd128)
            &.{ .simd128, .bulk_memory, .nontrapping_fptoint, .sign_ext, .mutable_globals }
        else
            &.{ .bulk_memory, .nontrapping_fptoint, .sign_ext, .mutable_globals }),
        .cpu_features_sub = std.Target.wasm.featureSet(&.{.atomics}),
    };
}

pub fn resolveWasmTarget(b: *std.Build, use_llvm: ?bool) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(wasmTargetQuery(defaultSimd128(use_llvm)));
}

pub fn simd128Option(b: *std.Build, use_llvm: ?bool) bool {
    return b.option(bool, "simd128", "Enable WebAssembly +simd128 for wasm32-wasi builds") orelse defaultSimd128(use_llvm);
}

/// Upgrades a bare `-Dtarget=wasm32-wasi` to include `+simd128` (when enabled)
/// and `-atomics` while preserving any explicit `-Dcpu` model or feature overrides.
pub fn adjustTarget(b: *std.Build, target: std.Build.ResolvedTarget, enable_simd128: bool) std.Build.ResolvedTarget {
    if (target.result.cpu.arch == .wasm32 and
        target.result.os.tag == .wasi and
        target.query.cpu_model == .determined_by_arch_os and
        target.query.cpu_features_add.isEmpty() and
        target.query.cpu_features_sub.isEmpty())
    {
        return b.resolveTargetQuery(wasmTargetQuery(enable_simd128));
    }
    return target;
}

/// Installs a wasm32-wasi command and its browser ES modules side by side.
/// Pass the nanoui dependency's root so this works outside nanoui's tree:
/// `nanoui.web.install(b, exe, dependency.path("."))`.
/// Both the executable and nanoui modules must be single-threaded wasm32-wasi.
pub fn install(b: *std.Build, exe: *std.Build.Step.Compile, nanoui_root: std.Build.LazyPath) *std.Build.Step {
    const target = exe.root_module.resolved_target.?.result;
    if (target.cpu.arch != .wasm32 or target.os.tag != .wasi) @panic("web.install needs wasm32-wasi");
    exe.rdynamic = true;
    const output = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    for (js_modules) |name| {
        const source = nanoui_root.path(b, b.fmt("src/web/{s}", .{name}));
        output.step.dependOn(&b.addInstallFile(source, b.fmt("web/{s}", .{name})).step);
    }
    return &output.step;
}

pub fn addSteps(b: *std.Build, version: []const u8, use_llvm: ?bool, enable_simd128: bool) void {
    const target = b.resolveTargetQuery(wasmTargetQuery(enable_simd128));
    const web_optimize = parseOptimize(b.option([]const u8, "web-optimize", "Optimization mode for web-parity and web-demo (default: ReleaseSmall)"));
    const options = portableOptions(b, version);
    addWebCheck(b, target, options, use_llvm);
    addWebParity(b, target, options, web_optimize, use_llvm);
    addWebDemo(b, target, options, web_optimize, use_llvm);
    addWebBench(b, target, options, use_llvm);
}

fn parseOptimize(raw: ?[]const u8) std.builtin.OptimizeMode {
    const s = raw orelse return std.builtin.OptimizeMode.ReleaseSmall;
    if (std.mem.eql(u8, s, "Debug") or std.mem.eql(u8, s, "debug")) return std.builtin.OptimizeMode.Debug;
    if (std.mem.eql(u8, s, "ReleaseSafe") or std.mem.eql(u8, s, "safe")) return std.builtin.OptimizeMode.ReleaseSafe;
    if (std.mem.eql(u8, s, "ReleaseFast") or std.mem.eql(u8, s, "fast")) return std.builtin.OptimizeMode.ReleaseFast;
    if (std.mem.eql(u8, s, "ReleaseSmall") or std.mem.eql(u8, s, "small")) return std.builtin.OptimizeMode.ReleaseSmall;
    @panic("invalid -Dweb-optimize (expected Debug, ReleaseSafe, ReleaseFast, or ReleaseSmall)");
}

fn portableOptions(b: *std.Build, version: []const u8) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "portable", true);
    options.addOption(bool, "in_rt", false);
    options.addOption([]const u8, "version", version);
    return options;
}

fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) *std.Build.Module {
    const core = b.createModule(.{
        .root_source_file = b.path("src/nanoui.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .link_libc = true,
    });
    core.addOptions("build_options", options);
    return core;
}

fn addWebCheck(b: *std.Build, target: std.Build.ResolvedTarget, options: *std.Build.Step.Options, use_llvm: ?bool) void {
    const step = b.step("web-check", "Compile the single-threaded wasm32-wasi UI probe (Debug and ReleaseSmall)");
    const modes = [_]struct { mode: std.builtin.OptimizeMode, suffix: []const u8 }{
        .{ .mode = .Debug, .suffix = "debug" },
        .{ .mode = .ReleaseSmall, .suffix = "small" },
    };
    var previous: ?*std.Build.Step = null;
    for (modes) |entry| {
        const core = coreModule(b, target, entry.mode, options);
        const probe = b.addExecutable(.{
            .name = b.fmt("nanoui-web-check-{s}", .{entry.suffix}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/web/check.zig"),
                .target = target,
                .optimize = entry.mode,
                .single_threaded = true,
                .imports = &.{.{ .name = "nanoui", .module = core }},
            }),
            .use_llvm = use_llvm,
        });
        probe.entry = .disabled;
        probe.rdynamic = true;
        probe.wasi_exec_model = .reactor;
        if (previous) |prev| probe.step.dependOn(prev);
        previous = &probe.step;
        step.dependOn(&b.addInstallArtifact(probe, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
        const demo_root = b.createModule(.{
            .root_source_file = b.path("examples/counter/main.zig"),
            .target = target,
            .optimize = entry.mode,
            .single_threaded = true,
            .imports = &.{.{ .name = "nanoui", .module = core }},
        });
        const demo = b.addExecutable(.{ .name = b.fmt("counter-check-{s}", .{entry.suffix}), .root_module = demo_root, .use_llvm = use_llvm });
        demo.rdynamic = true;
        demo.step.dependOn(&probe.step);
        previous = &demo.step;
        step.dependOn(&demo.step);
        const parity_root = b.createModule(.{ .root_source_file = b.path("src/web_parity.zig"), .target = target, .optimize = entry.mode, .single_threaded = true, .link_libc = true });
        parity_root.addOptions("build_options", options);
        const parity = b.addExecutable(.{ .name = b.fmt("parity-check-{s}", .{entry.suffix}), .root_module = parity_root, .use_llvm = use_llvm });
        parity.entry = .disabled;
        parity.rdynamic = true;
        parity.wasi_exec_model = .reactor;
        parity.step.dependOn(&demo.step);
        previous = &parity.step;
        step.dependOn(&parity.step);
    }
}

fn addWebParity(b: *std.Build, target: std.Build.ResolvedTarget, options: *std.Build.Step.Options, optimize: std.builtin.OptimizeMode, use_llvm: ?bool) void {
    const step = b.step("web-parity", "Build the browser WebGPU/CPU parity reactor and JavaScript host");
    const root = b.createModule(.{
        .root_source_file = b.path("src/web_parity.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .link_libc = true,
    });
    root.addOptions("build_options", options);
    step.dependOn(&b.addInstallFile(b.path("tools/web/fixtures.js"), "web/fixtures.js").step);
    step.dependOn(&b.addInstallFile(b.path("tools/web/codecs.js"), "web/codecs.js").step);
    const exe = b.addExecutable(.{ .name = "nanoui-web-parity", .root_module = root, .use_llvm = use_llvm });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.wasi_exec_model = .reactor;
    step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    for (js_modules) |file| {
        step.dependOn(&b.addInstallFile(b.path(b.fmt("src/web/{s}", .{file})), b.fmt("web/{s}", .{file})).step);
    }
}

fn addWebDemo(b: *std.Build, target: std.Build.ResolvedTarget, options: *std.Build.Step.Options, optimize: std.builtin.OptimizeMode, use_llvm: ?bool) void {
    const step = b.step("web-demo", "Build the counter canvas demo");
    const core = coreModule(b, target, optimize, options);
    for ([_][]const u8{ "counter", "gallery" }) |name| {
        const root = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{.{ .name = "nanoui", .module = core }},
        });
        const exe = b.addExecutable(.{ .name = name, .root_module = root, .use_llvm = use_llvm });
        step.dependOn(install(b, exe, b.path(".")));
    }
    for ([_][]const u8{ "index.html", "worker.js" }) |file| {
        step.dependOn(&b.addInstallFile(b.path(b.fmt("src/web/{s}", .{file})), b.fmt("web/{s}", .{file})).step);
    }
}

fn addWebBench(b: *std.Build, target: std.Build.ResolvedTarget, options: *std.Build.Step.Options, use_llvm: ?bool) void {
    const step = b.step("web-bench", "Compile the headless wasm32-wasi UI benchmark (ReleaseFast and ReleaseSmall)");
    const modes = [_]struct { mode: std.builtin.OptimizeMode, suffix: []const u8 }{
        .{ .mode = .ReleaseFast, .suffix = "fast" },
        .{ .mode = .ReleaseSmall, .suffix = "small" },
    };
    var previous: ?*std.Build.Step = null;
    for (modes) |entry| {
        const core = coreModule(b, target, entry.mode, options);
        const root = b.createModule(.{
            .root_source_file = b.path("tools/web/bench.zig"),
            .target = target,
            .optimize = entry.mode,
            .single_threaded = true,
            .link_libc = true,
            .imports = &.{.{ .name = "nanoui", .module = core }},
        });
        root.addAnonymousImport("dejavu_regular", .{ .root_source_file = b.path("src/ui/web_fonts/DejaVuSans.ttf") });
        root.addAnonymousImport("dejavu_bold", .{ .root_source_file = b.path("src/ui/web_fonts/DejaVuSans-Bold.ttf") });
        const exe = b.addExecutable(.{
            .name = b.fmt("nanoui-web-bench-{s}", .{entry.suffix}),
            .root_module = root,
            .use_llvm = use_llvm,
        });
        if (previous) |prev| exe.step.dependOn(prev);
        previous = &exe.step;
        step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
        if (std.mem.eql(u8, entry.suffix, "fast")) {
            const run = b.addRunArtifact(exe);
            run.addPassthruArgs();
            b.step("run-web-bench", "Run the ReleaseFast headless wasm32-wasi UI benchmark").dependOn(&run.step);
        }
    }
}
