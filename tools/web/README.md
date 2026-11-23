# WebGPU and WebGL2 target

The browser renderer and minimal canvas host build for single-threaded
`wasm32-wasi` (`+simd128`, `+bulk_memory`, `+nontrapping_fptoint`, `-atomics`)
with Zig 0.17 (`zig` with LLVM or `wazig` with `-fno-llvm`). WebGPU is
preferred when available, with an automatic non-destructive fallback to
WebGL2 (`#version 300 es`).

The renderer consumes the current **192-byte** `gpu.Instance`, including
subtree matrices, and respects `Texture.encoding` (`auto`, `display_sdr`,
`surface_linear`). It supports every current kind, pictures and glyphs,
rounded clipping, gradient stops, layers, holes, motion, glass (including
progressive sidebar blur), BGRA/half-float/external textures and LUTs.

## Build and verify

```sh
npm ci --prefix tools/web
PLAYWRIGHT_SKIP_BROWSER_GC=1 tools/web/node_modules/.bin/playwright install --only-shell chromium
zig build web-check -j1
node tools/web/check.mjs
zig build web-parity -j1
node tools/web/parity.mjs
zig build web-demo -j1
node tools/web/browser.mjs
node tools/web/serve.mjs

# Fast LLVM-free Wasm builds, unit/widget tests, and headless benchmarks with wazig + Wasmtime:
python3 tools/wazig/build.py web-check web-parity web-demo web-bench test --summary
python3 tools/wazig/build.py run-web-bench -- --frames=60 --warmup=15
```

Open the printed loopback URL with `/index.html` (counter) or
`/index.html?app=gallery` (plus optional `?gpu=webgpu|webgl2` and
`?ime=editcontext|textarea`). There is no CPU presentation fallback.
`parity.mjs` runs every scene on both WebGPU and WebGL2 against CPU pixels.
Linux CI uses pinned Playwright 1.63.0 with SwiftShader and the same checks.

`NANOUI_GPU=hardware node tools/web/parity.mjs` selects ANGLE Metal on this
Mac and adds H.264/HEVC decode tests. `NANOUI_ENGINE=webkit` selects WebKit.
The tests compare against CPU pixels at scales 1/2 and in BGRA/RGBA. They
cover subtree matrices, explicit color encodings, same-frame compute,
readback across memory growth, stale devices and incremental atlas uploads.

## App integration

`nanoui.web.mount(view, options)` creates one canvas surface;
`nanoui.web.run()` unwinds main to the JavaScript event loop. Register fonts
first. The app's state must outlive the surface. JavaScript drives only
requested frames; an idle surface registers no animation callback.
The canvas keeps a GPU backing texture for ordinary axis-aligned scenes.
It repaints changed tiles and leaves the previous image on screen when an
update produces identical pixels. Backdrop effects, transformed layers,
and application-owned passes use a full redraw.

The build helper `@import("nanoui").web.install(b, exe, dependency.path("."))`
installs a wasm32-wasi command and the browser modules together. Its module
must be single-threaded and link libc. In JavaScript:

```js
import {start} from './nanoui.js';
const runtime = await start({canvas, url: './my-app.wasm', gpu: 'auto', ime: 'auto', device});
```

`gpu` accepts `'auto'` (default: WebGPU, falling back cleanly to WebGL2
without locking the canvas), `'webgpu'` or `'webgl2'`. Omit `device` to have
nanoui acquire and recover a `GPUDevice` or `WebGL2RenderingContext`.
Injecting a device leaves ownership to the app; call `await runtime.setDevice(next)`
after replacement. `runtime.destroy()` frees renderer resources and only
an owned `GPUDevice`. OffscreenCanvas/Workers use the same API (`worker.js`).

`ui.webgpuDevice()` and `ui.webgpuDeviceGeneration()` identify the shared
device/context. `runtime.gpu.objects.put/get/drop` bridges app objects as
handles (on WebGL2, `runtime.gpu.wrapTexture(glTex, w, h, opts)` wraps raw
`WebGLTexture` handles).
Pass `true` as the second argument to `put` for textures that will keep the
same contents for their entire lifetime. Decoded `VideoFrame` objects are
already treated as immutable.
`Texture.web_texture` borrows a `GPUTexture` or wrapped `WebGLTexture`;
`web_external` borrows a `VideoFrame` or video element. Keep them alive until
the frame is submitted. Ordinary `VideoFrame` sources import directly. Padded
frames are cropped, and video elements use the normalized copy path to bridge
decoder backends. Native two-plane formats are not web sources.

### Async URL image cache (`ImageCache`)

`nanoui.web.ImageCache` (also aliased as `ui.ImageCache`) fetches, decodes,
optionally downscales, and uploads browser images off the render thread via
`src/web/images.js` (`fetch` + `createImageBitmap` with premultiplied alpha,
falling back to `HTMLImageElement` for SVG on the main thread, and supporting
`OffscreenCanvas` Workers via `baseUrl`):

```zig
var cache = nanoui.web.ImageCache.init(gpa, .{
    .max_entries = 256,
    .max_bytes = 64 * 1024 * 1024,
    .max_concurrent = 6,
});
defer cache.deinit();

// Low-level state (`loading | ready: ui.Texture | failed`):
const state = cache.get(c, url); // or cache.getWith(c, url, .{ .max_width = 256, .max_height = 256 })

// One-call widget with placeholder, smooth fade-in, cover/contain/fill fit, and fallback icon:
_ = cache.image(c, url, .{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .fit = .cover });
```

Entries are bounded by both `max_entries` and `max_bytes`; textures touched in
the current or previous frame stay pinned across `ui.list` scrolling while
older unpinned entries evict in LRU order, aborting pending fetches and freeing
their WebGPU/WebGL2 texture handles. In JavaScript, `runtime.images.putBlob(blob)`
registers in-memory `Blob`/`File` data as a `"nanoui-blob:..."` URI (`deleteBlob`
removes it). On WebGPU device loss or WebGL2 context restore
(`ui.webgpuDeviceGeneration()`), `ImageCache` automatically invalidates stale
handles and re-requests visible URLs. Keep `ImageCache` at a stable memory
address once requests are in flight (from its first `get`/`image` call until
`clear()` or `deinit()`); pass `WidgetOptions.cache_key` when global cache
identity differs from a widget's sibling `key` or rotating URL. On native
targets, `ui.Tester`, and Wasmtime, `ImageCache` uses a deterministic headless
mock host (`mockResolve`, `mockFail`, `mockStats`).

`Surface.before_encode` receives the GPUCommandEncoder's handle as a
pointer-sized integer; app JS resolves it through the object table.
`Surface.after_frame` retains its native meaning. `nanoui.web.Renderer` and
`Target` support offscreen rendering and asynchronous premultiplied BGRA
readback; keep output memory and callback context alive until completion.

`Surface.recordFrames` enables CPU/GPU timing; `gpu.stats` exposes recent
samples. The timestamp readback pool is bounded and never blocks a frame.

The host handles pointer and wheel input, pinch gestures, keyboard and
shortcuts (keeping browser-reserved chords intact), `EditContext` IME with a
hidden `<textarea>` fallback (`ime: 'auto' | 'editcontext' | 'textarea'`,
detached on password fields), DOM and async clipboard integration, cursor
styles, resize/DPR, and WebGPU/WebGL2 device/context-loss recovery. The
canvas delivers pinch scale and midpoint through `Context.input.zoom` and
`mouse`, and two-finger translation through `pan`. A pinch cancels any active
touch pointer drag rather than releasing it. Workers can forward pointer,
pinch, wheel, and key events (`worker.js`). Dialogs, filesystem, multi-window
and a complete App/Window platform remain separate work. Opaque desktop handle
types let shared app state compile without creating desktop windows in the
browser.

## JavaScript bridge and typed RPC

`nanoui.web.js` is the low-level generational handle and `Promise` bridge
(`js.zig` + `js.js`, zero `eval` / `new Function`, CSP `wasm-unsafe-eval`
clean). Zig reads and mutates JS values (`js.global`, `js.get`, `js.set`,
`js.invoke`, `js.construct`, `js.bigint`, `js.readString`, `js.readBytes`),
catches exceptions via `js.lastError`, and awaits JS `Promise`s with
`js.then` / `js.awaitCallback` and `js.cancel`. Settled `Promise`s and
dispatched RPC calls automatically wake a mounted `web.Surface` without idle
polling. Apps that do not touch `web.js` or `web.rpc` link zero `nanoui_js`
imports.

`nanoui.web.rpc` layers typed Zig ↔ TypeScript services, host imports, and
events (`rpc.zig` + `rpc.js`, mirroring desktop `App.bind` and `ipc.Event`):

```zig
const rpc = nanoui.web.rpc;
pub const Updated = rpc.Event("updated", struct { count: i32 });
pub const Host = struct { fetchNote: *const fn ([]const u8) ?[]const u8 };
pub const Schema = rpc.Schema(.{
    .services = &.{CounterService},
    .hosts = &.{Host},
    .events = &.{Updated.web_event},
});
pub const dts = Schema.dts;
```

Bind service instances before `mount` with `try rpc.bind(&svc)`, emit events
with `try Updated.emit(.{ .count = n })`, and call `runtime.host` methods
from Zig with `rpc.HostClient(Host).callSync` or `.call`. `rpc.Bytes` maps to
`Uint8Array` without base64, and `js.Handle` passes opaque JS objects (`unknown`)
on main-thread runtimes.

Pass `.rpc_schema` to `nanoui.web.installWithOptions` (with
`nanoui.web.schemaModule`) to emit `<exe>.d.ts` alongside `nanoui.d.ts`:

```js
import { start, createWorkerRPC } from './nanoui.js';
const runtime = await start({ canvas, url: './app.wasm', host: { Host: { fetchNote: k => notes.get(k) ?? null } } });
const out = await runtime.rpc.CounterService.add(1);
const off = runtime.rpc.onUpdated(ev => console.log(ev.count));
// OffscreenCanvas Worker (`worker.js`): structured-cloneable args & Uint8Array
const workerRpc = createWorkerRPC(worker);
```

See [MEASUREMENTS.md](MEASUREMENTS.md) for verification scope.
