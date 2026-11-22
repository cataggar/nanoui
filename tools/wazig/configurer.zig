//! Evaluates nanoui's build.zig under wasmtime and emits a topological JSON plan.
const std = @import("std");
const json = @import("json.zig");
const Allocator = std.mem.Allocator;
const Color = std.zig.Color;
const Io = std.Io;
const Step = std.Build.Step;
const assert = std.debug.assert;
const fatal = std.process.fatal;
const log = std.log;
const mem = std.mem;
const process = std.process;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const std_options: std.Options = .{
    .side_channels_mitigations = .none,
    .http_disable_tls = true,
};

pub fn main(init: process.Init.Minimal) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var threaded: std.Io.Threaded = .init(arena, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.args.toSlice(arena);
    var arg_i: usize = 1;

    const zig_exe = expectArgOrFatal(args, &arg_i, "--zig");
    const build_root_sub_path = expectArgOrFatal(args, &arg_i, "--build-root");
    const cache_root_sub_path = expectArgOrFatal(args, &arg_i, "--cache-root");
    const global_cache_root_sub_path = expectArgOrFatal(args, &arg_i, "--global-cache-root");
    const install_prefix_sub_path = expectArgOrFatal(args, &arg_i, "--prefix");

    var graph: std.Build.Graph = .{
        .io = io,
        .arena = arena,
        .environ_map = try init.environ.createMap(arena),
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(io, .{}),
        },
        .generated_files = .empty,
        .zig_exe = zig_exe,
        .wip_configuration = .init(arena),
    };
    assert(try graph.wip_configuration.addString("") == .empty);
    assert(try graph.wip_configuration.addString("root") == .root);

    const cwd: Io.Dir = .cwd();
    const build_root: std.Build.Cache.Path = if (mem.eql(u8, build_root_sub_path, ".")) .cwd() else .{
        .root_dir = .{
            .handle = try cwd.openDir(io, build_root_sub_path, .{}),
            .path = build_root_sub_path,
        },
    };

    const cache_dir = try cwd.createDirPathOpen(io, cache_root_sub_path, .{});
    _ = try cwd.createDirPathOpen(io, global_cache_root_sub_path, .{});

    const builder = try std.Build.create(&graph, build_root, dependencies.root_deps);

    var color: Color = .auto;
    var requested_steps: std.ArrayList([]const u8) = .empty;

    while (nextArg(args, &arg_i)) |arg| {
        if (mem.cutPrefix(u8, arg, "-D")) |option_contents| {
            if (option_contents.len == 0) fatal("expected option name after '-D'", .{});
            if (mem.findScalar(u8, option_contents, '=')) |name_end| {
                if (try builder.addUserInputOption(option_contents[0..name_end], option_contents[name_end + 1 ..]))
                    process.exit(1);
            } else {
                if (try builder.addUserInputFlag(option_contents))
                    process.exit(1);
            }
        } else if (mem.eql(u8, arg, "--step")) {
            try requested_steps.append(arena, nextArgOrFatal(args, &arg_i));
        } else if (mem.cutPrefix(u8, arg, "--color=")) |rest| {
            color = std.meta.stringToEnum(Color, rest) orelse
                fatal("expected --color=[auto|on|off]; found: {s}", .{arg});
        } else if (mem.eql(u8, arg, "--verbose")) {
            graph.verbose = true;
        } else if (mem.eql(u8, arg, "--search-prefix")) {
            try graph.search_prefixes.append(arena, nextArgOrFatal(args, &arg_i));
        } else {
            fatal("unrecognized argument: {s}", .{arg});
        }
    }

    const no_color = std.zig.EnvVar.NO_COLOR.isSet(&graph.environ_map);
    const clicolor_force = std.zig.EnvVar.CLICOLOR_FORCE.isSet(&graph.environ_map);
    graph.stderr_mode = switch (color) {
        .auto => try .detect(io, .stderr(), no_color, clicolor_force),
        .on => .escape_codes,
        .off => .no_color,
    };

    builder.runPackageScript(root);

    std.Build.PackageOptions.sort(&builder.user_input_options);
    for (builder.user_input_options.keys()) |name| {
        if (!builder.available_options_map.contains(name)) {
            log.err("invalid option: {q}", .{name});
            builder.invalid_user_input = true;
        }
    }
    if (builder.invalid_user_input) process.exit(1);

    var all_steps: std.array_hash_map.Auto(*Step, void) = .empty;
    for (builder.top_level_steps.values()) |tls| try all_steps.put(arena, &tls.step, {});
    var scan_idx: usize = 0;
    while (scan_idx < all_steps.count()) : (scan_idx += 1) {
        const step = all_steps.keys()[scan_idx];
        try createModuleDependenciesForStep(step);
        for (step.dependencies.items) |dep_step| try all_steps.put(arena, dep_step, {});
    }

    var ordered_steps: std.array_hash_map.Auto(*Step, void) = .empty;
    var visiting: std.array_hash_map.Auto(*Step, void) = .empty;
    if (requested_steps.items.len == 0) {
        try visitStep(arena, builder.default_step, &ordered_steps, &visiting);
    } else {
        for (requested_steps.items) |step_name| {
            const tls = builder.top_level_steps.get(step_name) orelse
                fatal("no step named {q}", .{step_name});
            try visitStep(arena, &tls.step, &ordered_steps, &visiting);
        }
    }

    const generated_paths = try arena.alloc([]const u8, graph.generated_files.items.len);
    @memset(generated_paths, "");

    var out_buf: std.Io.Writer.Allocating = .init(arena);
    const w = &out_buf.writer;
    try w.writeAll("{\n  \"steps\": [\n");
    var first_action = true;

    for (ordered_steps.keys(), 0..) |step, step_idx| {
        switch (step.tag) {
            .top_level => {},
            .options => {
                const so: *Step.Options = @fieldParentPtr("step", step);
                var digest: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(so.contents.items, &digest, .{});
                var hex: [Sha256.digest_length * 2]u8 = undefined;
                _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
                const sub_dir = try std.fs.path.join(arena, &.{ "o", &hex });
                try cache_dir.createDirPath(io, sub_dir);
                const sub_file = try std.fs.path.join(arena, &.{ sub_dir, "options.zig" });
                try cache_dir.writeFile(io, .{ .sub_path = sub_file, .data = so.contents.items });
                generated_paths[@backingInt(so.generated_file)] = try std.fs.path.join(arena, &.{ cache_root_sub_path, sub_file });
            },
            .write_file => {
                const wf: *Step.WriteFile = @fieldParentPtr("step", step);
                const sub_dir = try std.fmt.allocPrint(arena, "o/wf_{d}", .{step_idx});
                try cache_dir.createDirPath(io, sub_dir);
                const wc = &graph.wip_configuration;
                for (wf.embeds.items) |embed| {
                    const sub = wc.stringSlice(embed.sub_path);
                    const bytes = wc.string_bytes.items[embed.contents.index..][0..embed.contents.len];
                    const full = try std.fs.path.join(arena, &.{ sub_dir, sub });
                    if (std.fs.path.dirname(full)) |parent| try cache_dir.createDirPath(io, parent);
                    try cache_dir.writeFile(io, .{ .sub_path = full, .data = bytes });
                }
                for (wf.copies.items) |copy| {
                    const sub = wc.stringSlice(copy.sub_path);
                    const src = try json.resolveLazyPath(arena, copy.src_file, generated_paths);
                    const full = try std.fs.path.join(arena, &.{ sub_dir, sub });
                    if (std.fs.path.dirname(full)) |parent| try cache_dir.createDirPath(io, parent);
                    const data = try cwd.readFileAlloc(io, src, arena, .unlimited);
                    try cache_dir.writeFile(io, .{ .sub_path = full, .data = data });
                }
                generated_paths[@backingInt(wf.generated_directory)] = try std.fs.path.join(arena, &.{ cache_root_sub_path, sub_dir });
            },
            .compile => {
                const cs: *Step.Compile = @fieldParentPtr("step", step);
                const sub_dir = try std.fmt.allocPrint(arena, "o/bin_{d}_{s}", .{ step_idx, cs.name });
                try cache_dir.createDirPath(io, sub_dir);
                const rel_dir = try std.fs.path.join(arena, &.{ cache_root_sub_path, sub_dir });
                const out_path = try std.fs.path.join(arena, &.{ rel_dir, cs.out_filename });
                if (cs.generated_bin.unwrap()) |gb| generated_paths[@backingInt(gb)] = out_path;
                if (!first_action) try w.writeAll(",\n");
                first_action = false;
                try json.writeCompileStep(arena, w, step.name, cs, out_path, generated_paths, cache_root_sub_path, global_cache_root_sub_path, zig_exe);
            },
            .install_artifact => {
                const ia: *Step.InstallArtifact = @fieldParentPtr("step", step);
                if (ia.dest_dir) |dest_dir| if (ia.emitted_bin) |emitted_bin| {
                    const src_path = try json.resolveLazyPath(arena, emitted_bin, generated_paths);
                    const sub = ia.dest_sub_path orelse ia.artifact.out_filename;
                    const dest_path = try json.resolveInstallDir(arena, install_prefix_sub_path, dest_dir, sub);
                    if (!first_action) try w.writeAll(",\n");
                    first_action = false;
                    try json.writeInstallStep(w, "install_file", step.name, src_path, dest_path);
                };
            },
            .install_file => {
                const inf: *Step.InstallFile = @fieldParentPtr("step", step);
                const src_path = try json.resolveLazyPath(arena, inf.source, generated_paths);
                const dest_path = try json.resolveInstallDir(arena, install_prefix_sub_path, inf.dir, inf.dest_rel_path);
                if (!first_action) try w.writeAll(",\n");
                first_action = false;
                try json.writeInstallStep(w, "install_file", step.name, src_path, dest_path);
            },
            .install_dir => {
                const id: *Step.InstallDir = @fieldParentPtr("step", step);
                const src_path = try json.resolveLazyPath(arena, id.options.source_dir, generated_paths);
                const dest_path = try json.resolveInstallDir(arena, install_prefix_sub_path, id.options.install_dir, id.options.install_subdir);
                if (!first_action) try w.writeAll(",\n");
                first_action = false;
                try json.writeInstallStep(w, "install_dir", step.name, src_path, dest_path);
            },
            .run => {
                const run: *Step.Run = @fieldParentPtr("step", step);
                var step_buf: std.Io.Writer.Allocating = .init(arena);
                if (try json.writeRunStep(arena, io, cache_dir, &step_buf.writer, step_idx, step.name, run, cache_root_sub_path, generated_paths)) {
                    if (!first_action) try w.writeAll(",\n");
                    first_action = false;
                    try w.writeAll(step_buf.written());
                }
            },
            .fail => {
                const fail_step: *Step.Fail = @fieldParentPtr("step", step);
                if (!first_action) try w.writeAll(",\n");
                first_action = false;
                try json.writeFailStep(w, graph.wip_configuration.stringSlice(fail_step.error_msg));
            },
            else => {},
        }
    }

    try w.writeAll("\n  ]\n}\n");
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);
    try stdout_writer.interface.writeAll(out_buf.written());
    try stdout_writer.interface.flush();
}

fn visitStep(
    arena: Allocator,
    step: *Step,
    ordered: *std.array_hash_map.Auto(*Step, void),
    visiting: *std.array_hash_map.Auto(*Step, void),
) !void {
    if (ordered.contains(step) or visiting.contains(step)) return;
    try visiting.put(arena, step, {});
    for (step.dependencies.items) |dep| try visitStep(arena, dep, ordered, visiting);
    _ = visiting.swapRemove(step);
    try ordered.putNoClobber(arena, step, {});
}

fn createModuleDependenciesForStep(step: *Step) Allocator.Error!void {
    const cs = step.cast(Step.Compile) orelse return;
    if (cs.wit_path) |lp| lp.addStepDependencies(step);
    if (cs.wasi_adapter) |lp| lp.addStepDependencies(step);
    for (cs.root_module.getGraph().modules) |mod| {
        if (mod.root_source_file) |lp| lp.addStepDependencies(step);
        for (mod.include_dirs.items) |include_dir| switch (include_dir) {
            .path, .path_system, .path_after, .framework_path, .framework_path_system, .embed_path => |lp| lp.addStepDependencies(step),
            .other_step => |other| {
                other.getEmittedIncludeTree().addStepDependencies(step);
                step.dependOn(&other.step);
            },
            .config_header_step => |other| step.dependOn(&other.step),
        };
        for (mod.lib_paths.items) |lp| lp.addStepDependencies(step);
        for (mod.rpaths.items) |rpath| switch (rpath) {
            .lazy_path => |lp| lp.addStepDependencies(step),
            .special => {},
        };
        for (mod.link_objects.items) |link_object| switch (link_object) {
            .static_path, .assembly_file => |lp| lp.addStepDependencies(step),
            .other_step => |other| step.dependOn(&other.step),
            .system_lib => {},
            .c_source_file => |source| source.file.addStepDependencies(step),
            .c_source_files => |source_files| source_files.root.addStepDependencies(step),
            .win32_resource_file => |rc_source| {
                rc_source.file.addStepDependencies(step);
                for (rc_source.include_paths) |lp| lp.addStepDependencies(step);
            },
        };
    }
}

fn nextArg(args: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

fn nextArgOrFatal(args: []const [:0]const u8, idx: *usize) [:0]const u8 {
    return nextArg(args, idx) orelse fatal("expected argument after {q}", .{args[idx.* - 1]});
}

fn expectArgOrFatal(args: []const [:0]const u8, index_ptr: *usize, first: []const u8) []const u8 {
    const next_arg = nextArg(args, index_ptr) orelse fatal("missing {q} argument", .{first});
    if (!mem.eql(u8, first, next_arg)) fatal("expected {q} instead of {q}", .{ first, next_arg });
    return nextArg(args, index_ptr) orelse fatal("expected argument after {q}", .{first});
}
