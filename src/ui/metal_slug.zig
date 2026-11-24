//! Vector glyph table (`slug_store.Store`) on the GPU for Metal (`MTLPixelFormatR32Uint`).
const std = @import("std");
const objc = @import("../objc.zig");
const metal = @import("metal.zig");
const slug_store = @import("slug_store.zig");

pub const r32_uint: objc.NSUInteger = 53; // MTLPixelFormatR32Uint
const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };

pub const SlugGpu = struct {
    texture: ?objc.Object = null,
    fallback: ?objc.Object = null,
    height: u32 = 0,
    used_words: u32 = 0,
    generation: u64 = std.math.maxInt(u64),
    resets: u64 = std.math.maxInt(u64),

    /// Always returns a valid `MTLPixelFormatR32Uint` texture for `[[texture(4)]]`.
    pub fn bind(self: *SlugGpu, device: objc.Object) objc.Object {
        if (self.texture) |t| return t;
        if (self.fallback) |f| return f;
        const pool = objc.Pool.push();
        defer pool.pop();
        const f = makeTexture(device, 1, 1);
        const zero: u32 = 0;
        uploadRows(f, 0, 1, 1, (&zero)[0..1]);
        self.fallback = f;
        return f;
    }

    pub fn deinit(self: *SlugGpu) void {
        if (self.texture) |t| objc.release(t);
        if (self.fallback) |f| objc.release(f);
        self.* = .{};
    }
};

fn makeTexture(device: objc.Object, w: u32, h: u32) objc.Object {
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        r32_uint, @as(objc.NSUInteger, w), @as(objc.NSUInteger, h), objc.NO,
    });
    objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1)});
    return objc.msg(objc.Object, device, "newTextureWithDescriptor:", .{desc});
}

fn uploadRows(tex: objc.Object, y: u32, row_count: u32, width: u32, words: []const u32) void {
    const offset = @as(usize, y) * @as(usize, width);
    objc.msg(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
        Region{ .x = 0, .y = y, .z = 0, .w = width, .h = row_count, .d = 1 },
        @as(objc.NSUInteger, 0),
        @as(*const anyopaque, &words[offset]),
        @as(objc.NSUInteger, width) * 4,
    });
}

pub fn syncSlug(renderer: *metal.Renderer, store: *const slug_store.Store) void {
    const s = &renderer.slug_gpu;
    const w: u32 = slug_store.tex_width;
    const h = store.tex_height;
    if (h == 0 or store.words.len < @as(usize, w) * @as(usize, h)) return;
    if (s.generation == store.generation and s.height == h and s.resets == store.resets) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const active_rows = @min(h, @max(@as(u32, 1), (store.used_words + w - 1) / w));
    if (s.texture == null or s.height != h or s.resets != store.resets or store.used_words < s.used_words) {
        if (s.texture) |old| {
            renderer.waitIdle();
            objc.release(old);
        }
        s.texture = makeTexture(renderer.device, w, h);
        uploadRows(s.texture.?, 0, active_rows, w, store.words);
    } else {
        const start_row = @min(active_rows, s.used_words / w);
        if (active_rows > start_row) {
            uploadRows(s.texture.?, start_row, active_rows - start_row, w, store.words);
        }
    }
    s.height = h;
    s.used_words = store.used_words;
    s.generation = store.generation;
    s.resets = store.resets;
}
