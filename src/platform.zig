//! What differs by operating system below nanoui's own code, chosen at
//! compile time: macOS (AppKit, CoreText, Metal), iOS (UIKit, likewise),
//! Linux (GTK, nanoui's own text, the CPU renderer), Android (its NDK,
//! likewise) and Windows (Win32, likewise).
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");

pub const os = builtin.os.tag;
const android = builtin.abi.isAndroid();
const has_platform = backend.has_platform;

const cf = struct {
    extern "c" fn CFRunLoopRunInMode(mode: *const anyopaque, seconds: f64, return_after: bool) i32;
    extern "c" const kCFRunLoopDefaultMode: *const anyopaque;
    extern "c" fn CFRunLoopStop(rl: *anyopaque) void;
    extern "c" fn CFRunLoopGetMain() *anyopaque;
};

/// Runs the event loop for `seconds`: replies, processes and timers get
/// handled (headless tests use it between frames).
pub fn runFor(seconds: f64) void {
    if (comptime !has_platform) return;
    switch (os) {
        .macos, .ios => _ = cf.CFRunLoopRunInMode(cf.kCFRunLoopDefaultMode, seconds, false),
        .linux => if (android) androidRunFor(seconds) else @import("linux/loop.zig").runFor(seconds),
        .windows => @import("windows/loop.zig").runFor(seconds),
        else => {},
    }
}

/// Runs the event loop for at most `seconds`, returning as soon as `flag`
/// is set (by another thread, which then calls `wakeMain`).
pub fn runUntil(seconds: f64, flag: *const std.atomic.Value(bool)) void {
    const clock = @import("ui/clock.zig");
    const end = clock.now() + seconds;
    while (!flag.load(.acquire)) {
        const left = end - clock.now();
        if (left <= 0) return;
        if (comptime !has_platform) {
            if (comptime os == .freestanding or os == .wasi) return;
            std.Io.sleep(std.Options.debug_io, .fromNanoseconds(@intFromFloat(@min(left, 0.005) * 1e9)), .awake) catch return;
            continue;
        }
        switch (os) {
            .macos, .ios => _ = cf.CFRunLoopRunInMode(cf.kCFRunLoopDefaultMode, left, true),
            // No wake-up of the loop here: it is looked at every 10 ms.
            else => runFor(@min(left, 0.01)),
        }
    }
}

/// From any thread: wakes the main thread's loop, so `runUntil` looks at
/// its flag.
pub fn wakeMain() void {
    if (comptime !has_platform) return;
    switch (os) {
        .macos, .ios => @import("objc.zig").dispatchMain(null, stopMainLoop),
        else => {},
    }
}

fn stopMainLoop(_: ?*anyopaque) callconv(.c) void {
    cf.CFRunLoopStop(cf.CFRunLoopGetMain());
}

/// Writes text to the system's clipboard.
pub fn clipboardWrite(text: []const u8) void {
    if (comptime !has_platform) return;
    switch (os) {
        .macos => @import("desktop.zig").clipboard.writeText(text),
        .ios => @import("ios/desktop.zig").clipboard.writeText(text),
        .linux => if (android) @import("android/desktop.zig").clipboard.writeText(text) else @import("linux/desktop.zig").clipboard.writeText(text),
        .windows => @import("windows/desktop.zig").clipboard.writeText(text),
        else => {},
    }
}

/// Android: the app's thread's loop for `seconds` (elsewhere, a sleep).
fn androidRunFor(seconds: f64) void {
    const activity = @import("android/activity.zig");
    const clock = @import("ui/clock.zig");
    const end = clock.now() + seconds;
    while (true) {
        const left = end - clock.now();
        if (left <= 0) return;
        if (!activity.onAppThread()) {
            const ns: u64 = @intFromFloat(left * 1e9);
            var ts: std.c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
            _ = std.c.nanosleep(&ts, &ts);
            return;
        }
        activity.beginWait();
        activity.poll(@intFromFloat(@ceil(left * 1000)));
    }
}
