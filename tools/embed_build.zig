//! Standalone zero-dependency embeddable UI build helpers and freestanding/WASI verification steps.
const std = @import("std");
const web = @import("web/build.zig");

/// Target query for single-threaded `wasm32-freestanding` with post-MVP features and optional `+simd128`.
pub fn wasmFreestandingQuery(enable_simd128: bool) std.Target.Query {
    return .{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(if (enable_simd128)
            &.{ .simd128, .bulk_memory, .nontrapping_fptoint, .sign_ext, .mutable_globals }
        else
            &.{ .bulk_memory, .nontrapping_fptoint, .sign_ext, .mutable_globals }),
        .cpu_features_sub = std.Target.wasm.featureSet(&.{.atomics}),
    };
}

/// Upgrades a bare `-Dtarget=wasm32-freestanding` to include `+simd128` (when enabled)
/// and `-atomics` while preserving any explicit `-Dcpu` model or feature overrides.
pub fn adjustTarget(b: *std.Build, target: std.Build.ResolvedTarget, enable_simd128: bool) std.Build.ResolvedTarget {
    if (target.result.cpu.arch == .wasm32 and
        target.result.os.tag == .freestanding and
        target.query.cpu_model == .determined_by_arch_os and
        target.query.cpu_features_add.isEmpty() and
        target.query.cpu_features_sub.isEmpty())
    {
        return b.resolveTargetQuery(wasmFreestandingQuery(enable_simd128));
    }
    return target;
}

pub fn embedOptions(b: *std.Build, version: []const u8) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "portable", true);
    options.addOption(bool, "in_rt", false);
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "backend", "none");
    return options;
}

pub fn createEmbedModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options, link_libc: ?bool) *std.Build.Module {
    const os = target.result.os.tag;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/nanoui.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = if (os == .wasi or os == .freestanding) true else null,
        .link_libc = link_libc,
    });
    mod.addOptions("build_options", options);
    return mod;
}

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nanoui: *std.Build.Module,
    is_embed: bool,
    version: []const u8,
    use_llvm: ?bool,
    new_linker: ?bool,
    enable_simd128: bool,
    filters: []const []const u8,
) void {
    const options = embedOptions(b, version);
    const embed_mod = createEmbedModule(b, target, optimize, options, null);
    const exported = if (is_embed) nanoui else embed_mod;
    b.modules.put(b.graph.arena, b.graph.dupeString("embed"), exported) catch @panic("OOM");
    b.modules.put(b.graph.arena, b.graph.dupeString("ui"), exported) catch @panic("OOM");

    const os = target.result.os.tag;
    if (os != .freestanding and os != .wasi and !target.result.abi.isAndroid() and os != .ios) {
        const exe = b.addExecutable(.{
            .name = "embedded",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/embedded/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nanoui", .module = embed_mod }},
            }),
            .use_llvm = use_llvm,
        });
        exe.use_new_linker = new_linker;
        if (is_embed) b.installArtifact(exe);
        b.step("embedded", "Build the zero-dependency headless embedded UI example").dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step("run-embedded", "Run the headless embedded UI example").dependOn(&run.step);
    }

    addTestEmbed(b, optimize, options, use_llvm, new_linker, enable_simd128, filters);
}

pub fn addFreestandingCheck(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, nanoui: *std.Build.Module, use_llvm: ?bool, enable_simd128: bool) void {
    const root = b.createModule(.{
        .root_source_file = b.path("tools/embed_probe.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .link_libc = false,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    if (target.result.cpu.arch.isWasm()) {
        const probe = b.addExecutable(.{ .name = "nanoui-embed-probe", .root_module = root, .use_llvm = use_llvm });
        probe.entry = .disabled;
        probe.rdynamic = true;
        const check = addWasmImportCheck(b, probe.getEmittedBin(), enable_simd128);
        step.dependOn(&check.step);
        b.getInstallStep().dependOn(&check.step);
        const test_bin = b.addInstallArtifact(probe, .{ .dest_sub_path = "nanoui-embed-probe.wasm" });
        b.step("test-bin", "Install the freestanding probe as zig-out/bin/nanoui-embed-probe.wasm").dependOn(&test_bin.step);
    } else {
        const obj = b.addObject(.{ .name = "nanoui-embed-probe", .root_module = root, .use_llvm = use_llvm });
        _ = obj.getEmittedBin();
        step.dependOn(&obj.step);
        b.getInstallStep().dependOn(&obj.step);
    }
}

fn addTestEmbed(b: *std.Build, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options, use_llvm: ?bool, new_linker: ?bool, enable_simd128: bool, filters: []const []const u8) void {
    const step = b.step("test-embed", "Test standalone zero-dependency embed mode and freestanding/WASI builds");
    const host = web.adjustTarget(b, b.graph.host, enable_simd128);

    const host_mod = createEmbedModule(b, host, optimize, options, null);
    const host_tests = b.addTest(.{ .root_module = host_mod, .use_llvm = use_llvm, .filters = filters });
    host_tests.use_new_linker = new_linker;
    step.dependOn(&b.addRunArtifact(host_tests).step);

    const wasm_check_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/embed_wasm_check.zig"),
        .target = host,
        .single_threaded = if (host.result.os.tag == .wasi) true else null,
    }) });
    step.dependOn(&b.addRunArtifact(wasm_check_tests).step);

    const freestanding_target = b.resolveTargetQuery(wasmFreestandingQuery(enable_simd128));
    const freestanding_nanoui = createEmbedModule(b, freestanding_target, optimize, options, false);
    const freestanding_probe = b.addExecutable(.{
        .name = "nanoui-embed-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_probe.zig"),
            .target = freestanding_target,
            .optimize = optimize,
            .single_threaded = true,
            .link_libc = false,
            .imports = &.{.{ .name = "nanoui", .module = freestanding_nanoui }},
        }),
        .use_llvm = use_llvm,
    });
    freestanding_probe.entry = .disabled;
    freestanding_probe.rdynamic = true;
    freestanding_probe.step.dependOn(&host_tests.step);
    const check_freestanding = addWasmImportCheck(b, freestanding_probe.getEmittedBin(), enable_simd128);
    step.dependOn(&check_freestanding.step);

    const wasi_target = b.resolveTargetQuery(web.wasmTargetQuery(enable_simd128));
    const wasi_nanoui = createEmbedModule(b, wasi_target, optimize, options, null);
    const wasi_probe = b.addExecutable(.{
        .name = "nanoui-embed-wasi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_probe.zig"),
            .target = wasi_target,
            .optimize = optimize,
            .single_threaded = true,
            .link_libc = null,
            .imports = &.{.{ .name = "nanoui", .module = wasi_nanoui }},
        }),
        .use_llvm = use_llvm,
    });
    wasi_probe.entry = .disabled;
    wasi_probe.wasi_exec_model = .reactor;
    wasi_probe.rdynamic = true;
    wasi_probe.step.dependOn(&freestanding_probe.step);
    _ = wasi_probe.getEmittedBin();
    step.dependOn(&wasi_probe.step);
}

fn addWasmImportCheck(b: *std.Build, wasm_bin: std.Build.LazyPath, enable_simd128: bool) *std.Build.Step.Run {
    const host = web.adjustTarget(b, b.graph.host, enable_simd128);
    const checker = b.addExecutable(.{
        .name = "embed-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_wasm_check.zig"),
            .target = host,
            .single_threaded = if (host.result.os.tag == .wasi) true else null,
            .link_libc = if (host.result.os.tag == .wasi) true else null,
        }),
    });
    const run = b.addRunArtifact(checker);
    run.addFileArg(wasm_bin);
    run.addArg("nanoui_embed_probe");
    return run;
}
