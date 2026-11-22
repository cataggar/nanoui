# Current integration verification

These results were measured on nanoui 0.14.6 with this target added. The
old 0.11 experiment's performance results are not represented as
measurements of this revision.

Hardware testing uses an Apple M5 Max, macOS 27.0.1, Zig 0.17.0, Node 26.9.0
and Playwright 1.63.0's Chromium headless shell. Pixel parity runs at scales
1 and 2 in both BGRA and RGBA. Current additions cover the 192-byte instance
matrix and explicit display/surface-linear texture encoding, alongside the
original renderer scenarios. Nested opacity groups and scroll-edge masks
are covered together with overlapping content. The limits remain the
native CPU/OpenGL ones.

The current revision passes 76 hardware Chromium cases, 68 SwiftShader
cases and 68 WebKit cases. Each includes both scales and texture formats.
The nested-group scene differs from the CPU by at most one channel level.

An application built on this target has also been checked headlessly for
startup, zero idle frames, DPR/resize, device recovery preserving the
document, and resource cleanup.

Physical 120/240 Hz displays and guaranteed hardware-decoder selection have
not been tested. H.264/HEVC tests use WebCodecs `no-preference`; external HDR
conversion belongs to the browser. Playwright WebKit is not installed Safari.
Firefox's headless build exposed WebGPU but no adapter on this machine.

---

## Wasm `+simd128`, `wazig` (`-fno-llvm`), and headless WASI benchmarks

Measured on a 16-core ARM Neoverse-N2 (`aarch64-linux-gnu`), `zig 0.17.1`
(`-fllvm`), `wazig 0.17.1-wazig.1` (`-fno-llvm`), `wasmtime 50.0.1`,
`gzip 1.14` (`-9`), and `zstd 1.5.7` (`-19`).

All WebAssembly targets default to single-threaded `wasm32-wasi` with
`+simd128`, `+bulk_memory`, `+nontrapping_fptoint`, `+sign_ext`,
`+mutable_globals`, and `-atomics` (disable SIMD with `-Dsimd128=false`).
Portable `wasm32-wasi` unit and widget tests (`nanoui-tests.wasm`) pass
**576 / 576** active tests (34 platform-specific skips, 0 failures) under
Wasmtime with both `zig` (`-fllvm`) and `wazig` (`-fno-llvm +simd128`).

### `.wasm` binary sizes (raw / `gzip -9` / `zstd -19`)

`counter`, `gallery`, `nanoui-web-parity`, and `nanoui-web-bench` embed two
DejaVuSans `.ttf` faces (~1.58 MB raw); `nanoui-web-check` reflects the
engine, rasterizer, and WebGPU/WebGL2 bridge without embedded font files. In
`Debug` and `ReleaseFast`, `wazig` (`-fno-llvm`) emits **2.08×–4.00× smaller**
raw `.wasm` binaries than `zig` (`-fllvm`).

| artifact | mode | `zig -fllvm` (`-Dsimd128=false`) | `zig -fllvm` (`+simd128`) | `wazig -fno-llvm` (`+simd128`) |
|---|---|---:|---:|---:|
| `nanoui-web-check` | `Debug` | 4.72 MB / 1.53 MB / 1.18 MB | 4.73 MB / 1.53 MB / 1.18 MB | 1.18 MB / 399 KB / 320 KB |
| `nanoui-web-check` | `ReleaseSmall` | 468 KB / 202 KB / 176 KB | 465 KB / 201 KB / 175 KB | 719 KB / 270 KB / 226 KB |
| `nanoui-web-check` | `ReleaseFast` | 3.66 MB / 1.19 MB / 991 KB | 3.71 MB / 1.20 MB / 1.00 MB | 960 KB / 356 KB / 291 KB |
| `nanoui-web-parity` | `ReleaseSmall` | 2.19 MB / 979 KB / 759 KB | 2.19 MB / 975 KB / 758 KB | 2.46 MB / 1.05 MB / 811 KB |
| `nanoui-web-parity` | `ReleaseFast` | 5.65 MB / 2.05 MB / 1.65 MB | 5.70 MB / 2.07 MB / 1.66 MB | 2.74 MB / 1.15 MB / 889 KB |
| `counter` | `Debug` | 6.73 MB / 2.45 MB / 1.85 MB | 6.74 MB / 2.45 MB / 1.86 MB | 2.89 MB / 1.21 MB / 926 KB |
| `counter` | `ReleaseSmall` | 2.06 MB / 977 KB / 760 KB | 2.06 MB / 977 KB / 759 KB | 2.35 MB / 1.05 MB / 814 KB |
| `counter` | `ReleaseFast` | 5.57 MB / 2.07 MB / 1.66 MB | 5.62 MB / 2.08 MB / 1.67 MB | 2.64 MB / 1.16 MB / 894 KB |
| `gallery` | `Debug` | 8.04 MB / 2.91 MB / 2.19 MB | 8.05 MB / 2.91 MB / 2.19 MB | 3.40 MB / 1.39 MB / 1.06 MB |
| `gallery` | `ReleaseSmall` | 2.39 MB / 1.10 MB / 863 KB | 2.38 MB / 1.09 MB / 858 KB | 2.73 MB / 1.20 MB / 924 KB |
| `gallery` | `ReleaseFast` | 7.16 MB / 2.60 MB / 2.07 MB | 7.17 MB / 2.60 MB / 2.07 MB | 3.13 MB / 1.35 MB / 1.03 MB |
| `nanoui-web-bench` | `ReleaseSmall` | 2.00 MB / 957 KB / 741 KB | 1.99 MB / 956 KB / 741 KB | 2.28 MB / 1.03 MB / 795 KB |
| `nanoui-web-bench` | `ReleaseFast` | 5.73 MB / 2.09 MB / 1.67 MB | 5.83 MB / 2.12 MB / 1.70 MB | 2.57 MB / 1.14 MB / 876 KB |
| `nanoui-tests` | `Debug` | 22.66 MB / 5.85 MB / 3.89 MB | 22.67 MB / 5.85 MB / 3.89 MB | 7.39 MB / 1.96 MB / 1.30 MB |
| `nanoui-tests` | `ReleaseSmall` | 3.11 MB / 984 KB / 800 KB | 3.01 MB / 938 KB / 776 KB | 5.60 MB / 1.49 MB / 1.03 MB |
| `nanoui-tests` | `ReleaseFast` | 21.82 MB / 4.96 MB / 3.75 MB | 21.91 MB / 4.99 MB / 3.77 MB | 7.36 MB / 2.05 MB / 1.36 MB |

*(Decimal MB = 10^6 B, KB = 10^3 B; exact byte counts are recorded by `tools/web/bench.zig --json`.)*

### Compile wall-times (`zig -fllvm` vs `wazig -fno-llvm`)

`tools/wazig/build.py` evaluates `build.zig` once in Wasmtime (`~27.8 s` cold
configure; cached when build inputs are unchanged) and invokes `wazig`
(`-fno-llvm`) per artifact. In `ReleaseFast`, `wazig` compiles **1.52×–1.60×
faster** than `zig` (`-fllvm +simd128`):

| step (`-Dweb-optimize=...`) | `zig -fllvm` (`+simd128`) compile | `wazig -fno-llvm` (`+simd128`) compile | `zig` incremental edit | `wazig` incremental edit |
|---|---:|---:|---:|---:|
| `web-parity` (`Debug`) | 5.14 s | 12.97 s | 5.15 s | 11.96 s |
| `web-parity` (`ReleaseSmall`) | 10.07 s | 10.00 s | 9.12 s | 8.93 s |
| `web-parity` (`ReleaseFast`) | 18.56 s | 11.62 s (**1.60×**) | 18.81 s | 10.65 s (**1.77×**) |
| `web-demo` (`ReleaseSmall`) | 13.78 s | 22.38 s | 13.38 s | 21.40 s |
| `web-demo` (`ReleaseFast`) | 28.81 s | 26.74 s (**1.08×**) | — | 25.98 s |
| `web-bench` (`ReleaseFast` + `ReleaseSmall`) | 30.89 s | 20.34 s (**1.52×**) | 30.02 s | 19.45 s (**1.54×**) |
| `test-bin` (`Debug`) | 28.23 s | 89.97 s | — | 89.51 s |
| `test-bin` (`ReleaseFast`) | 137.27 s | 86.08 s (**1.59×**) | — | 86.10 s |

### Headless WASI UI & CPU rasterizer benchmarks (`tools/web/bench.zig`)

`tools/web/bench.zig` renders 6 offscreen `800×600 @ 1×` scenes through
`ui.Tester` + `ui.PixelCanvas` + embedded DejaVuSans (4 warm-up + 60 measured
frames under Wasmtime 50.0.1). Every scene produces **100% bit-identical
FNV-1a `u64` pixel hashes** across `zig` (`-Dsimd128=false`), `zig`
(`+simd128`), and `wazig` (`-fno-llvm +simd128`) in both `ReleaseFast` and
`ReleaseSmall`, before and after optimization:

#### `ReleaseFast` median frame times (ms)

| scene | items | FNV-1a hash | `wazig` pre total | `wazig` post total (ui / raster) | `wazig` speedup | `zig +simd128` post total (ui / raster) | `zig -Dsimd128=false` post total |
|---|---:|---|---:|---:|---:|---:|---:|
| `boxes` | 1,001 | `56ddfded68de1e25` | 173.12 ms | **46.44 ms** (0.259 / 46.18) | **3.73×** | 47.59 ms (0.202 / 47.39) | 78.67 ms |
| `text` | 1,019 | `66b32adcf93303df` | 7.88 ms | **3.88 ms** (0.655 / 3.23) | **2.03×** | 4.35 ms (0.453 / 3.87) | 4.07 ms |
| `scroll` | 1,691 | `4477de3f7caad919` | 11.56 ms | **3.93 ms** (1.401 / 2.53) | **2.94×** | 3.92 ms (1.015 / 2.89) | 3.81 ms |
| `list` | 932 | `493df0b6a0373c9e` | 8.19 ms | **1.78 ms** (0.253 / 1.53) | **4.60×** | 3.43 ms (0.170 / 3.26) | 1.86 ms |
| `dashboard` | 268 | `38b5db84be713fed` | 74.52 ms | **15.11 ms** (0.130 / 14.98) | **4.93×** | 16.22 ms (0.085 / 16.13) | 22.93 ms |
| `motion` | 184 | `2132efebe1d8df40` | 11.15 ms | **3.36 ms** (0.134 / 3.22) | **3.32×** | 3.52 ms (0.097 / 3.43) | 3.48 ms |

#### `ReleaseSmall` median frame times (ms)

| scene | `wazig` pre total | `wazig` post total (ui / raster) | `wazig` speedup | `zig +simd128` post total | `zig -Dsimd128=false` post total |
|---|---:|---:|---:|---:|---:|
| `boxes` | 211.90 ms | **49.39 ms** (0.317 / 49.08) | **4.29×** | 51.60 ms | 75.05 ms |
| `text` | 8.54 ms | **4.80 ms** (0.761 / 4.05) | **1.78×** | 4.43 ms | 4.43 ms |
| `scroll` | 12.12 ms | **4.69 ms** (1.604 / 3.08) | **2.59×** | 4.47 ms | 4.46 ms |
| `list` | 8.41 ms | **2.14 ms** (0.306 / 1.83) | **3.92×** | 3.21 ms | 2.31 ms |
| `dashboard` | 91.26 ms | **17.84 ms** (0.181 / 17.66) | **5.12×** | 17.46 ms | 22.02 ms |
| `motion` | 11.49 ms | **3.49 ms** (0.149 / 3.34) | **3.29×** | 3.98 ms | 3.96 ms |

### Key Wasm & `-fno-llvm` optimizations

- **Pointer-borrowed UI & raster records:** Replaced large by-value struct/union parameters (`Style` ~350 B, `Node` ~450 B, `Motion` ~440 B, `Band` ~148 B, `Mask` ~92 B, `TextStyle`) with `*const` borrows and in-place `Context.nodes` slot initialization across `layout.zig`, `paint.zig`, `scroll.zig`, `context.zig`, `div.zig`, `widgets.zig`, `motion/`, `text*.zig`, and `raster*.zig`, cutting `wazig` layout time by **1.31×–1.85×**.
- **Two-tier horizontal quad spans:** Added unrotated interior scanline span fast paths in `src/ui/raster.zig` (`@memset` for opaque `c[3] == 1`, tight premultiplied span blend for translucent fills), speeding up `list` and `scroll` rasterization by **3.8×–5.2×**.
- **Row-hoisted + `@Vector(4, f32)` SIMD Gaussian shadows:** Hoisted per-scanline vertical shadow weights into `ShadowRow` and vectorized curved 8-tap Gaussian evaluation with exact IEEE-754 `@Vector(4, f32)` `erf4` in `src/ui/raster_shapes.zig`, speeding up `boxes` and `dashboard` by **3.7×–5.1×** while maintaining bit-exact parity with scalar `erf`.

