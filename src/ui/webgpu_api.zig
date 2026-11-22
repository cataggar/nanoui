//! WebGPU object handles and the thin JavaScript import boundary.
pub const Handle = u32;
pub const Format = enum(u32) { bgra8unorm, rgba8unorm, r8unorm, rgba16float };
pub const TextureDesc = extern struct { width: u32, height: u32, format: Format, usage: u32, depth: u32 = 1, dimension: u32 = 2 };
pub const WriteDesc = extern struct { width: u32, height: u32, bytes_per_row: u32, depth: u32 = 1, x: u32 = 0, y: u32 = 0 };
/// kind: 0 dynamic uniform, 1 storage, 2 texture, 3 sampler,
/// 4 external texture, 5 3D texture, 6 non-filtering sampler.
pub const LayoutEntry = extern struct { binding: u32, visibility: u32, kind: u32 };
/// kind: 0 buffer, 1 texture view, 2 sampler, 3 external texture.
/// size=0 binds the whole buffer.
pub const BindEntry = extern struct { binding: u32, kind: u32, resource: Handle, offset: u32 = 0, size: u32 = 0 };
pub const PipelineDesc = extern struct { shader: Handle, layout: Handle, format: Format, kind: u32 = 0, sample_layout: Handle = 0 };
comptime {
    const assert = @import("std").debug.assert;
    assert(@sizeOf(TextureDesc) == 24 and @sizeOf(WriteDesc) == 24);
    assert(@sizeOf(LayoutEntry) == 12 and @sizeOf(BindEntry) == 20 and @sizeOf(PipelineDesc) == 20);
}

const raw = if (@import("builtin").is_test) struct {
    pub fn backend() u32 {
        return 0;
    }
    pub fn device() Handle {
        return 1;
    }
    pub fn device_generation() u32 {
        return 1;
    }
    pub fn preferred_format() Format {
        return .bgra8unorm;
    }
    pub fn canvas_texture() Handle {
        return 1;
    }
    pub fn canvas_view(_: Handle) Handle {
        return 1;
    }
    pub fn release(_: Handle) void {}
    pub fn buffer_create(_: u32, _: u32) Handle {
        return 1;
    }
    pub fn buffer_write(_: Handle, _: u32, _: [*]const u8, _: u32) void {}
    pub fn texture_create(_: *const TextureDesc) Handle {
        return 1;
    }
    pub fn texture_write(_: Handle, _: *const WriteDesc, _: [*]const u8, _: u32) void {}
    pub fn texture_view(_: Handle) Handle {
        return 1;
    }
    pub fn texture_format(_: Handle) Format {
        return .bgra8unorm;
    }
    pub fn texture_srgb(_: Handle) bool {
        return false;
    }
    pub fn resource_generation(_: Handle) u32 {
        return 1;
    }
    pub fn resource_serial(_: Handle) u32 {
        return 1;
    }
    pub fn resource_content_serial(_: Handle) u32 {
        return 0;
    }
    pub fn external_import(_: Handle) Handle {
        return 1;
    }
    pub fn external_copy(_: Handle, _: Handle) u32 {
        return 0;
    }
    pub fn sampler_create(_: u32) Handle {
        return 1;
    }
    pub fn shader_create(_: [*]const u8, _: u32) Handle {
        return 1;
    }
    pub fn layout_create(_: [*]const LayoutEntry, _: u32) Handle {
        return 1;
    }
    pub fn pipeline_create(_: *const PipelineDesc) Handle {
        return 1;
    }
    pub fn bind_group_create(_: Handle, _: [*]const BindEntry, _: u32) Handle {
        return 1;
    }
    pub fn encoder_begin() Handle {
        return 1;
    }
    pub fn pass_begin(_: Handle, _: Handle, _: u32, _: f32, _: f32, _: f32, _: f32) Handle {
        return 1;
    }
    pub fn pass_set_pipeline(_: Handle, _: Handle) void {}
    pub fn pass_set_bind_group(_: Handle, _: u32, _: Handle, _: u32) void {}
    pub fn pass_draw(_: Handle, _: u32, _: u32, _: u32) void {}
    pub fn pass_end(_: Handle) void {}
    pub fn pass_viewport(_: Handle, _: u32, _: u32) void {}
    pub fn pass_scissor(_: Handle, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn encoder_copy_texture(_: Handle, _: Handle, _: Handle, _: u32, _: u32) void {}
    pub fn encoder_submit(_: Handle) void {}
    pub fn read_begin(_: Handle, _: u32, _: u32, _: Format, _: [*]u8, _: u32) void {}
} else struct {
    pub extern "nanoui_gpu" fn backend() u32;
    pub extern "nanoui_gpu" fn device() Handle;
    pub extern "nanoui_gpu" fn device_generation() u32;
    pub extern "nanoui_gpu" fn preferred_format() Format;
    pub extern "nanoui_gpu" fn canvas_texture() Handle;
    pub extern "nanoui_gpu" fn canvas_view(texture: Handle) Handle;
    pub extern "nanoui_gpu" fn release(h: Handle) void;
    pub extern "nanoui_gpu" fn buffer_create(size: u32, usage: u32) Handle;
    pub extern "nanoui_gpu" fn buffer_write(buf: Handle, offset: u32, ptr: [*]const u8, len: u32) void;
    pub extern "nanoui_gpu" fn texture_create(desc: *const TextureDesc) Handle;
    pub extern "nanoui_gpu" fn texture_write(tex: Handle, desc: *const WriteDesc, ptr: [*]const u8, len: u32) void;
    pub extern "nanoui_gpu" fn texture_view(tex: Handle) Handle;
    pub extern "nanoui_gpu" fn texture_format(tex: Handle) Format;
    pub extern "nanoui_gpu" fn texture_srgb(tex: Handle) bool;
    pub extern "nanoui_gpu" fn resource_generation(resource: Handle) u32;
    pub extern "nanoui_gpu" fn resource_serial(resource: Handle) u32;
    pub extern "nanoui_gpu" fn resource_content_serial(resource: Handle) u32;
    pub extern "nanoui_gpu" fn external_import(source: Handle) Handle;
    pub extern "nanoui_gpu" fn external_copy(source: Handle, texture: Handle) u32;
    pub extern "nanoui_gpu" fn sampler_create(filter: u32) Handle;
    pub extern "nanoui_gpu" fn shader_create(ptr: [*]const u8, len: u32) Handle;
    pub extern "nanoui_gpu" fn layout_create(entries: [*]const LayoutEntry, n: u32) Handle;
    pub extern "nanoui_gpu" fn pipeline_create(desc: *const PipelineDesc) Handle;
    pub extern "nanoui_gpu" fn bind_group_create(layout: Handle, entries: [*]const BindEntry, n: u32) Handle;
    pub extern "nanoui_gpu" fn encoder_begin() Handle;
    pub extern "nanoui_gpu" fn pass_begin(enc: Handle, view: Handle, load: u32, r: f32, g: f32, b: f32, a: f32) Handle;
    pub extern "nanoui_gpu" fn pass_set_pipeline(pass: Handle, pipeline: Handle) void;
    pub extern "nanoui_gpu" fn pass_set_bind_group(pass: Handle, index: u32, group: Handle, dynamic_offset: u32) void;
    pub extern "nanoui_gpu" fn pass_draw(pass: Handle, vertices: u32, instances: u32, first_instance: u32) void;
    pub extern "nanoui_gpu" fn pass_end(pass: Handle) void;
    pub extern "nanoui_gpu" fn pass_viewport(pass: Handle, width: u32, height: u32) void;
    pub extern "nanoui_gpu" fn pass_scissor(pass: Handle, x: u32, y: u32, width: u32, height: u32) void;
    pub extern "nanoui_gpu" fn encoder_copy_texture(enc: Handle, src: Handle, dst: Handle, width: u32, height: u32) void;
    pub extern "nanoui_gpu" fn encoder_submit(enc: Handle) void;
    pub extern "nanoui_gpu" fn read_begin(tex: Handle, w: u32, h: u32, format: Format, dest: [*]u8, token: u32) void;
};

pub const backend = raw.backend;
pub const device = raw.device;
pub const device_generation = raw.device_generation;
pub const preferred_format = raw.preferred_format;
pub const canvas_texture = raw.canvas_texture;
pub const canvas_view = raw.canvas_view;
pub const release = raw.release;
pub const buffer_create = raw.buffer_create;
pub const buffer_write = raw.buffer_write;
pub const texture_create = raw.texture_create;
pub const texture_write = raw.texture_write;
pub const texture_view = raw.texture_view;
pub const texture_format = raw.texture_format;
pub const texture_srgb = raw.texture_srgb;
pub const resource_generation = raw.resource_generation;
pub const resource_serial = raw.resource_serial;
pub const resource_content_serial = raw.resource_content_serial;
pub const external_import = raw.external_import;
pub const external_copy = raw.external_copy;
pub const sampler_create = raw.sampler_create;
pub const shader_create = raw.shader_create;
pub const layout_create = raw.layout_create;
pub const pipeline_create = raw.pipeline_create;
pub const bind_group_create = raw.bind_group_create;
pub const encoder_begin = raw.encoder_begin;
pub const pass_begin = raw.pass_begin;
pub const pass_set_pipeline = raw.pass_set_pipeline;
pub const pass_set_bind_group = raw.pass_set_bind_group;
pub const pass_draw = raw.pass_draw;
pub const pass_end = raw.pass_end;
pub const pass_viewport = raw.pass_viewport;
pub const pass_scissor = raw.pass_scissor;
pub const encoder_copy_texture = raw.encoder_copy_texture;
pub const encoder_submit = raw.encoder_submit;
pub const read_begin = raw.read_begin;

const Completion = struct {
    token: u32,
    ctx: *anyopaque,
    done: *const fn (*anyopaque, bool) void,
};
var pending: [32]?Completion = @splat(null);
var serial: u32 = 0;

pub fn completion(ctx: *anyopaque, done: *const fn (*anyopaque, bool) void) ?u32 {
    for (&pending, 0..) |*slot, i| if (slot.* == null) {
        serial = (serial +% 1) & 0x7ffffff;
        const token = (serial << 5) | @as(u32, @intCast(i));
        slot.* = .{ .token = token, .ctx = ctx, .done = done };
        return token;
    };
    return null;
}

export fn nanoui_gpu_done(token: u32, status: u32) void {
    const slot = &pending[token & 31];
    const call = slot.* orelse return;
    if (call.token != token) return;
    slot.* = null;
    call.done(call.ctx, status == 0);
}
