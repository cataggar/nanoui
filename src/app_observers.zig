const std = @import("std");
const objc = @import("objc.zig");

pub const AppearanceObserver = struct {
    gpa: std.mem.Allocator,
    object: objc.Object,
    app: objc.Object,
    ctx: ?*anyopaque,
    callback: *const fn (ctx: ?*anyopaque, dark: bool) void,

    pub fn create(gpa: std.mem.Allocator, app: objc.Object, ctx: ?*anyopaque, callback: *const fn (?*anyopaque, bool) void) !*AppearanceObserver {
        const self = try gpa.create(AppearanceObserver);
        errdefer gpa.destroy(self);
        const cls = objc.defineClass(.{
            .name = "NanoUIAppearanceObserver",
            .superclass = "NSObject",
            .methods = &.{
                .{ .name = "observeValueForKeyPath:ofObject:change:context:", .imp = &appearanceChanged, .types = "v@:@@@^v" },
            },
        });
        const object = objc.msg(objc.Object, cls, "new", .{});
        self.* = .{ .gpa = gpa, .object = object, .app = app, .ctx = ctx, .callback = callback };
        objc.setZig(object, self);
        objc.msg(void, app, "addObserver:forKeyPath:options:context:", .{ object, objc.nsString("effectiveAppearance"), @as(objc.NSUInteger, 0), @as(?*anyopaque, null) });
        return self;
    }

    pub fn stop(self: *AppearanceObserver) void {
        objc.msg(void, self.app, "removeObserver:forKeyPath:", .{ self.object, objc.nsString("effectiveAppearance") });
        objc.setZig(self.object, null);
        objc.release(self.object);
        self.gpa.destroy(self);
    }
};

fn appearanceChanged(object: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, _: objc.Object, _: ?*anyopaque) callconv(.c) void {
    const self = objc.getZig(AppearanceObserver, object) orelse return;
    self.callback(self.ctx, @import("desktop.zig").isDark());
}

pub const PowerObserver = struct {
    gpa: std.mem.Allocator,
    object: objc.Object,
    center: objc.Object,
    ctx: ?*anyopaque,
    on_sleep: ?*const fn (?*anyopaque) void,
    on_wake: ?*const fn (?*anyopaque) void,

    pub fn create(gpa: std.mem.Allocator, center: objc.Object, ctx: ?*anyopaque, on_sleep: ?*const fn (?*anyopaque) void, on_wake: ?*const fn (?*anyopaque) void) !*PowerObserver {
        const self = try gpa.create(PowerObserver);
        errdefer gpa.destroy(self);
        const cls = objc.defineClass(.{
            .name = "NanoUIPowerObserver",
            .superclass = "NSObject",
            .methods = &.{
                .{ .name = "nanouiWillSleep:", .imp = &willSleep, .types = "v@:@" },
                .{ .name = "nanouiDidWake:", .imp = &didWake, .types = "v@:@" },
            },
        });
        const object = objc.msg(objc.Object, cls, "new", .{});
        self.* = .{ .gpa = gpa, .object = object, .center = center, .ctx = ctx, .on_sleep = on_sleep, .on_wake = on_wake };
        objc.setZig(object, self);
        observePowerNotifications(center, object, on_sleep != null, on_wake != null);
        return self;
    }

    pub fn stop(self: *PowerObserver) void {
        objc.msg(void, self.center, "removeObserver:", .{self.object});
        objc.setZig(self.object, null);
        objc.release(self.object);
        self.gpa.destroy(self);
    }
};

pub fn observePowerNotifications(center: objc.Object, observer: objc.Object, sleep: bool, wake: bool) void {
    if (sleep) objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("nanouiWillSleep:"), objc.nsString("NSWorkspaceWillSleepNotification"), @as(?objc.Object, null) });
    if (wake) objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("nanouiDidWake:"), objc.nsString("NSWorkspaceDidWakeNotification"), @as(?objc.Object, null) });
}

fn willSleep(object: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(PowerObserver, object) orelse return;
    if (self.on_sleep) |callback| callback(self.ctx);
}

fn didWake(object: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(PowerObserver, object) orelse return;
    if (self.on_wake) |callback| callback(self.ctx);
}

test "power notifications dispatch from a local notification center" {
    const testing = std.testing;
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "new", .{});
    defer objc.release(center);
    var counts: [2]usize = @splat(0);
    const callbacks = struct {
        fn sleep(ctx: ?*anyopaque) void {
            const value: *[2]usize = @ptrCast(@alignCast(ctx));
            value[0] += 1;
        }
        fn wake(ctx: ?*anyopaque) void {
            const value: *[2]usize = @ptrCast(@alignCast(ctx));
            value[1] += 1;
        }
    };
    const observer = try PowerObserver.create(testing.allocator, center, &counts, callbacks.sleep, callbacks.wake);
    objc.msg(void, center, "postNotificationName:object:", .{ objc.nsString("NSWorkspaceWillSleepNotification"), @as(?objc.Object, null) });
    objc.msg(void, center, "postNotificationName:object:", .{ objc.nsString("NSWorkspaceDidWakeNotification"), @as(?objc.Object, null) });
    try testing.expectEqual([2]usize{ 1, 1 }, counts);
    observer.stop();
    objc.msg(void, center, "postNotificationName:object:", .{ objc.nsString("NSWorkspaceDidWakeNotification"), @as(?objc.Object, null) });
    try testing.expectEqual([2]usize{ 1, 1 }, counts);
}
