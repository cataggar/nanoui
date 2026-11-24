# Embedding nanoui (`-Dbackend=none` & Render Packet Contract)

nanoui's immediate-mode UI core (`ui.Context`, `ui.div`, flexbox `layout`,
`ui.motion`, `nanoui.kit`, SVG/PNG/JPEG/GIF decoding, pure-Zig TrueType/WOFF2
shaping and rasterization in `src/ui/tt/`, accessibility tree generation, and
the reference CPU renderer `src/ui/raster.zig`) can be embedded directly inside
an existing engine, plugin, compositor, or WebAssembly guest without `App`,
`Window`, WebViews, swapchains, `libc`, or external Zig packages.

Each frame, `ui.embed.Host` consumes host input events and evaluates your
`ui.View` into an explicit `ui.contract.FrameOutput` packet: a flat slice of
192-byte `gpu.Instance` primitives, incremental glyph/image atlas diffs, and
one-shot host side effects (cursor, clipboard, IME geometry, accessibility, and
next-frame wake deadlines). Hosts can either feed `FrameOutput` into their own
Vulkan/DX12/Metal/GL/custom renderer or encode directly into an existing render
target with `ui.embed.pass`.

---

## 1. Overview & Build Configuration

Add `nanoui` to `build.zig.zon` and select a `backend` option when importing:

```zig
const dep = b.dependency("nanoui", .{
    .target = target,
    .optimize = optimize,
    .backend = .none, // .auto | .none | .metal | .d3d11 | .opengl | .gles | .webgpu
});
exe.root_module.addImport("nanoui", dep.module("nanoui"));
// Focused aliases exported by build.zig:
//   dep.module("embed") -> ui.embed (Host, contract, pass)
//   dep.module("ui")    -> native UI core (Context, div, widgets, motion, contract)
```

| `-Dbackend=...` | Windowing / WebView / `http_zig` | `libc` / OS libs | Bundled Pass Encoders (`ui.embed.pass`) |
| --- | --- | --- | --- |
| `auto` *(default)* | Full `App`, `Window`, `Page`, menus, trays, dialogs | Platform default | Platform renderer + `Cpu` |
| `none` | Excluded (**0** external dependencies fetched) | **None** (`link_libc = false`) | `Cpu` (`src/ui/raster.zig`) |
| `metal` | Excluded (**0** external dependencies fetched) | Metal, CoreGraphics, Foundation, `objc` | `Metal` + `Cpu` |
| `d3d11` | Excluded (**0** external dependencies fetched) | `d3d11`, `d3dcompiler_47` | `D3D11` + `Cpu` |
| `opengl` / `gles` | Excluded (**0** external dependencies fetched) | `dlopen` GL loader + `libc` | `OpenGL` (3.3 / ES 3) + `Cpu` |
| `webgpu` | Excluded (**0** external dependencies fetched) | Browser Wasm imports | `WebGPU` + `Cpu` |

### WebAssembly & Freestanding Targets

`-Dbackend=none` compiles cleanly with zero external packages and zero OS/libc
imports on both:

- **`wasm32-freestanding`** (pure memory-to-memory UI + `FrameOutput` / CPU
  rasterizer, using `@wasmMemoryGrow` via `std.heap.wasm_allocator` when
  `TextBuffer` needs a backing allocator and host-supplied `dt`/`time` clocks).
- **`wasm32-wasi`** (both standard `zig` `-fllvm` and LLVM-free `wazig` with
  `+simd128`).

---

## 2. `ui.embed.Host` Lifecycle

`ui.embed.Host` owns a `text.TextSystem`, a `ui.Context`, and persistent
per-frame buffers (`instances`, clipboard outbox, and IME state).

### Initialization & Fonts

Embedded hosts are **hermetic by default** (`scan_system_fonts = false`): no OS
font directories are walked and `std.Io.Threaded` is never touched, keeping
frame output deterministic across machines and compatible with freestanding
sandboxes. Register bundled TTF/OTF/WOFF2 bytes before drawing, or opt into
system font discovery on desktop targets:

```zig
const nanoui = @import("nanoui");
const ui = nanoui.ui;

var host = try ui.embed.Host.init(gpa, .{
    .size = .{ .w = 800, .h = 600 },
    .scale = 2.0,
    .theme = .dark_theme,
    .scan_system_fonts = false, // set true on OS targets to walk installed fonts
});
defer host.deinit();

// Register in-memory TTF/OTF/WOFF2 font bytes (scoped to the lifetime of `host`):
try host.registerFont(@embedFile("Inter-Regular.ttf"));
try host.registerFontFace(.{
    .family = "Inter",
    .weight = .{ 700, 700 },
    .italic = false,
    .bytes = @embedFile("Inter-Bold.ttf"),
});
```

### Event Ingestion & Frame Evaluation

Feed host window/plugin events into `Host` as they arrive, then call
`host.frame(view, dt, time)` when dirty or woken:

```zig
host.resize(.{ .w = 960, .h = 640 }, 2.0);
host.pointerMove(.{ .x = 120, .y = 84 });
host.pointerDown(.{ .x = 120, .y = 84 }, .left, 1);
host.scroll(.{ .x = 0, .y = -24 }, .changed, true);
host.keyDown(.{ .codepoint = 'k', .cmd = true });
try host.textInput("hello");
try host.imeSetMarked("nihao", 0, 5);
try host.imeCommit("你好");
try host.paste(clipboard_utf8);

// Thread-safe wake callback for background tasks (`c.requestFrameFromAnyThread()`):
const waker: ui.Waker = host.waker();
_ = waker;

const out: ui.contract.FrameOutput = host.frame(ui.View.init(&app_state, buildUi), dt_sec, now_sec);
```

### Idle Power & Wake Scheduling

nanoui never polls when idle. After every `host.frame(...)` call, inspect:

- **`out.wants_frame`**: `true` when an active spring/tween (`ui.motion`),
  pointer hover transition (`hot_changed`), layout-dependent resize pass, spin
  animation, or background `Waker` requires another frame on the next display
  vblank.
- **`out.next_frame_in`**: optional timer delay in seconds (`?f32`, such as
  caret blink cadence or slow pulse animations) when `wants_frame` is `false`.
  Arm a single-shot host timer for `next_frame_in` seconds; if both
  `wants_frame == false` and `next_frame_in == null`, sleep until the next
  input event or `Waker` signal.

---

## 3. `FrameOutput` Lifetime & Ownership Invariants

`FrameOutput` (`src/ui/contract.zig`) is a zero-copy view into `Host`-owned
arenas and atlases:

1. **Frame-borrowed slices** (`instances`, `gradients`, `textures`,
   `cursor.tooltip`, `clipboard_write`, `ime.?.text`, `a11y`, `stage_rects`)
   remain valid **until the next `host.frame(...)` or `host.deinit()` call**.
   Copy `clipboard_write` or `a11y` labels if retaining them across frames.
2. **Atlas pixel & table slices** (`glyph_atlas.pixels`, `image_atlas.pixels`,
   `vector_glyphs.words`) remain valid until the next `host.frame(...)` or
   `host.deinit()` call. Growing or resetting an atlas reallocates its backing
   buffer and increments `resets` (or `vector_glyphs.generation`).
3. **One-shot side effects**: `clipboard_write` and `close_requested` are
   cleared automatically at the start of the next `host.frame(...)`.
4. **External textures** (`out.textures`): `gpu.Texture` descriptors passed to
   `ui.texture(c, desc, ...)` borrow caller pixel slices or GPU handles; keep
   any referenced GPU textures or pixel buffers alive until the GPU finishes
   executing the encoded frame.

---

## 4. Binary `gpu.Instance` Layout

Every visual primitive in `out.instances` is an `extern struct` of **192 bytes**
(`contract.instance_stride == 192`, `align(4)`), laid out as **12 consecutive
`vec4<f32>`** attributes (`contract.instance_vec4_count == 12`), verified at
compile time in `src/ui/contract.zig`:

| Attr | Byte Offset | Field(s) | Type | Description |
| --- | --- | --- | --- | --- |
| `0` | `0..16` | `rect` | `[4]f32` | `[x, y, w, h]` bounds in logical points (top-left origin) |
| `1` | `16..32` | `color` | `[4]f32` | `[r, g, b, a]` straight sRGB fill / ink / tint / opacity |
| `2` | `32..48` | `border_color` | `[4]f32` | Per-`Kind`: border color, image tint, glass tone, dashes, v2, affine, or fade |
| `3` | `48..64` | `uv` | `[4]f32` | `[u0, v0, u1, v1]` atlas UVs, gradient flags, glass lens, or endpoints |
| `4` | `64..80` | `clip` | `[4]f32` | `[x0, y0, x1, y1]` scissor clip in post-transform `screen` points |
| `5` | `80..96` | `radius`, `border_width`, `kind`, `clip_round` | `4 × f32` | Offset `80`: corner radius; `84`: width/blur/slot; `88`: `Kind`; `92`: packed rounded clip |
| `6` | `96..112` | `xf` | `[4]f32` | `[angle0_rad, spin_rad_per_s, pivot_x, pivot_y]` 2D rotation around pivot |
| `7` | `112..128` | `pulse` | `[4]f32` | `[period_s, scale_amp, alpha_low, 0]` periodic scale/opacity pulse |
| `8` | `128..144` | `vel` | `[4]f32` | `[vx_pt, vy_pt, face, mirror_x]` motion blur (`0,1,3`) & 3D face (`0`=both, `1`=front, `2`=back) |
| `9` | `144..160` | `turn` | `[4]f32` | `[angle_rad, eye_dist_pt, pivot_x, pivot_y]` 3D Y-axis turn (`eye_dist == 0` is flat) |
| `10` | `160..176` | `m` | `[4]f32` | 2D affine matrix `[m0, m1, m2, m3]` (`x' = m0·x + m2·y + mt0`, `y' = m1·x + m3·y + mt1`) |
| `11` | `176..192` | `mt` | `[4]f32` | 2D affine translation `[mt0, mt1, 0, 0]` (identity `m = [1,0,0,1]`, `mt = [0,0,0,0]`) |

### `clip_round` Packing (Offset `92`)

When `clip_round != 0`, the clip box (`clip`) has rounded corners (`gpu.clipCorners`):
`corners = floor(|clip_round| / 4096)` is a 4-bit mask (`1` = top-left,
`2` = top-right, `4` = bottom-right, `8` = bottom-left), and
`r = |clip_round| - corners * 4096` is the clip radius in points. As with
`radius`, positive values use Apple's continuous squircle SDF (`corner_sdf` in
`src/ui/shader.metal`) and negative values use circular arcs.

### Per-`Kind` Semantics (`kind` @ Offset `88`)

| `Kind` | Value | Primitive & Field Interpretation |
| --- | --- | --- |
| `quad` | `0` | Rounded box (`radius`: `>0` squircle, `<0` circle). `color` straight sRGB fill; `border_color` + `border_width` inside-border laid *over* fill. `uv[0] > 0.5`: dashed border (`2w` dash, `1w` gap). `uv[1] == 1`: 2-stop vertical gradient to `gpu.gradientBottom(uv)`; `uv[1] == 2`: multi-stop gradient at index `uint(uv[2])` in `out.gradients` (`uint(uv[3])` stops). |
| `text` | `1` | Glyph or vector icon sampled from `glyph_atlas` (`.r` coverage) over `uv = [u0, v0, u1, v1]`, colored by `color` (`rgb * a, a` where `a = cov * color.a`). When `border_width > 0`, horizontal truncation fades alpha by `clamp((radius - world.x) / border_width, 0, 1)`. |
| `shadow` | `2` | Analytical Gaussian drop shadow of rounded box `rect` (`radius`). `border_width` is Gaussian `σ` in points (`>= 0.25`); vertex quad expands outward by `3 * border_width` on all sides. |
| `image` | `3` | Premultiplied picture sampled from `image_atlas` over `uv = [u0, v0, u1, v1]`, rounded by `radius`, scaled by `color[3]`. If `border_color[3] > 0`, acts as a monochrome alpha mask tinted with `border_color` (`a = px.a * border_color.a * cov * color.a`). |
| `glass` | `4` | **Barrier**: Liquid Glass pane (`src/ui/glass.zig`). `color` = tint; `border_width` = backdrop blur `σ` (pt); `border_color` = `[low, high, curve, saturation]`; `uv` = `[bezel, refraction, opacity, rim_width]` or `[-1, edge_blur, opacity, reflection]` in sidebar mode (`uv[0] < 0`). |
| `shadow_out` | `5` | Knockout drop shadow (drawn only outside the caster box). Same Gaussian math as `shadow`, multiplied by outer box SDF using `uv = [-offset_x, -offset_y, spread, 0]`. |
| `segment` | `6` | Anti-aliased line (`ui.Canvas`) from `uv[0..2]` to `uv[2..4]` in world points, stroke width `border_width`, round caps. If `border_color[0] > 0 && border_color[1] > 0`, dashed with `[on_pt, off_pt, phase_pt, 0]` and square-cut dash ends. |
| `triangle` | `7` | Anti-aliased filled triangle (`ui.Canvas`) with vertices `v0 = uv[0..2]`, `v1 = uv[2..4]`, `v2 = border_color[0..2]`. `uint(border_color[2])` is a 3-bit smooth-edge mask (`1`: `v0→v1`, `2`: `v1→v2`, `4`: `v2→v0`; unsmoothed shared edges join without seams). |
| `texture` | `8` | External texture quad (`ui.texture`) sampling `out.textures[usize(border_width)]` over `uv`, rounded by `radius`, opacity `color[3]`. Non-zero `border_color` applies a 2×2 row-major affine map around `xf[2..4]` (`gpu.affine`). |
| `layer_begin` | `9` | **Barrier**: Opens an offscreen group/mask pass (`rect` = clipped group bounds). Shaded directly, outputs `0`. |
| `layer_end` | `10` | **Barrier**: Matches `layer_begin` (`gpu.groupEnd`). `color[3]` = group opacity; `border_color` = `[top_y, bottom_y, top_fade_pt, bottom_fade_pt]`. Rewritten to `layer_composite` (`11`) when compositing the group texture. |
| `layer_composite` | `11` | Composites the premultiplied offscreen layer texture at `pos.xy` multiplied by `color[3] * scroll_fade * clip_cover * pulse_alpha`. |
| `hole` | `12` | Rounded box (`rect`, `radius`) drawn with `BlendMode.punch_out_hole` (`src * 0 + dst * (1 - src.a)`), cutting transparent alpha through the UI target. |
| `vector_text` | `13` | Analytic Slug vector glyph (`TextStyle.vector` or `Context.auto_vector_text` under geometric transforms). `border_color.xy` packs the 32-bit word offset `blob = uint(border_color.x) + uint(border_color.y) * 65536` into `out.vector_glyphs.words`; `uv = [u0, v0, u1, v1]` holds em-space (`+Y` up) quad corners interpolated across the quad; `color` is straight sRGB ink. When `border_width > 0`, horizontal truncation fades alpha by `clamp((radius - world.x) / border_width, 0, 1)`. Batched inside normal `.draw` runs (no pass barrier). |

---

## 5. Vertex Expansion, Coordinate Space & Blending

### Coordinate Space & Viewport

- Logical coordinates are in **points** with `(0, 0)` at the **top-left** and
  `+X` right, `+Y` down, over `out.size = { w, h }`.
- Physical target dimensions are `out.pixel_size = [round(w * scale), round(h * scale)]`
  (clamped to `>= 1`).
- Clip-space projection maps `seen` points `(x, y)` with perspective weight `w`
  to NDC:
  `pos = float4((seen / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0)) * w, 0.0, w)`
  (for OpenGL bottom-left FBOs, flip Y or render top-down into an internal FBO
  before blitting, as `src/ui/opengl.zig` does).

### 4-Vertex Triangle Strip Expansion (`vid` ∈ `0..3`)

Each instance draws `contract.vertices_per_instance == 4` vertices as a
**triangle strip** (`corner = float2(vid & 1, vid >> 1)` → `(0,0), (1,0), (0,1), (1,1)`):

1. Compute shadow/motion-blur padding:
   `grow = (kind == 2 || kind == 5) ? border_width * 3.0 : 0.0`, plus
   `abs(clamped_vel) * 0.5` when `length(vel.xy) > 0.5` and `kind ∈ {0, 1, 3}`.
2. Base point: `p_unrot = rect.xy - grow2 + corner * (rect.zw + 2.0 * grow2)`.
   (`local = p_unrot - rect.xy` is passed to fragment SDFs so rounded corners
   never distort under transforms.)
3. Back-face mirror: if `vel.z == 2.0`, `p.x = 2.0 * vel.w - p.x`.
4. Special geometry:
   - `kind == 6` (`segment`): oriented strip along `a = uv.xy` → `b = uv.zw`
     with half-width `e = border_width * 0.5 + 1.0`.
   - `kind == 7` (`triangle`): `vid == 0 ? uv.xy : (vid == 1 ? uv.zw : border_color.xy)`.
   - Otherwise apply `pulse`, 2D rotation `angle = xf.x + xf.y * time`, and
     `kind == 8` `border_color` 2×2 map about `xf.zw`.
5. Apply 2D plane transform `landed = m * p + mt` (`screen = landed`), then 3D
   Y-axis turn `turn` (culling back-turned faces to a degenerate point).

### Premultiplied sRGB Blending & Multi-Stop Gradients

All fragment outputs are **premultiplied display-encoded sRGB** (`rgb <= a`):

- **`BlendMode.premultiplied_over`** (all primitives except `Kind.hole`):
  `out.rgb = src.rgb * 1 + dst.rgb * (1 - src.a)`,
  `out.a   = src.a   * 1 + dst.a   * (1 - src.a)`.
  Do **not** attach an `_SRGB` hardware framebuffer conversion if shaders emit
  sRGB values directly (nanoui blends in sRGB space to match Metal, CSS, and
  `raster.zig` pixel-for-pixel).
- **`BlendMode.punch_out_hole`** (`Kind.hole`, `contract.blendModeFor(kind)`):
  `out = dst * (1 - src.a)` (`src_factor = ZERO`, `dst_factor = ONE_MINUS_SRC_ALPHA`).
- **Multi-stop gradient table** (`out.gradients: []const [4]f32`):
  For `Kind.quad` with `uv[1] == 2`, `at = uint(uv[2])` indexes a header
  `gradients[at] = [anchor_y, anchor_h, stop_count, 0]` followed by `stop_count`
  pairs `[stop_t, 0, 0, 0]`, `[r, g, b, a]` (straight sRGB), evaluated via
  `gpu.gradientAt(out.gradients, inst.uv, local.y)`.

---

## 6. Atlases & Incremental GPU Upload

`FrameOutput` exposes two CPU-backed texture atlases and one packed vector-glyph
word table:

- **`out.glyph_atlas`** (`contract.GlyphAtlas`): `R8_UNORM`, 1 byte/texel,
  row pitch `width` bytes, linear filtering, `clamp_to_edge`.
- **`out.image_atlas`** (`contract.ImageAtlas`): premultiplied `BGRA8_UNORM`
  (`[B, G, R, A]` bytes in memory; swizzle `.bgra` if uploading as `RGBA8` on
  GLES/WebGL), 4 bytes/texel, row pitch `width * 4` bytes, linear filtering,
  `clamp_to_edge`.
- **`out.vector_glyphs`** (`contract.VectorGlyphTable`): `1024`-wide `R32_UINT`
  word table (`words: []const u32`, `width = 1024`, `height` rows, `used_words`,
  `generation`) addressed linearly as `(word_idx & 1023, word_idx >> 10)` using
  nearest/integer texel fetches (`texelFetch` / `read` / `Load`). Word `0` is a
  zero sentinel; each `Kind.vector_text` (`13`) glyph header begins at `blob`
  with 9 `u32` words (`min_x`, `min_y`, `scale_x`, `scale_y` as `f32` bits,
  `h_bands | (v_bands << 8)`, `total_curves | (flags << 16)`, `h_dir_off`,
  `v_dir_off`, `pts_off`), followed by `(count, list_off)` band directories,
  `u16`-pair curve index lists, and quantized `u16x2` control-point triples.
  Re-upload `words[0..used_words]` (recreating the `1024 × height` `R32_UINT`
  texture if `height` grew) whenever `vector_glyphs.generation` changes.

Upload logic for custom GPU backends:

1. **Texture recreation**: If your cached GPU texture is missing, its dimensions
   differ from `(atlas.width, atlas.height)`, or `atlas.resets != cached_resets`,
   recreate the GPU texture at `(atlas.width, atlas.height)` and upload all of
   `atlas.pixels`.
2. **Incremental sub-rect upload**: Otherwise, if
   `atlas.generation != cached_generation`:
   - If `atlas.dirty` is `|rect|` (`!rect.isEmpty()`) **and**
     `atlas.dirty_from_generation == cached_generation` (no intermediate
     frames that modified the atlas were skipped), upload only rows
     `rect.y .. rect.y + rect.height` and columns `rect.x .. rect.x + rect.width`
     from `atlas.pixels` (`offset = (rect.y * atlas.width + rect.x) * bpp`,
     `bytes_per_row = atlas.width * bpp`).
   - Otherwise (`atlas.dirty == null` or an earlier `FrameOutput` was not
     encoded so `cached_generation != atlas.dirty_from_generation`), upload the
     full texture.
3. Record `cached_generation = atlas.generation` and `cached_resets = atlas.resets`.

---

## 7. Pass Splitting & Barrier Ordering

Most frames consist of a single instanced draw call. Render-pass barriers occur
only when a frame uses Liquid Glass (`Kind.glass`) or grouped opacity / scroll
edge-fade masks (`Kind.layer_begin` .. `Kind.layer_end`). Use
`ui.contract.effectiveClear`, `ui.contract.iterPasses`, and
`ui.contract.iterSpan` to walk passes without heap allocation:

```zig
const ec = ui.contract.effectiveClear(out.instances, out.size, out.clear_color);
// Clear target to `ec.clear` on the first render pass; hidden instances `0..ec.first` are skipped.

var it = ui.contract.iterPasses(out.instances, out.size);
while (it.next()) |run| switch (run) {
    .draw => |range| {
        // Inside `out.instances[range.start..range.end]`, batch contiguous
        // instances, switching texture slot 3 on `Kind.texture`
        // (`slot = usize(inst.border_width)`) and switching blend state to
        // `punch_out_hole` on `Kind.hole`.
        encodeDrawRange(range.start, range.end);
    },
    .glass => |idx| {
        // End current pass, downsample + Gaussian-blur backdrop (`glass.backdropFor`),
        // then shade `out.instances[idx]` into the target.
        encodeGlassPane(idx);
    },
    .layer => |grp| {
        if (grp.end <= grp.begin + 1) continue;
        // Unmasked opacity groups hoist direct `Kind.glass` panes to the parent
        // target before clearing the offscreen layer texture to transparent:
        if (!grp.masked) hoistDirectGlassToParent(grp.begin + 1, grp.end);
        // Recursively encode `ui.contract.iterSpan(out.instances, grp.begin + 1, grp.end)`
        // into a transparent offscreen layer texture at depth `d` (skipping glass when `!grp.masked`),
        // then composite `out.instances[grp.end]` with `kind = Kind.layer_composite` (11).
        encodeOffscreenLayer(grp);
    },
};
```

Key ordering invariants verified across Metal, D3D11, OpenGL, WebGPU, and CPU:

1. **Opaque cover promotion (`effectiveClear`)**: `gpu.lastCover` finds the last
   full-viewport, unclipped, untransformed opaque `Kind.quad` before any barrier,
   hole, or external texture, promoting its RGB to the pass clear color.
2. **Unmasked vs. masked layers**:
   - `grp.masked == false` (`Style.group` with `opacity < 1`): direct
     `Kind.glass` children render against the *parent* target before the layer
     pass so they refract what lies behind the group, and are skipped inside the
     transparent layer pass.
   - `grp.masked == true` (`scroll_edge_fade` where `border_color[2] > 0` or
     `border_color[3] > 0` on `instances[grp.end]`): glass renders inside the
     layer so the composite pass fades both content and glass at the scroll edges.
3. **Sub-pass state switches**: `Kind.texture` and `Kind.hole` stay inside the
   current `.draw` render pass (no target readback barrier); `Kind.texture`
   binds `out.textures[usize(inst.border_width)]`, and `Kind.hole` binds the
   `(ZERO, ONE_MINUS_SRC_ALPHA)` punch-out pipeline for 1 instance.

---

## 8. Bundled Pass Encoders (`ui.embed.pass`)

When your host already uses a supported graphics API (or wants reference software
rendering), `ui.embed.pass` consumes `FrameOutput` directly into caller-owned
targets without creating windows or swapchains:

- **`ui.embed.pass.Cpu`** *(always available, including `-Dbackend=none`)*:
  draws `FrameOutput` (full frame or pixel damage rect via `raster.damage`) into
  caller-owned premultiplied BGRA `gpu.Pixels`.
- **`ui.embed.pass.Metal`** *(`-Dbackend=metal` or macOS/iOS `auto`)*:
  `CAMetalLayer`-free encoder initialized on an existing or default `MTLDevice`;
  syncs `FrameOutput`'s `R8` glyph and `BGRA8` image atlases and encodes passes
  directly into a caller's `MTLCommandBuffer` + target `MTLTexture`.
- **`ui.embed.pass.D3D11`** *(`-Dbackend=d3d11` or Windows `auto`)*:
  wraps `d3d11.Renderer.initOn(device, context, cache_root)`, syncs `FrameOutput`
  atlases/gradients/textures, and draws into a caller `*ID3D11Texture2D`.
- **`ui.embed.pass.OpenGL`** *(`-Dbackend=opengl` / `gles` or Linux/Android `auto`)*:
  wraps OpenGL 3.3 (`init`) or OpenGL ES 3 (`initEs`) and blits into a caller
  framebuffer ID (`target_fbo: u32`, `0` for default framebuffer).
- **`ui.embed.pass.WebGPU`** *(`-Dbackend=webgpu`)*:
  syncs `FrameOutput` resources and encodes into a caller `webgpu.Target`
  (`{ texture, view, width, height, format }`).

See `examples/embedded/main.zig` (`zig build run-embedded -Dbackend=none`) and
`src/ui/tests_embed.zig` (`zig build test-embed`) for complete end-to-end usage.
