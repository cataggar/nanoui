fn WindowType(comptime Pointer: type) type {
    return @typeInfo(Pointer).pointer.child;
}

pub fn performClose(self: anytype) void {
    self.close();
}

pub fn addTab(_: anytype, _: anytype, _: bool) bool {
    return false;
}

pub fn tabCount(_: anytype) usize {
    return 1;
}

pub fn tabIndex(_: anytype) ?usize {
    return null;
}

pub fn tabAt(self: anytype, _: usize) ?*WindowType(@TypeOf(self)) {
    return null;
}

pub fn moveTab(_: anytype, _: isize) bool {
    return false;
}
