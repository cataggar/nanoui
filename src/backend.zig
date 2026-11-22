//! Compile-time backend selection (`-Dbackend=...`) and portable allocators.
//! `.auto` is full desktop/mobile/web platform mode; every other `Kind` is
//! standalone embed mode (`is_embed`) with zero windowing or IPC dependencies.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const build_options = @import("build_options");

pub const Kind = enum { auto, none, metal, d3d11, opengl, gles, webgpu };

const raw: []const u8 = if (@hasDecl(build_options, "backend")) build_options.backend else "auto";

pub const current: Kind = if (builtin.os.tag == .freestanding and std.mem.eql(u8, raw, "auto"))
    .none
else
    (std.meta.stringToEnum(Kind, raw) orelse @compileError("invalid build_options.backend: " ++ raw));

pub const is_embed: bool = current != .auto;
pub const has_platform: bool = current == .auto and builtin.os.tag != .freestanding;

const has_root_page = @hasDecl(root, "os") and @hasDecl(root.os, "heap") and @hasDecl(root.os.heap, "page_allocator");

pub const page_or_wasm_allocator: std.mem.Allocator = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else if (builtin.os.tag == .freestanding and !has_root_page)
    std.mem.Allocator.failing
else
    std.heap.page_allocator;

pub const default_allocator: std.mem.Allocator = if (builtin.link_libc)
    std.heap.c_allocator
else
    page_or_wasm_allocator;
