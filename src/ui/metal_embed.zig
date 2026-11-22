//! Embedded Metal pass encoder (`CAMetalLayer`-free, `NSView`-free).
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const contract = @import("contract.zig");

pub const available: bool = (builtin.os.tag == .macos or builtin.os.tag == .ios) and (backend.current == .auto or backend.current == .metal);
const objc = if (available) @import("../objc.zig") else struct {};
const cf = if (available) @import("cf.zig") else struct {};
const metal = if (available) @import("metal.zig") else struct {};
const metal_glass = if (available) @import("metal_glass.zig") else struct {};
const metal_texture = if (available) @import("metal_texture.zig") else struct {};
const shader_source = @embedFile("shader.metal") ++ @embedFile("glass.metal") ++ @embedFile("texture_post.metal");

pub const Encoder = if (available) AppleEncoder else struct {
    pub fn init(_: ?*anyopaque) !@This() {
        return error.UnsupportedBackend;
    }
    pub fn deinit(_: *@This()) void {}
    pub fn encode(_: *@This(), _: *anyopaque, _: *anyopaque, _: contract.FrameOutput) void {}
    pub fn drawTexture(_: *@This(), _: *anyopaque, _: contract.FrameOutput) !void {
        return error.UnsupportedBackend;
    }
};

const AppleEncoder = struct {
    const r8_format: objc.NSUInteger = 10;
    const bgra8_format: objc.NSUInteger = 80;
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    const LayerTex = struct { tex: ?objc.Object = null, w: objc.NSUInteger = 0, h: objc.NSUInteger = 0 };
    const AtlasSlot = struct { texture: ?objc.Object = null, width: u32 = 0, height: u32 = 0, generation: u64 = std.math.maxInt(u64), resets: u64 = std.math.maxInt(u64) };
    const Pipes = struct { main: objc.Object, hole: objc.Object, glass: objc.Object };
    device: objc.Object,
    library: objc.Object,
    pipeline: objc.Object,
    hole: objc.Object,
    fallback_atlas: objc.Object,
    glass: metal_glass.Glass,
    frame_textures: metal_texture.Textures,
    queue: ?objc.Object = null,
    target_format: objc.NSUInteger = bgra8_format,
    glyph_slot: AtlasSlot = .{},
    image_slot: AtlasSlot = .{},
    buffers: [3]?objc.Object = @splat(null),
    capacities: [3]usize = @splat(0),
    tex_held: [3]std.ArrayList(*anyopaque) = @splat(.empty),
    retired: [3]std.ArrayList(objc.Object) = @splat(.empty),
    next_slot: usize = 0,
    layers: std.ArrayList(LayerTex) = .empty,
    grad_offset: usize = 0,
    time: f32 = 0,

    pub fn init(device_opt: ?*anyopaque) !AppleEncoder {
        const pool = objc.Pool.push();
        defer pool.pop();
        const device: objc.Object = if (device_opt) |d| objc.retain(@ptrCast(d)) else cf.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer objc.release(device);
        var err: ?objc.Object = null;
        const lib = objc.msg(?objc.Object, device, "newLibraryWithSource:options:error:", .{ objc.nsString(shader_source), @as(?objc.Object, null), &err }) orelse return error.ShaderCompile;
        errdefer objc.release(lib);
        const pipes = try makePipes(device, lib, bgra8_format);
        errdefer {
            objc.release(pipes.main);
            objc.release(pipes.hole);
        }
        var glass = metal_glass.Glass.init(device, lib, pipes.glass) catch |e| {
            objc.release(pipes.glass);
            return e;
        };
        errdefer glass.deinit();
        var ftex: metal_texture.Textures = .{ .gpa = backend.default_allocator };
        try ftex.initPost(device, lib);
        errdefer ftex.deinit();
        const fallback = newTex(device, r8_format, 1, 1, 1, 0) orelse return error.TextureCreate;
        uploadRect(fallback, 0, 0, 1, 1, &[1]u8{0}, 1);
        return .{ .device = device, .library = lib, .pipeline = pipes.main, .hole = pipes.hole, .fallback_atlas = fallback, .glass = glass, .frame_textures = ftex };
    }
    pub fn deinit(self: *AppleEncoder) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const gpa = backend.default_allocator;
        for (&self.tex_held) |*h| {
            self.frame_textures.release(h);
            h.deinit(self.frame_textures.gpa);
        }
        for (&self.retired) |*r| {
            releaseRetired(r);
            r.deinit(gpa);
        }
        for (&self.buffers) |*b| if (b.*) |buf| objc.release(buf);
        for (self.layers.items) |l| if (l.tex) |t| objc.release(t);
        self.layers.deinit(gpa);
        for ([_]?objc.Object{ self.glyph_slot.texture, self.image_slot.texture, self.queue }) |o| if (o) |x| objc.release(x);
        self.frame_textures.deinit();
        self.glass.deinit();
        for ([_]objc.Object{ self.fallback_atlas, self.hole, self.pipeline, self.library, self.device }) |o| objc.release(o);
    }
    pub fn drawTexture(self: *AppleEncoder, target_texture: *anyopaque, out: contract.FrameOutput) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const q = self.queue orelse (objc.msg(?objc.Object, self.device, "newCommandQueue", .{}) orelse return error.NoCommandQueue);
        self.queue = q;
        const cmd = objc.msg(?objc.Object, q, "commandBuffer", .{}) orelse return error.NoCommandBuffer;
        self.encode(@ptrCast(cmd), target_texture, out);
        objc.msg(void, cmd, "commit", .{});
        objc.msg(void, cmd, "waitUntilCompleted", .{});
    }
    pub fn encode(self: *AppleEncoder, cmd_buffer: *anyopaque, target_texture: *anyopaque, out: contract.FrameOutput) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd: objc.Object = @ptrCast(cmd_buffer);
        const target: objc.Object = @ptrCast(target_texture);
        const slot = self.next_slot;
        self.next_slot = (slot + 1) % 3;
        self.frame_textures.release(&self.tex_held[slot]);
        releaseRetired(&self.retired[slot]);
        const pf = objc.msg(objc.NSUInteger, target, "pixelFormat", .{});
        if (pf != 0 and pf != self.target_format) self.retarget(pf, slot);
        self.time = @floatCast(out.time);
        const g = out.glyph_atlas;
        const im = out.image_atlas;
        const atlas = self.syncAtlas(&self.glyph_slot, g.pixels, g.width, g.height, 1, r8_format, g.generation, g.resets, g.dirty_from_generation, g.dirty, slot) orelse self.fallback_atlas;
        const images = self.syncAtlas(&self.image_slot, im.pixels, im.width, im.height, 4, bgra8_format, im.generation, im.resets, im.dirty_from_generation, im.dirty, slot) orelse atlas;
        const ec = contract.effectiveClear(out.instances, out.size, out.clear_color);
        const buf = (if (ec.first < out.instances.len) self.uploadFrame(slot, out.instances, out.gradients) else null) orelse return endPass(metal.Renderer.pass(cmd, target, ec.clear));
        self.frame_textures.prepare(self.device, cmd, out.textures, &self.tex_held[slot]);
        self.encodeSpan(cmd, target, buf, atlas, images, out, ec.first, out.instances.len, 0, ec.clear, false, slot);
    }
    fn syncAtlas(self: *AppleEncoder, s: *AtlasSlot, pixels: []const u8, w: u32, h: u32, bpp: usize, fmt: objc.NSUInteger, gen: u64, resets: u64, dirty_from: u64, dirty: ?contract.DirtyRect, slot: usize) ?objc.Object {
        if (w == 0 or h == 0 or pixels.len < @as(usize, w) * @as(usize, h) * bpp) return null;
        const stride = @as(usize, w) * bpp;
        if (s.texture == null or s.width != w or s.height != h or s.resets != resets) {
            if (s.texture) |old| self.retire(slot, old);
            const tex = newTex(self.device, fmt, w, h, 1, 0) orelse {
                s.* = .{};
                return null;
            };
            uploadRect(tex, 0, 0, w, h, pixels.ptr, stride);
            s.* = .{ .texture = tex, .width = w, .height = h, .generation = gen, .resets = resets };
            return tex;
        }
        if (s.generation != gen) {
            const r = if (dirty != null and dirty_from == s.generation) dirty.? else contract.DirtyRect{ .x = 0, .y = 0, .width = w, .height = h };
            const rx: usize = @min(r.x, w);
            const ry: usize = @min(r.y, h);
            const rw: usize = @min(r.width, w - @as(u32, @intCast(rx)));
            const rh: usize = @min(r.height, h - @as(u32, @intCast(ry)));
            if (rw > 0 and rh > 0) uploadRect(s.texture.?, rx, ry, rw, rh, pixels.ptr + ry * stride + rx * bpp, stride);
            s.generation = gen;
        }
        return s.texture;
    }
    fn uploadFrame(self: *AppleEncoder, slot: usize, instances: []const gpu.Instance, gradients: []const [4]f32) ?objc.Object {
        const ib = std.mem.sliceAsBytes(instances);
        const gb = std.mem.sliceAsBytes(gradients);
        const goff = if (gb.len > 0) std.mem.alignForward(usize, ib.len, 256) else 0;
        const need = if (gb.len > 0) goff + gb.len else ib.len;
        if (self.buffers[slot] == null or self.capacities[slot] < need) {
            if (self.buffers[slot]) |old| self.retire(slot, old);
            const cap = @max(need * 2, 16 * 1024);
            self.buffers[slot] = objc.msg(?objc.Object, self.device, "newBufferWithLength:options:", .{ @as(objc.NSUInteger, cap), @as(objc.NSUInteger, 0) }) orelse {
                self.capacities[slot] = 0;
                return null;
            };
            self.capacities[slot] = cap;
        }
        const buf = self.buffers[slot].?;
        const dst: [*]u8 = @ptrCast(objc.msg(*anyopaque, buf, "contents", .{}));
        @memcpy(dst[0..ib.len], ib);
        for (@as([*]gpu.Instance, @ptrCast(@alignCast(dst)))[0..instances.len]) |*inst| if (inst.kind == gpu.Kind.layer_end) {
            inst.kind = gpu.Kind.layer_composite;
        };
        if (gb.len > 0) @memcpy(dst[goff .. goff + gb.len], gb);
        self.grad_offset = goff;
        return buf;
    }
    fn encodeSpan(self: *AppleEncoder, cmd: objc.Object, target: objc.Object, buf: objc.Object, atlas: objc.Object, images: objc.Object, out: contract.FrameOutput, begin: usize, end: usize, depth: usize, clear: types.Color, skip_glass: bool, slot: usize) void {
        const tw = objc.msg(objc.NSUInteger, target, "width", .{});
        const th = objc.msg(objc.NSUInteger, target, "height", .{});
        const scale: f32 = if (out.size.w > 0) @as(f32, @floatFromInt(tw)) / out.size.w else if (out.scale > 0) out.scale else 1;
        var cleared = false;
        var it = contract.iterSpan(out.instances, begin, end);
        while (it.next()) |run| switch (run) {
            .draw => |r| {
                const enc = metal.Renderer.pass(cmd, target, if (cleared) null else clear);
                cleared = true;
                self.drawRun(enc, buf, atlas, images, out.size, out.instances, r.start, r.end);
                endPass(enc);
            },
            .glass => |at| {
                if (!cleared) {
                    endPass(metal.Renderer.pass(cmd, target, clear));
                    cleared = true;
                }
                if (!skip_glass) self.encodeGlass(cmd, target, buf, out.size, out.instances[at], at, scale);
            },
            .layer => |grp| {
                if (!cleared) {
                    endPass(metal.Renderer.pass(cmd, target, clear));
                    cleared = true;
                }
                const b = grp.bounds;
                if (grp.end <= grp.begin + 1 or @ceil((b.x + b.w) * scale) <= @max(0, @floor(b.x * scale)) or @ceil((b.y + b.h) * scale) <= @max(0, @floor(b.y * scale)) or @floor(b.x * scale) >= @as(f32, @floatFromInt(tw)) or @floor(b.y * scale) >= @as(f32, @floatFromInt(th))) continue;
                if (!grp.masked) {
                    var git = contract.iterSpan(out.instances, grp.begin + 1, grp.end);
                    while (git.next()) |gr| if (gr == .glass) self.encodeGlass(cmd, target, buf, out.size, out.instances[gr.glass], gr.glass, scale);
                }
                const ltex = self.ensureLayer(tw, th, depth, slot) orelse continue;
                self.encodeSpan(cmd, ltex, buf, atlas, images, out, grp.begin + 1, grp.end, depth + 1, types.Color.transparent, !grp.masked, slot);
                const cenc = metal.Renderer.pass(cmd, target, null);
                self.drawRange(cenc, self.pipeline, buf, atlas, images, ltex, atlas, out.size, grp.end, 1);
                endPass(cenc);
            },
        };
        if (!cleared) endPass(metal.Renderer.pass(cmd, target, clear));
    }
    fn encodeGlass(self: *AppleEncoder, cmd: objc.Object, target: objc.Object, buf: objc.Object, size: types.Size, inst: gpu.Instance, at: usize, scale: f32) void {
        const pane = self.glass.backdrop(self.device, cmd, target, inst, scale) orelse return;
        const genc = metal.Renderer.pass(cmd, target, null);
        self.bindBase(genc, self.glass.pipeline, buf, size);
        objc.msg(void, genc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &pane), @as(objc.NSUInteger, @sizeOf(metal_glass.Pane)), @as(objc.NSUInteger, 1) });
        objc.msg(void, genc, "setFragmentTexture:atIndex:", .{ self.glass.a.?, @as(objc.NSUInteger, 2) });
        drawInstanced(genc, 1, at);
        endPass(genc);
    }
    fn drawRun(self: *AppleEncoder, enc: objc.Object, buf: objc.Object, atlas: objc.Object, images: objc.Object, size: types.Size, instances: []const gpu.Instance, first: usize, end: usize) void {
        var from = first;
        for (instances[first..end], first..) |inst, i| {
            if (inst.kind != gpu.Kind.texture and inst.kind != gpu.Kind.hole) continue;
            if (i > from) self.drawRange(enc, self.pipeline, buf, atlas, images, atlas, atlas, size, from, i - from);
            from = i + 1;
            if (inst.kind == gpu.Kind.hole) self.drawRange(enc, self.hole, buf, atlas, images, atlas, atlas, size, i, 1) else if (inst.border_width >= 0) if (self.frame_textures.get(@intFromFloat(inst.border_width))) |tex| self.drawRange(enc, self.pipeline, buf, atlas, images, atlas, tex, size, i, 1);
        }
        if (end > from) self.drawRange(enc, self.pipeline, buf, atlas, images, atlas, atlas, size, from, end - from);
    }
    fn drawRange(self: *AppleEncoder, enc: objc.Object, pipe: objc.Object, buf: objc.Object, atlas: objc.Object, images: objc.Object, layer_tex: objc.Object, frame_tex: objc.Object, size: types.Size, base: usize, count: usize) void {
        self.bindBase(enc, pipe, buf, size);
        objc.msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ buf, @as(objc.NSUInteger, self.grad_offset), @as(objc.NSUInteger, 3) });
        for ([_]objc.Object{ atlas, images, layer_tex, frame_tex }, 0..) |t, idx| objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ t, @as(objc.NSUInteger, idx) });
        drawInstanced(enc, count, base);
    }
    fn bindBase(self: *const AppleEncoder, enc: objc.Object, pipe: objc.Object, buf: objc.Object, size: types.Size) void {
        const vp: [2]f32 = .{ size.w, size.h };
        objc.msg(void, enc, "setRenderPipelineState:", .{pipe});
        objc.msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ buf, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &vp), @as(objc.NSUInteger, 8), @as(objc.NSUInteger, 1) });
        objc.msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &self.time), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 2) });
        objc.msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ buf, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0) });
    }
    fn ensureLayer(self: *AppleEncoder, w: objc.NSUInteger, h: objc.NSUInteger, depth: usize, slot: usize) ?objc.Object {
        if (w == 0 or h == 0) return null;
        while (self.layers.items.len <= depth) self.layers.append(backend.default_allocator, .{}) catch return null;
        const l = &self.layers.items[depth];
        if (l.tex != null and l.w == w and l.h == h) return l.tex;
        if (l.tex) |old| self.retire(slot, old);
        l.* = .{ .tex = newTex(self.device, self.target_format, w, h, 1 | 4, 2), .w = w, .h = h };
        return l.tex;
    }
    fn retarget(self: *AppleEncoder, pf: objc.NSUInteger, slot: usize) void {
        const pipes = makePipes(self.device, self.library, pf) catch return;
        for ([_]objc.Object{ self.pipeline, self.hole, self.glass.pipeline }) |old| self.retire(slot, old);
        self.pipeline = pipes.main;
        self.hole = pipes.hole;
        self.glass.pipeline = pipes.glass;
        self.target_format = pf;
        for (self.layers.items) |*l| {
            if (l.tex) |old| self.retire(slot, old);
            l.* = .{};
        }
    }
    fn endPass(enc: objc.Object) void {
        objc.msg(void, enc, "endEncoding", .{});
    }
    fn drawInstanced(enc: objc.Object, count: usize, base: usize) void {
        objc.msg(void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{ @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, count), @as(objc.NSUInteger, base) });
    }
    fn retire(self: *AppleEncoder, slot: usize, obj: objc.Object) void {
        self.retired[slot].append(backend.default_allocator, obj) catch objc.release(obj);
    }
    fn releaseRetired(list: *std.ArrayList(objc.Object)) void {
        for (list.items) |o| objc.release(o);
        list.clearRetainingCapacity();
    }
    fn uploadRect(tex: objc.Object, x: usize, y: usize, w: usize, h: usize, ptr: [*]const u8, stride: usize) void {
        objc.msg(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ Region{ .x = x, .y = y, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, ptr), @as(objc.NSUInteger, stride) });
    }
    fn newTex(device: objc.Object, fmt: objc.NSUInteger, w: objc.NSUInteger, h: objc.NSUInteger, usage: objc.NSUInteger, storage: objc.NSUInteger) ?objc.Object {
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ fmt, w, h, objc.NO });
        objc.msg(void, desc, "setUsage:", .{usage});
        objc.msg(void, desc, "setStorageMode:", .{storage});
        return objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc});
    }
    fn makePipes(device: objc.Object, library: objc.Object, fmt: objc.NSUInteger) !Pipes {
        const main = try metal.makePipelineFor(device, library, "fs", 1, fmt);
        errdefer objc.release(main);
        const hole = try metal.makePipelineFor(device, library, "fs", 0, fmt);
        errdefer objc.release(hole);
        return .{ .main = main, .hole = hole, .glass = try metal.makePipelineFor(device, library, "fs_glass", 1, fmt) };
    }
};
