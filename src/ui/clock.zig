//! A monotonic clock in seconds, for frame timing and animations.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");

const apple = struct {
    extern "c" fn CACurrentMediaTime() f64;
};

const win32 = struct {
    extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;
};

pub fn now() f64 {
    return switch (builtin.os.tag) {
        .freestanding => 0,
        .macos, .ios => if (backend.has_platform or backend.current == .metal)
            apple.CACurrentMediaTime()
        else if (builtin.link_libc)
            libcMonotonic()
        else
            0,
        .windows => {
            if (comptime backend.current == .none and !builtin.link_libc) return 0;
            var c: i64 = 0;
            var f: i64 = 1;
            _ = win32.QueryPerformanceCounter(&c);
            _ = win32.QueryPerformanceFrequency(&f);
            return @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(f));
        },
        .linux => if (builtin.link_libc) libcMonotonic() else {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
        },
        .wasi => if (builtin.link_libc) libcMonotonic() else {
            var ns: std.os.wasi.timestamp_t = 0;
            _ = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
            return @as(f64, @floatFromInt(ns)) * 1e-9;
        },
        else => if (builtin.link_libc) libcMonotonic() else 0,
    };
}

fn libcMonotonic() f64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
}
