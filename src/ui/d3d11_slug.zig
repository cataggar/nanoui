//! Vector glyph table (`slug_store.Store`) on the GPU for Direct3D 11 (`DXGI_FORMAT_R32_UINT`).
const std = @import("std");
const raster = @import("raster.zig");
const slug_store = @import("slug_store.zig");
const api = @import("d3d11_glue.zig");
const Com = api.Com;

pub const r32_uint: u32 = 42; // DXGI_FORMAT_R32_UINT

const D3DBox = extern struct { left: u32, top: u32, front: u32, right: u32, bottom: u32, back: u32 };

pub const Slug = struct {
    slug_tex: ?*Com = null,
    slug_srv: ?*Com = null,
    slug_fallback_tex: ?*Com = null,
    slug_fallback_srv: ?*Com = null,
    slug_height: u32 = 0,
    slug_used: u32 = 0,
    slug_resets: u64 = std.math.maxInt(u64),
    slug_generation: u64 = std.math.maxInt(u64),

    pub fn initFallback(s: *Slug, device: *Com, context: *Com) void {
        if (s.slug_fallback_srv != null) return;
        const tex = api.texture2D(device, r32_uint, 1, 1, api.bind_shader_resource) orelse return;
        const zero: [4]u8 = .{ 0, 0, 0, 0 };
        context.slot(*const fn (*Com, *Com, u32, ?*const anyopaque, [*]const u8, u32, u32) callconv(.winapi) void, api.UpdateSubresource)(context, tex, 0, null, &zero, 4, 0);
        const srv = api.textureSrv(device, tex) orelse {
            tex.release();
            return;
        };
        s.slug_fallback_tex = tex;
        s.slug_fallback_srv = srv;
    }

    /// Always returns a valid `Texture2D<uint>` SRV for `t6`.
    pub fn view(s: *Slug, device: *Com, context: *Com) ?*Com {
        if (s.slug_srv) |v| return v;
        s.initFallback(device, context);
        return s.slug_fallback_srv;
    }

    pub fn sync(s: *Slug, device: *Com, context: *Com, mask: raster.Mask) void {
        s.initFallback(device, context);
        const w: u32 = slug_store.tex_width;
        const h = mask.slug_height;
        if (h == 0 or mask.slug_words.len < @as(usize, w) * @as(usize, h)) return;
        if (mask.slug_generation == s.slug_generation and h == s.slug_height and s.slug_srv != null) return;
        const used: u32 = if (mask.slug_used > 0) @min(mask.slug_used, h * w) else h * w;
        const active_rows = @min(h, @max(@as(u32, 1), (used + w - 1) / w));
        var full_upload = false;
        if (s.slug_tex == null or h != s.slug_height) {
            if (s.slug_srv) |v| v.release();
            s.slug_srv = null;
            if (s.slug_tex) |t| t.release();
            s.slug_tex = api.texture2D(device, r32_uint, w, h, api.bind_shader_resource);
            s.slug_height = if (s.slug_tex != null) h else 0;
            if (s.slug_tex) |t| s.slug_srv = api.textureSrv(device, t);
            full_upload = true;
        } else if (mask.slug_resets != s.slug_resets or used < s.slug_used) {
            full_upload = true;
        }
        if (s.slug_tex) |t| {
            const start_row: u32 = if (full_upload) 0 else @min(active_rows, s.slug_used / w);
            if (active_rows > start_row) {
                const box: D3DBox = .{ .left = 0, .top = start_row, .front = 0, .right = w, .bottom = active_rows, .back = 1 };
                const bytes = std.mem.sliceAsBytes(mask.slug_words[@as(usize, start_row) * w .. @as(usize, active_rows) * w]);
                context.slot(*const fn (*Com, *Com, u32, ?*const anyopaque, [*]const u8, u32, u32) callconv(.winapi) void, api.UpdateSubresource)(context, t, 0, &box, bytes.ptr, w * 4, 0);
            }
            s.slug_used = used;
            s.slug_resets = mask.slug_resets;
            s.slug_generation = mask.slug_generation;
        }
    }

    pub fn deinit(s: *Slug) void {
        if (s.slug_srv) |v| v.release();
        if (s.slug_tex) |t| t.release();
        if (s.slug_fallback_srv) |v| v.release();
        if (s.slug_fallback_tex) |t| t.release();
        s.* = .{};
    }
};
