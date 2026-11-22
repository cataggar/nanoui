//! JSON plan serialization for nanoui's wazig build configurer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Step = std.Build.Step;
const mem = std.mem;

pub fn writeString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            try w.writeAll("\\u00");
            try w.printInt(c, 16, .lower, .{ .width = 2, .fill = '0' });
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeKv(w: *Io.Writer, prefix: []const u8, val: []const u8) !void {
    try w.writeAll(prefix);
    try writeString(w, val);
}

pub fn writeStringArray(w: *Io.Writer, items: []const []const u8) !void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(", ");
        try writeString(w, item);
    }
    try w.writeByte(']');
}

fn joinRootSub(arena: Allocator, root_str: []const u8, sub: []const u8) ![]const u8 {
    if (root_str.len == 0 or mem.eql(u8, root_str, ".")) return if (sub.len == 0) "." else sub;
    if (sub.len == 0) return root_str;
    return std.fs.path.join(arena, &.{ root_str, sub });
}

pub fn resolveLazyPath(arena: Allocator, lp: std.Build.LazyPath, generated_paths: []const []const u8) ![]const u8 {
    return switch (lp) {
        .src_path => |sp| joinRootSub(arena, try sp.owner.root.toString(arena), sp.sub_path),
        .dependency => |d| joinRootSub(arena, try d.dependency.builder.root.toString(arena), d.sub_path),
        .cwd_relative => |p| if (p.len == 0) "." else p,
        .relative => |r| if (r.sub_path.len == 0) "." else r.sub_path,
        .generated => |gen| blk: {
            var base = generated_paths[@backingInt(gen.index)];
            var up = gen.up;
            while (up > 0) : (up -= 1) base = std.fs.path.dirname(base) orelse ".";
            break :blk if (gen.sub_path.len == 0) base else try std.fs.path.join(arena, &.{ base, gen.sub_path });
        },
    };
}

pub fn resolveInstallDir(arena: Allocator, prefix: []const u8, dir: std.Build.InstallDir, rel: []const u8) ![]const u8 {
    const sub: []const u8 = switch (dir) {
        .prefix => "",
        .lib => "lib",
        .bin => "bin",
        .header => "include",
        .custom => |c| c,
    };
    return if (sub.len == 0) std.fs.path.join(arena, &.{ prefix, rel }) else std.fs.path.join(arena, &.{ prefix, sub, rel });
}

fn appendToggle(arena: Allocator, args: *std.ArrayList([]const u8), val: ?bool, yes: []const u8, no: []const u8) !void {
    if (val) |v| try args.append(arena, if (v) yes else no);
}

fn appendIncludeDir(arena: Allocator, inc: std.Build.Module.IncludeDir, args: *std.ArrayList([]const u8), gen: []const []const u8) !void {
    switch (inc) {
        .path => |lp| try args.appendSlice(arena, &.{ "-I", try resolveLazyPath(arena, lp, gen) }),
        .path_system => |lp| try args.appendSlice(arena, &.{ "-isystem", try resolveLazyPath(arena, lp, gen) }),
        .path_after => |lp| try args.appendSlice(arena, &.{ "-irafter", try resolveLazyPath(arena, lp, gen) }),
        .framework_path => |lp| try args.appendSlice(arena, &.{ "-F", try resolveLazyPath(arena, lp, gen) }),
        .framework_path_system => |lp| try args.appendSlice(arena, &.{ "-iframework", try resolveLazyPath(arena, lp, gen) }),
        .embed_path => |lp| try args.appendSlice(arena, &.{ "--embed-dir", try resolveLazyPath(arena, lp, gen) }),
        .other_step => |cs| if (cs.installed_headers_include_tree) |wf| {
            try args.appendSlice(arena, &.{ "-I", try resolveLazyPath(arena, wf.getDirectory(), gen) });
        },
        .config_header_step => {},
    }
}

pub fn writeCompileStep(arena: Allocator, w: *Io.Writer, step_name: []const u8, cs: *Step.Compile, out_path: []const u8, generated_paths: []const []const u8, cache_root: []const u8, global_cache_root: []const u8, zig_exe: []const u8) !void {
    var zig_args: std.ArrayList([]const u8) = .empty;
    try zig_args.append(arena, switch (cs.kind) {
        .lib => "build-lib",
        .exe => "build-exe",
        .obj => "build-obj",
        .@"test" => "test",
        .test_obj => "test-obj",
    });
    if (cs.kind == .@"test") try zig_args.append(arena, "--test-no-exec");
    if (cs.kind == .lib) if (cs.linkage) |lm| try zig_args.append(arena, if (lm == .dynamic) "-dynamic" else "-static");

    const is_wazigl = mem.endsWith(u8, zig_exe, "wazigl") or mem.endsWith(u8, zig_exe, "wazigl.wasm");
    const is_wazig = !is_wazigl and mem.indexOf(u8, zig_exe, "wazig") != null;
    const use_llvm = if (is_wazig) false else if (cs.use_llvm) |u| u else true;
    try zig_args.appendSlice(arena, &.{ if (use_llvm) "-fllvm" else "-fno-llvm", try std.fmt.allocPrint(arena, "-femit-bin={s}", .{out_path}), "--name", cs.name });
    if (cs.test_runner) |tr| try zig_args.appendSlice(arena, &.{ "--test-runner", try resolveLazyPath(arena, tr.path, generated_paths) });
    for (cs.filters) |f| try zig_args.appendSlice(arena, &.{ "--test-filter", f });

    switch (cs.entry) {
        .default => {},
        .disabled => try zig_args.append(arena, "-fno-entry"),
        .enabled => try zig_args.append(arena, "-fentry"),
        .symbol_name => |sym| try zig_args.append(arena, try std.fmt.allocPrint(arena, "-fentry={s}", .{sym})),
    }
    if (cs.linker_script) |ls| try zig_args.appendSlice(arena, &.{ "--script", try resolveLazyPath(arena, ls, generated_paths) });
    for (cs.force_undefined_symbols.keys()) |sym| try zig_args.appendSlice(arena, &.{ "--force_undefined", sym });
    if (cs.stack_size) |ss| try zig_args.appendSlice(arena, &.{ "--stack", try std.fmt.allocPrint(arena, "{d}", .{ss}) });
    if (cs.rdynamic) try zig_args.append(arena, "-rdynamic");
    if (cs.import_memory) try zig_args.append(arena, "--import-memory");
    if (cs.export_memory) try zig_args.append(arena, "--export-memory");
    if (cs.import_symbols) try zig_args.append(arena, "--import-symbols");
    if (cs.import_table) try zig_args.append(arena, "--import-table");
    if (cs.export_table) try zig_args.append(arena, "--export-table");
    if (cs.growable_table) try zig_args.append(arena, "--growable-table");
    if (cs.shared_memory) try zig_args.append(arena, "--shared-memory");
    if (cs.initial_memory) |m| try zig_args.append(arena, try std.fmt.allocPrint(arena, "--initial-memory={d}", .{m}));
    if (cs.max_memory) |m| try zig_args.append(arena, try std.fmt.allocPrint(arena, "--max-memory={d}", .{m}));
    if (cs.global_base) |gb| try zig_args.append(arena, try std.fmt.allocPrint(arena, "--global-base={d}", .{gb}));
    if (cs.wasi_exec_model) |wem| try zig_args.append(arena, try std.fmt.allocPrint(arena, "-mexec-model={t}", .{wem}));

    const mod_graph = cs.root_module.getGraph();
    var mod_to_cli: std.array_hash_map.Auto(*std.Build.Module, []const u8) = .empty;
    var used_names: std.array_hash_map.String(void) = .empty;
    for ([_][]const u8{ "root", "std", "builtin" }) |r| try used_names.put(arena, r, {});
    try mod_to_cli.putNoClobber(arena, mod_graph.modules[0], "root");
    for (mod_graph.modules[1..], mod_graph.names[1..]) |m, orig_name| {
        var candidate = orig_name;
        var suffix: usize = 0;
        while ((try used_names.getOrPut(arena, candidate)).found_existing) : (suffix += 1)
            candidate = try std.fmt.allocPrint(arena, "{s}{d}", .{ orig_name, suffix });
        try mod_to_cli.putNoClobber(arena, m, candidate);
    }

    var is_linking_libc = false;
    var is_linking_libcpp = false;
    for (mod_graph.modules) |m| {
        const cli_name = mod_to_cli.get(m).?;
        if (m.link_libc == true) is_linking_libc = true;
        if (m.link_libcpp == true) is_linking_libcpp = true;
        for (m.link_objects.items) |lo| switch (lo) {
            .static_path, .assembly_file => |lp| try zig_args.append(arena, try resolveLazyPath(arena, lp, generated_paths)),
            .other_step => |other| if (other.generated_bin.unwrap()) |gb| try zig_args.append(arena, generated_paths[@backingInt(gb)]),
            .system_lib => |sl| try zig_args.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{sl.name})),
            else => {},
        };
        for (m.lib_paths.items) |lp| try zig_args.appendSlice(arena, &.{ "-L", try resolveLazyPath(arena, lp, generated_paths) });
        try appendToggle(arena, &zig_args, m.strip, "-fstrip", "-fno-strip");
        if (m.unwind_tables) |uwt| try zig_args.append(arena, switch (uwt) {
            .sync => "-funwind-tables",
            .async => "-fasync-unwind-tables",
            .none => "-fno-unwind-tables",
        });
        try appendToggle(arena, &zig_args, m.single_threaded, "-fsingle-threaded", "-fno-single-threaded");
        try appendToggle(arena, &zig_args, m.stack_check, "-fstack-check", "-fno-stack-check");
        try appendToggle(arena, &zig_args, m.stack_protector, "-fstack-protector", "-fno-stack-protector");
        try appendToggle(arena, &zig_args, m.omit_frame_pointer, "-fomit-frame-pointer", "-fno-omit-frame-pointer");
        try appendToggle(arena, &zig_args, m.error_tracing, "-ferror-tracing", "-fno-error-tracing");
        if (m.optimize) |opt| try zig_args.append(arena, switch (opt) {
            .debug => "-ODebug",
            .safe => "-OReleaseSafe",
            .fast => "-OReleaseFast",
            .small => "-OReleaseSmall",
        });
        if (m.resolved_target) |rt| try zig_args.appendSlice(arena, &.{
            "-target", try rt.result.zigTriple(arena), "-mcpu", try std.zig.serializeCpuAlloc(arena, rt.result.cpu),
        });
        for (m.export_symbol_names) |sym| try zig_args.append(arena, try std.fmt.allocPrint(arena, "--export={s}", .{sym}));
        for (m.include_dirs.items) |inc| try appendIncludeDir(arena, inc, &zig_args, generated_paths);
        for (m.c_macros.items) |cm| try zig_args.append(arena, cm);
        for (m.import_table.keys(), m.import_table.values()) |imp_name, imp_mod| {
            const imp_cli = mod_to_cli.get(imp_mod).?;
            try zig_args.appendSlice(arena, &.{
                "--dep", if (mem.eql(u8, imp_cli, imp_name)) imp_cli else try std.fmt.allocPrint(arena, "{s}={s}", .{ imp_name, imp_cli }),
            });
        }
        if (m.root_source_file) |lp| {
            try zig_args.append(arena, try std.fmt.allocPrint(arena, "-M{s}={s}", .{ cli_name, try resolveLazyPath(arena, lp, generated_paths) }));
        } else try zig_args.append(arena, try std.fmt.allocPrint(arena, "-M{s}", .{cli_name}));
    }

    const root_rt = cs.root_module.resolved_target.?;
    if (root_rt.result.os.tag != .freestanding) {
        if (is_linking_libcpp) try zig_args.append(arena, "-lc++");
        if (is_linking_libc) try zig_args.append(arena, "-lc");
    }
    try zig_args.appendSlice(arena, &.{ "--cache-dir", cache_root, "--global-cache-dir", global_cache_root });

    try writeKv(w, "    {\"kind\": \"compile\", \"name\": ", step_name);
    try writeKv(w, ", \"compile_kind\": ", @tagName(cs.kind));
    try writeKv(w, ", \"out_filename\": ", cs.out_filename);
    try writeKv(w, ", \"output\": ", out_path);
    try writeKv(w, ", \"target\": ", try root_rt.result.zigTriple(arena));
    try writeKv(w, ", \"mcpu\": ", try std.zig.serializeCpuAlloc(arena, root_rt.result.cpu));
    try w.writeAll(", \"args\": ");
    try writeStringArray(w, zig_args.items);
    try w.writeByte('}');
}

pub fn writeInstallStep(w: *Io.Writer, kind: []const u8, name: []const u8, src: []const u8, dest: []const u8) !void {
    try writeKv(w, "    {\"kind\": ", kind);
    try writeKv(w, ", \"name\": ", name);
    try writeKv(w, ", \"src\": ", src);
    try writeKv(w, ", \"dest\": ", dest);
    try w.writeByte('}');
}

pub fn writeFailStep(w: *Io.Writer, msg: []const u8) !void {
    try writeKv(w, "    {\"kind\": \"fail\", \"message\": ", msg);
    try w.writeByte('}');
}

fn writeCheckObj(w: *Io.Writer, kind: []const u8, val: []const u8) !void {
    try writeKv(w, "{\"kind\": ", kind);
    try writeKv(w, ", \"value\": ", val);
    try w.writeByte('}');
}

pub fn writeRunStep(arena: Allocator, io: Io, cache_dir: Io.Dir, w: *Io.Writer, step_idx: usize, step_name: []const u8, run: *Step.Run, cache_root: []const u8, generated_paths: [][]const u8) !bool {
    var run_args: std.ArrayList([]const u8) = .empty;
    var has_passthru = false;
    const sub_dir = try std.fmt.allocPrint(arena, "o/run_{d}", .{step_idx});
    const out_dir = try std.fs.path.join(arena, &.{ cache_root, sub_dir });

    for (run.argv.items) |arg| switch (arg) {
        .artifact => |pa| if (pa.artifact.generated_bin.unwrap()) |gb| {
            try run_args.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ pa.prefix, generated_paths[@backingInt(gb)], pa.suffix }));
        },
        .lazy_path, .decorated_directory => |lp| {
            try run_args.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ lp.prefix, try resolveLazyPath(arena, lp.lazy_path, generated_paths), lp.suffix }));
        },
        .bytes => |b| try run_args.append(arena, b),
        .output_file, .output_file_dep => |out| {
            try cache_dir.createDirPath(io, sub_dir);
            const p = try std.fs.path.join(arena, &.{ out_dir, out.basename });
            generated_paths[@backingInt(out.generated_file)] = p;
            try run_args.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ out.prefix, p, out.suffix }));
        },
        .output_directory => |out| {
            try cache_dir.createDirPath(io, try std.fs.path.join(arena, &.{ sub_dir, out.basename }));
            const p = try std.fs.path.join(arena, &.{ out_dir, out.basename });
            generated_paths[@backingInt(out.generated_file)] = p;
            try run_args.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ out.prefix, p, out.suffix }));
        },
        .passthru => has_passthru = true,
        else => {},
    };
    if (run_args.items.len == 0) return false;

    const is_wasm = if (run.producer) |p| p.rootModuleTarget().cpu.arch.isWasm() else mem.endsWith(u8, run_args.items[0], ".wasm");
    const uses_threads = if (run.producer) |p| p.shared_memory or std.Target.wasm.featureSetHas(p.rootModuleTarget().cpu.features, .atomics) else false;

    try writeKv(w, "    {\"kind\": \"run\", \"name\": ", step_name);
    try w.print(", \"is_wasm\": {s}, \"threads\": {s}, \"passthru\": {s}", .{ if (is_wasm) "true" else "false", if (uses_threads) "true" else "false", if (has_passthru) "true" else "false" });
    if (run.cwd) |run_cwd| try writeKv(w, ", \"cwd\": ", try resolveLazyPath(arena, run_cwd, generated_paths));
    if (run.captured_stdout) |cap| {
        try cache_dir.createDirPath(io, sub_dir);
        const p = try std.fs.path.join(arena, &.{ out_dir, cap.basename });
        generated_paths[@backingInt(cap.generated_file)] = p;
        try writeKv(w, ", \"capture_stdout\": ", p);
    }
    if (run.stdio == .check) {
        try w.writeAll(", \"checks\": [");
        for (run.stdio.check.items, 0..) |chk, i| {
            if (i != 0) try w.writeAll(", ");
            switch (chk) {
                .expect_stdout_exact => |s| try writeCheckObj(w, "stdout_exact", s),
                .expect_stdout_match => |s| try writeCheckObj(w, "stdout_match", s),
                .expect_stderr_exact => |s| try writeCheckObj(w, "stderr_exact", s),
                .expect_stderr_match => |s| try writeCheckObj(w, "stderr_match", s),
                .expect_term => |t| if (t == .exited) try w.print("{{\"kind\": \"exit_code\", \"code\": {d}}}", .{t.exited}) else try w.writeAll("{\"kind\": \"noop\"}"),
                else => try w.writeAll("{\"kind\": \"noop\"}"),
            }
        }
        try w.writeByte(']');
    }
    try w.writeAll(", \"args\": ");
    try writeStringArray(w, run_args.items);
    try w.writeByte('}');
    return true;
}
