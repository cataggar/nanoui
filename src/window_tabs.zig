const objc = @import("objc.zig");

fn WindowType(comptime Pointer: type) type {
    return @typeInfo(Pointer).pointer.child;
}

pub fn performClose(self: anytype) void {
    if (self.closed) return;
    const style = objc.msg(objc.NSUInteger, self.nswindow, "styleMask", .{});
    const titled_and_closable = style & 1 != 0 and style & 2 != 0;
    if (titled_and_closable and self.isVisible()) {
        objc.msg(void, self.nswindow, "performClose:", .{@as(?objc.Object, null)});
    } else self.close();
}

pub fn addTab(self: anytype, other: @TypeOf(self), after: bool) bool {
    if (self == other or self.closed or other.closed) return false;
    objc.msg(void, self.nswindow, "addTabbedWindow:ordered:", .{ other.nswindow, @as(objc.NSInteger, if (after) 1 else -1) });
    return true;
}

fn tabWindows(self: anytype) ?objc.Object {
    const group = objc.msg(?objc.Object, self.nswindow, "tabGroup", .{}) orelse return null;
    return objc.msg(?objc.Object, group, "windows", .{});
}

pub fn tabCount(self: anytype) usize {
    const windows = tabWindows(self) orelse return 1;
    const count = objc.msg(objc.NSUInteger, windows, "count", .{});
    return if (count == 0) 1 else count;
}

pub fn tabIndex(self: anytype) ?usize {
    const windows = tabWindows(self) orelse return null;
    const count = objc.msg(objc.NSUInteger, windows, "count", .{});
    for (0..count) |index| {
        const window = objc.msg(objc.Object, windows, "objectAtIndex:", .{index});
        if (window == self.nswindow) return index;
    }
    return null;
}

pub fn tabAt(self: anytype, index: usize) ?*WindowType(@TypeOf(self)) {
    const windows = tabWindows(self) orelse return null;
    const count = objc.msg(objc.NSUInteger, windows, "count", .{});
    if (index >= count) return null;
    const nswindow = objc.msg(objc.Object, windows, "objectAtIndex:", .{index});
    const delegate = objc.msg(?objc.Object, nswindow, "delegate", .{});
    if (delegate) |object| if (objc.getZig(WindowType(@TypeOf(self)), object)) |window| return window;
    for (self.app.windows.items) |window| if (window.nswindow == nswindow) return window;
    return null;
}

pub fn destinationIndex(current: usize, count: usize, delta: isize) usize {
    if (count == 0) return 0;
    if (delta < 0) {
        const amount: usize = @intCast(-(delta + 1));
        return current -| (amount + 1);
    }
    return @min(current +| @as(usize, @intCast(delta)), count - 1);
}

pub fn moveTab(self: anytype, delta: isize) bool {
    const current = tabIndex(self) orelse return false;
    const count = tabCount(self);
    const target = destinationIndex(current, count, delta);
    if (target == current) return false;
    const destination = tabAt(self, target) orelse return false;
    objc.msg(void, destination.nswindow, "addTabbedWindow:ordered:", .{ self.nswindow, @as(objc.NSInteger, if (target > current) 1 else -1) });
    return true;
}

test "tab movement clamps at both ends" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(usize, 0), destinationIndex(2, 5, -20));
    try testing.expectEqual(@as(usize, 1), destinationIndex(2, 5, -1));
    try testing.expectEqual(@as(usize, 3), destinationIndex(2, 5, 1));
    try testing.expectEqual(@as(usize, 4), destinationIndex(2, 5, 20));
    try testing.expectEqual(@as(usize, 0), destinationIndex(0, 0, 1));
}
