const std = @import("std");

pub const Timer = struct {
    ref: *anyopaque,
    ctx: ?*anyopaque,
    func: *const fn (?*anyopaque) callconv(.c) void,

    pub fn stop(self: *Timer) void {
        cf.CFRunLoopTimerInvalidate(self.ref);
        cf.CFRelease(self.ref);
        std.heap.c_allocator.destroy(self);
    }
};

pub fn every(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) ?*Timer {
    const timer = std.heap.c_allocator.create(Timer) catch return null;
    const seconds = @as(f64, @floatFromInt(@max(ms, 1))) / 1000.0;
    var timer_ctx: cf.Context = .{ .info = timer };
    const ref = cf.CFRunLoopTimerCreate(null, cf.CFAbsoluteTimeGetCurrent() + seconds, seconds, 0, 0, fire, &timer_ctx) orelse {
        std.heap.c_allocator.destroy(timer);
        return null;
    };
    timer.* = .{ .ref = ref, .ctx = ctx, .func = func };
    cf.CFRunLoopAddTimer(cf.CFRunLoopGetMain(), ref, cf.kCFRunLoopCommonModes);
    return timer;
}

fn fire(_: *anyopaque, info: ?*anyopaque) callconv(.c) void {
    const timer: *Timer = @ptrCast(@alignCast(info orelse return));
    const func = timer.func;
    const ctx = timer.ctx;
    func(ctx);
}

const cf = struct {
    const Context = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };

    extern "c" fn CFRunLoopTimerCreate(allocator: ?*anyopaque, fire_at: f64, interval: f64, flags: usize, order: isize, callout: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void, context: *Context) ?*anyopaque;
    extern "c" fn CFRunLoopAddTimer(loop: *anyopaque, timer: *anyopaque, mode: *anyopaque) void;
    extern "c" fn CFRunLoopTimerInvalidate(timer: *anyopaque) void;
    extern "c" fn CFRelease(ref: *anyopaque) void;
    extern "c" fn CFRunLoopGetMain() *anyopaque;
    extern "c" fn CFAbsoluteTimeGetCurrent() f64;
    extern "c" const kCFRunLoopCommonModes: *anyopaque;
};

test "a repeating common-modes timer stops cleanly" {
    const testing = std.testing;
    var count: usize = 0;
    const callback = struct {
        fn fire(ctx: ?*anyopaque) callconv(.c) void {
            const value: *usize = @ptrCast(@alignCast(ctx));
            value.* += 1;
        }
    }.fire;
    const timer = every(1, &count, callback) orelse return error.TimerCreateFailed;
    for (0..5) |_| @import("platform.zig").runFor(0.02);
    try testing.expect(count > 1);
    timer.stop();
    const stopped_at = count;
    @import("platform.zig").runFor(0.01);
    try testing.expectEqual(stopped_at, count);
}
