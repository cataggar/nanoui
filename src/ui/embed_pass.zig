//! Bundled host pass encoders (`ui.embed.pass`).
//!
//! Consumes `contract.FrameOutput` directly into caller-owned CPU pixel buffers
//! or GPU render targets (Metal, Direct3D 11, OpenGL 3.3 / ES 3, WebGPU)
//! without creating windows, views, or swapchains.
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const gpu = @import("gpu.zig");
const contract = @import("contract.zig");
const raster = @import("raster.zig");
const metal_embed = @import("metal_embed.zig");

pub const Error = error{
    UnsupportedBackend,
    OpenGLUnavailable,
};

fn maskOf(out: contract.FrameOutput) raster.Mask {
    const g = out.glyph_atlas;
    const side: usize = g.width;
    return .{
        .pixels = g.pixels,
        .size = if (side == 0 or g.pixels.len < side * side) 0 else g.width,
    };
}

fn picturesOf(out: contract.FrameOutput) raster.Pictures {
    const im = out.image_atlas;
    const side: usize = im.width;
    return .{
        .pixels = im.pixels,
        .size = if (side == 0 or im.pixels.len < side * side * 4) 0 else im.width,
        .textures = out.textures,
        .gradients = out.gradients,
    };
}

fn atlasStamp(generation: u64, resets: u64) u64 {
    return generation ^ (resets *% 0x9e3779b97f4a7c15);
}

/// Reference software pass encoder (`src/ui/raster.zig`). Always available,
/// including `-Dbackend=none` and `wasm32-freestanding`.
pub const Cpu = struct {
    pub const available: bool = true;
    pub const Pixels = gpu.Pixels;

    pub fn draw(out: contract.FrameOutput, target: gpu.Pixels) void {
        raster.draw(target, out.instances, maskOf(out), picturesOf(out), out.scale, out.clear_color);
    }

    pub fn drawRegion(out: contract.FrameOutput, target: gpu.Pixels, region: [4]usize) void {
        raster.drawRegion(target, out.instances, maskOf(out), picturesOf(out), out.scale, out.clear_color, region);
    }

    pub fn damage(width: usize, height: usize, prev: []const gpu.Instance, next: []const gpu.Instance, scale: f32) ?[4]usize {
        return raster.damage(width, height, prev, next, scale);
    }

    pub fn freeLayers() void {
        raster.freeLayers();
    }
};

/// Embedded Metal pass encoder (`CAMetalLayer`-free, `NSView`-free).
/// Encodes `FrameOutput` directly into a caller `MTLCommandBuffer` + `MTLTexture`.
pub const Metal = struct {
    pub const available: bool = (builtin.os.tag == .macos or builtin.os.tag == .ios) and
        (backend.current == .auto or backend.current == .metal);

    enc: metal_embed.Encoder,

    pub fn init(device: ?*anyopaque) !Metal {
        if (!available) return error.UnsupportedBackend;
        return .{ .enc = try metal_embed.Encoder.init(device) };
    }

    pub fn deinit(self: *Metal) void {
        self.enc.deinit();
    }

    pub fn encode(self: *Metal, cmd_buffer: *anyopaque, target_texture: *anyopaque, out: contract.FrameOutput) void {
        self.enc.encode(cmd_buffer, target_texture, out);
    }

    pub fn drawTexture(self: *Metal, target_texture: *anyopaque, out: contract.FrameOutput) !void {
        return self.enc.drawTexture(target_texture, out);
    }
};

/// Embedded Direct3D 11 pass encoder wrapping `d3d11.Renderer.initOn`.
/// Draws `FrameOutput` into a caller `*ID3D11Texture2D`.
pub const D3D11 = struct {
    pub const available: bool = builtin.os.tag == .windows and
        (backend.current == .auto or backend.current == .d3d11);
    const Impl = if (available) @import("d3d11.zig").Renderer else void;

    r: Impl = if (available) undefined else {},

    pub fn init(device: *anyopaque, context: *anyopaque, cache_root: ?[]const u8) !D3D11 {
        if (!available) return error.UnsupportedBackend;
        return .{ .r = try Impl.initOn(@ptrCast(@alignCast(device)), @ptrCast(@alignCast(context)), cache_root) };
    }

    pub fn deinit(self: *D3D11) void {
        if (!available) return;
        self.r.deinit();
    }

    pub fn draw(self: *D3D11, target_texture: *anyopaque, out: contract.FrameOutput) void {
        if (!available) return;
        self.r.textures = out.textures;
        self.r.sync(
            maskOf(out),
            atlasStamp(out.glyph_atlas.generation, out.glyph_atlas.resets),
            picturesOf(out),
            atlasStamp(out.image_atlas.generation, out.image_atlas.resets),
        );
        self.r.draw(out.instances, out.size, out.scale, out.clear_color, @ptrCast(@alignCast(target_texture)));
    }
};

/// Embedded OpenGL 3.3 / OpenGL ES 3 pass encoder.
/// Draws `FrameOutput` into a caller framebuffer ID (`target_fbo`, `0` for default).
pub const OpenGL = struct {
    pub const available: bool = builtin.os.tag == .linux and builtin.link_libc and
        (backend.current == .auto or backend.current == .opengl or backend.current == .gles);
    const gl = if (available) @import("gl.zig") else struct {};
    const Impl = if (available) @import("opengl.zig").Renderer else void;

    r: Impl = if (available) undefined else {},

    pub fn init(es: bool) !OpenGL {
        if (!available) return error.UnsupportedBackend;
        if (!(if (es) gl.loadEs() else gl.load())) return error.OpenGLUnavailable;
        return .{ .r = if (es) try Impl.initEs() else try Impl.init() };
    }

    pub fn deinit(self: *OpenGL) void {
        if (!available) return;
        self.r.deinit();
    }

    pub fn draw(self: *OpenGL, target_fbo: u32, out: contract.FrameOutput) void {
        if (!available) return;
        self.r.sync(
            maskOf(out),
            atlasStamp(out.glyph_atlas.generation, out.glyph_atlas.resets),
            picturesOf(out),
            atlasStamp(out.image_atlas.generation, out.image_atlas.resets),
        );
        self.r.draw(out.instances, out.size, out.scale, out.clear_color, target_fbo, out.time);
    }
};

/// Embedded WebGPU pass encoder (`wasm32-wasi` + `-Dbackend=webgpu`).
/// Draws `FrameOutput` into a caller `Target` (`texture` + `view`).
pub const WebGPU = struct {
    pub const available: bool = builtin.os.tag == .wasi and
        (backend.current == .auto or backend.current == .webgpu);
    const Impl = if (available) @import("webgpu.zig").Renderer else void;

    pub const Target = if (available) @import("webgpu_target.zig").Target else struct {
        texture: u32 = 0,
        view: u32 = 0,
        width: u32 = 0,
        height: u32 = 0,
        format: u8 = 0,
        owned: bool = false,
    };

    r: Impl = if (available) undefined else {},

    pub fn init() !WebGPU {
        if (!available) return error.UnsupportedBackend;
        return .{ .r = try Impl.init() };
    }

    pub fn deinit(self: *WebGPU) void {
        if (!available) return;
        self.r.deinit();
    }

    pub fn draw(self: *WebGPU, target: Target, out: contract.FrameOutput) void {
        if (!available) return;
        self.r.gradients = out.gradients;
        self.r.textures = out.textures;
        self.r.sync(
            maskOf(out),
            atlasStamp(out.glyph_atlas.generation, out.glyph_atlas.resets),
            picturesOf(out),
            atlasStamp(out.image_atlas.generation, out.image_atlas.resets),
        );
        self.r.draw(out.instances, out.size, out.scale, out.clear_color, target, out.time);
    }
};
