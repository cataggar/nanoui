pub const Timer = struct {
    pub fn stop(_: *Timer) void {}
};

pub fn every(_: u64, _: ?*anyopaque, _: *const fn (?*anyopaque) callconv(.c) void) ?*Timer {
    return null;
}
