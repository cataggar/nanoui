import { createExternalSources } from "./external.js";
import { createPassOps } from "./webgl2_pass.js";

const FORMATS = ["bgra8unorm", "rgba8unorm", "r8unorm", "rgba16float"];
const STORAGE_TEX_WIDTH = 1024, STORAGE_ROW_BYTES = 16384, STORAGE_ROW_FLOATS = 4096;

export const WEBGL2_CONTEXT_ATTRIBUTES = {
  alpha: false, premultipliedAlpha: true, antialias: false, depth: false, stencil: false,
  preserveDrawingBuffer: false, powerPreference: "high-performance",
};

export function getWebGL2Context(canvas) {
  const gl = canvas?.getContext?.("webgl2", WEBGL2_CONTEXT_ATTRIBUTES);
  if (!gl) throw new Error("WebGL2 is unavailable");
  return gl;
}

export function createWebGL2({ gl, canvas = null, memory, done, generation = 1 }) {
  const values = [null], generations = [0], serials = [0], immutable = [false], free = [], frame = [], diagnostics = [];
  let serial = 0, targetCanvas = canvas ?? gl.canvas ?? null, copyExternal = false;
  let swizzleScratch = new Uint8Array(0), resizeCanvas = null, onTiming = () => {};
  const externalSources = createExternalSources();
  const stats = {
    frames: 0, passes: 0, draws: 0, uploads: 0, uploadBytes: 0,
    upload_bytes: 0, encode_ms: 0, gpu_ms: null, timestamped: false, samples: [],
  };
  let encodeStart = 0, frameDraws = 0, frameUploaded = 0;

  const objects = {
    put(value, immutableContents = false) {
      const h = free.pop() ?? values.length;
      values[h] = value; generations[h] = generation; serials[h] = ++serial;
      immutable[h] = immutableContents || (typeof VideoFrame !== "undefined" && value instanceof VideoFrame);
      return h;
    },
    get(h) {
      if (!h || !values[h]) throw new Error(`Invalid WebGL2 handle ${h}`);
      return values[h];
    },
    drop(h) { if (h && values[h]) { values[h] = null; free.push(h); } },
    get size() { return values.length - free.length - 1; },
  };

  let deviceHandle = objects.put(gl);
  const get = h => objects.get(h);
  const transient = value => { const h = objects.put(value); frame.push(h); return h; };
  const bytes = (ptr, len) => new Uint8Array(memory().buffer, ptr >>> 0, len >>> 0);
  const words = (ptr, len) => new Uint32Array(memory().buffer, ptr >>> 0, len >>> 0);
  const halfFloats = (ptr, byteLen) => {
    const p = ptr >>> 0, count = byteLen >>> 1;
    return (p & 1) === 0 ? new Uint16Array(memory().buffer, p, count) : new Uint16Array(bytes(p, count * 2).slice().buffer);
  };
  const canDelete = (ownerGl, ownerGen) => !ownerGl.isContextLost() && (ownerGl !== gl || ownerGen === generation);
  const recordUpload = n => { stats.uploads++; stats.uploadBytes += n; frameUploaded += n; };

  let vao = null, nearestClampSampler = null, linearClampSampler = null, dummyTex2D = null, canvasTarget = null;

  function makeSampler(ctx, filter) {
    const s = ctx.createSampler();
    for (const p of [ctx.TEXTURE_MIN_FILTER, ctx.TEXTURE_MAG_FILTER]) ctx.samplerParameteri(s, p, filter);
    for (const p of [ctx.TEXTURE_WRAP_S, ctx.TEXTURE_WRAP_T, ctx.TEXTURE_WRAP_R]) ctx.samplerParameteri(s, p, ctx.CLAMP_TO_EDGE);
    return s;
  }

  function setup2DParams(filter) {
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  }

  function resetUnpack() {
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, 0);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, 0);
  }

  function initGLState() {
    gl.getExtension?.("EXT_color_buffer_float");
    gl.getExtension?.("OES_texture_float_linear");
    vao = gl.createVertexArray(); gl.bindVertexArray(vao);
    gl.disable(gl.CULL_FACE); gl.disable(gl.DEPTH_TEST); gl.disable(gl.STENCIL_TEST);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1); gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
    resetUnpack();
    nearestClampSampler = makeSampler(gl, gl.NEAREST);
    linearClampSampler = makeSampler(gl, gl.LINEAR);
    dummyTex2D = gl.createTexture();
    gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D, dummyTex2D);
    setup2DParams(gl.NEAREST);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
    if (!gl.isContextLost()) { for (let i = 0; i < 16 && gl.getError() !== gl.NO_ERROR; i++) {} }
  }

  function destroyCanvasTarget(ctx = gl, allowDelete = !ctx.isContextLost()) {
    if (!canvasTarget) return;
    if (allowDelete && canvasTarget.fbo) ctx.deleteFramebuffer(canvasTarget.fbo);
    if (allowDelete && canvasTarget.glTex) ctx.deleteTexture(canvasTarget.glTex);
    canvasTarget = null;
  }

  function destroyInternalGL(ctx = gl, allowDelete = !ctx.isContextLost()) {
    destroyCanvasTarget(ctx, allowDelete);
    if (allowDelete) {
      if (dummyTex2D) ctx.deleteTexture(dummyTex2D);
      if (nearestClampSampler) ctx.deleteSampler(nearestClampSampler);
      if (linearClampSampler) ctx.deleteSampler(linearClampSampler);
      if (vao) ctx.deleteVertexArray(vao);
    }
    dummyTex2D = nearestClampSampler = linearClampSampler = vao = null;
  }

  function ensureFbo(tex) {
    if (tex.fbo) return tex.fbo;
    const fbo = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex.glTex, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    tex.fbo = fbo; tex.fboGl = gl; tex.fboGen = generation;
    return fbo;
  }

  function ensureCanvasTarget() {
    const w = Math.max(1, gl.drawingBufferWidth || targetCanvas?.width || 1);
    const h = Math.max(1, gl.drawingBufferHeight || targetCanvas?.height || 1);
    if (!canvasTarget || canvasTarget.width !== w || canvasTarget.height !== h) {
      destroyCanvasTarget(gl, !gl.isContextLost());
      const glTex = gl.createTexture();
      gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D, glTex);
      setup2DParams(gl.LINEAR);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      canvasTarget = { kind: "texture", glTex, fbo: null, width: w, height: h, depth: 1, dimension: 2, target: gl.TEXTURE_2D, format: "rgba8unorm", formatIndex: 1, srgb: false, isCanvas: true };
      ensureFbo(canvasTarget);
    }
    return canvasTarget;
  }

  initGLState();

  const passOps = createPassOps({
    get gl() { return gl; },
    get generation() { return generation; },
    get vao() { return vao; },
    get nearestClampSampler() { return nearestClampSampler; },
    get linearClampSampler() { return linearClampSampler; },
    get dummyTex2D() { return dummyTex2D; },
    get canvasTarget() { return canvasTarget; },
    objects, get, transient, bytes, words, done, diagnostics, stats, canDelete, ensureFbo,
    beginEncode() { encodeStart = performance.now(); frameDraws = 0; },
    recordDraw() { stats.draws++; frameDraws++; },
    finishSubmit() {
      stats.frames++;
      stats.encode_ms = performance.now() - encodeStart;
      stats.upload_bytes = frameUploaded; frameUploaded = 0;
      stats.samples.push({ encode_ms: stats.encode_ms, gpu_ms: null, draws: frameDraws, upload_bytes: stats.upload_bytes });
      if (stats.samples.length > 512) stats.samples.shift();
      externalSources.submitted();
      for (const h of frame) {
        if (values[h]?.transientDestroy) values[h].destroy();
        objects.drop(h);
      }
      frame.length = 0;
    },
  });

  const imports = {
    backend: () => 1,
    device: () => deviceHandle,
    device_generation: () => generation,
    preferred_format: () => 1,
    canvas_texture: () => transient(ensureCanvasTarget()),
    canvas_view: h => transient({ kind: "view", texture: get(h) }),
    release(h) { get(h).destroy?.(); objects.drop(h); },
    buffer_create(size, usage) {
      const ownerGl = gl, ownerGen = generation;
      if (usage & 64) {
        const byteLength = Math.max(256, Math.ceil(Math.max(size >>> 0, 1) / 256) * 256);
        const glBuf = gl.createBuffer();
        gl.bindBuffer(gl.UNIFORM_BUFFER, glBuf);
        gl.bufferData(gl.UNIFORM_BUFFER, byteLength, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.UNIFORM_BUFFER, null);
        return objects.put({
          kind: "ubo", glBuf, byteLength, shadow: new Uint8Array(byteLength),
          destroy() { if (glBuf && canDelete(ownerGl, ownerGen)) ownerGl.deleteBuffer(glBuf); },
        });
      }
      const rows = Math.max(1, Math.ceil(Math.max(size >>> 0, 16) / STORAGE_ROW_BYTES));
      const shadow = new Uint8Array(rows * STORAGE_ROW_BYTES);
      const glTex = gl.createTexture();
      gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D, glTex);
      setup2DParams(gl.NEAREST);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, STORAGE_TEX_WIDTH, rows, 0, gl.RGBA, gl.FLOAT, null);
      return objects.put({
        kind: "storage", glTex, rows, shadow, shadowF32: new Float32Array(shadow.buffer),
        destroy() { if (glTex && canDelete(ownerGl, ownerGen)) ownerGl.deleteTexture(glTex); },
      });
    },
    buffer_write(h, offset, ptr, len) {
      const off = offset >>> 0, n = len >>> 0;
      recordUpload(n);
      if (n === 0) return;
      const buf = get(h), src = bytes(ptr, n);
      if (buf.kind === "ubo") {
        gl.bindBuffer(gl.UNIFORM_BUFFER, buf.glBuf);
        if (off + n > buf.byteLength) {
          const nextShadow = new Uint8Array(Math.max(256, Math.ceil((off + n) / 256) * 256));
          nextShadow.set(buf.shadow); nextShadow.set(src, off);
          buf.shadow = nextShadow; buf.byteLength = nextShadow.byteLength;
          gl.bufferData(gl.UNIFORM_BUFFER, nextShadow, gl.DYNAMIC_DRAW);
        } else {
          buf.shadow.set(src, off);
          gl.bufferSubData(gl.UNIFORM_BUFFER, off, src);
        }
        gl.bindBuffer(gl.UNIFORM_BUFFER, null);
        return;
      }
      gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D, buf.glTex);
      gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
      if (off + n > buf.shadow.byteLength) {
        const nextRows = Math.max(1, Math.ceil((off + n) / STORAGE_ROW_BYTES));
        const nextShadow = new Uint8Array(nextRows * STORAGE_ROW_BYTES);
        nextShadow.set(buf.shadow); nextShadow.set(src, off);
        buf.shadow = nextShadow; buf.shadowF32 = new Float32Array(nextShadow.buffer); buf.rows = nextRows;
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, STORAGE_TEX_WIDTH, nextRows, 0, gl.RGBA, gl.FLOAT, buf.shadowF32, 0);
        return;
      }
      buf.shadow.set(src, off);
      const rowStart = off >>> 14, rowCount = ((off + n - 1) >>> 14) - rowStart + 1;
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, rowStart, STORAGE_TEX_WIDTH, rowCount, gl.RGBA, gl.FLOAT, buf.shadowF32, rowStart * STORAGE_ROW_FLOATS);
    },
    texture_create(ptr) {
      const ownerGl = gl, ownerGen = generation, [width, height, f, usage, depth, dimension] = words(ptr, 6);
      const glTex = gl.createTexture();
      gl.activeTexture(gl.TEXTURE7);
      if (dimension === 3) {
        gl.bindTexture(gl.TEXTURE_3D, glTex);
        for (const p of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_3D, p, gl.LINEAR);
        for (const p of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T, gl.TEXTURE_WRAP_R]) gl.texParameteri(gl.TEXTURE_3D, p, gl.CLAMP_TO_EDGE);
        gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGBA16F, width, height, depth, 0, gl.RGBA, gl.HALF_FLOAT, null);
        return objects.put({
          kind: "texture", glTex, fbo: null, width, height, depth, dimension: 3, target: gl.TEXTURE_3D,
          format: FORMATS[f] ?? "rgba16float", formatIndex: f, srgb: false,
          destroy() { if (glTex && canDelete(ownerGl, ownerGen)) ownerGl.deleteTexture(glTex); },
        });
      }
      gl.bindTexture(gl.TEXTURE_2D, glTex);
      setup2DParams(gl.LINEAR);
      gl.texImage2D(gl.TEXTURE_2D, 0, f === 2 ? gl.R8 : f === 3 ? gl.RGBA16F : gl.RGBA8, width, height, 0, f === 2 ? gl.RED : gl.RGBA, f === 3 ? gl.HALF_FLOAT : gl.UNSIGNED_BYTE, null);
      const texObj = {
        kind: "texture", glTex, fbo: null, fboGl: ownerGl, fboGen: ownerGen, width, height, depth: 1, dimension: 2,
        target: gl.TEXTURE_2D, format: FORMATS[f] ?? "rgba8unorm", formatIndex: f, srgb: false,
        destroy() {
          if (this.fbo && canDelete(this.fboGl ?? ownerGl, this.fboGen ?? ownerGen)) (this.fboGl ?? ownerGl).deleteFramebuffer(this.fbo);
          if (glTex && canDelete(ownerGl, ownerGen)) ownerGl.deleteTexture(glTex);
        },
      };
      if ((usage & 16) && f <= 1) ensureFbo(texObj);
      return objects.put(texObj);
    },
    texture_write(h, ptr, src, len) {
      const [width, height, bytesPerRow, depth, x, y] = words(ptr, 6), n = len >>> 0, sPtr = src >>> 0;
      recordUpload(n);
      if (width === 0 || height === 0 || n === 0) return;
      const tex = get(h);
      gl.activeTexture(gl.TEXTURE7); resetUnpack();
      if (tex.dimension === 3) {
        gl.bindTexture(gl.TEXTURE_3D, tex.glTex);
        const rowPixels = bytesPerRow === width * 8 ? 0 : Math.floor(bytesPerRow / 8);
        if (rowPixels) gl.pixelStorei(gl.UNPACK_ROW_LENGTH, rowPixels);
        gl.texSubImage3D(gl.TEXTURE_3D, 0, x, y, 0, width, height, depth, gl.RGBA, gl.HALF_FLOAT, halfFloats(sPtr, n));
        if (rowPixels) gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
        return;
      }
      gl.bindTexture(gl.TEXTURE_2D, tex.glTex);
      if (tex.formatIndex === 0) {
        const needed = width * height * 4, raw = bytes(sPtr, n);
        if (swizzleScratch.length < needed) swizzleScratch = new Uint8Array(needed);
        for (let row = 0; row < height; row++) {
          for (let col = 0, s = row * bytesPerRow, d = row * width * 4; col < width; col++, s += 4, d += 4) {
            swizzleScratch[d] = raw[s + 2]; swizzleScratch[d + 1] = raw[s + 1];
            swizzleScratch[d + 2] = raw[s]; swizzleScratch[d + 3] = raw[s + 3];
          }
        }
        gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, width, height, gl.RGBA, gl.UNSIGNED_BYTE, swizzleScratch.subarray(0, needed));
        return;
      }
      const bpp = tex.formatIndex === 2 ? 1 : tex.formatIndex === 3 ? 8 : 4;
      const rowPixels = bytesPerRow === width * bpp ? 0 : Math.floor(bytesPerRow / bpp);
      if (rowPixels) gl.pixelStorei(gl.UNPACK_ROW_LENGTH, rowPixels);
      if (tex.formatIndex === 3) gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, width, height, gl.RGBA, gl.HALF_FLOAT, halfFloats(sPtr, n));
      else gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, width, height, tex.formatIndex === 2 ? gl.RED : gl.RGBA, gl.UNSIGNED_BYTE, bytes(sPtr, n));
      if (rowPixels) gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
    },
    texture_view: h => objects.put({ kind: "view", texture: get(h) }),
    texture_srgb: h => { const t = get(h); return t.srgb || (typeof t.format === "string" && t.format.endsWith("-srgb")) ? 1 : 0; },
    texture_format: h => {
      const t = get(h);
      return (t.srgb || (typeof t.format === "string" && t.format.endsWith("-srgb"))) ? 3 : (t.formatIndex ?? Math.max(0, FORMATS.indexOf(t.format)));
    },
    resource_generation: h => values[h] ? generations[h] : 0,
    resource_serial: h => values[h] ? serials[h] : 0,
    resource_content_serial: h => values[h] && generations[h] === generation && immutable[h] ? serials[h] : 0,
    external_import(h) {
      const source = get(h);
      if (copyExternal || (typeof HTMLVideoElement !== "undefined" && source instanceof HTMLVideoElement)) return 0;
      const ownerGl = gl, ownerGen = generation;
      try {
        const src = externalSources.get(source), glTex = gl.createTexture();
        gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D, glTex);
        setup2DParams(gl.LINEAR); resetUnpack();
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, src);
        return transient({ kind: "external", glTex, transientDestroy: true, destroy() { if (glTex && canDelete(ownerGl, ownerGen)) ownerGl.deleteTexture(glTex); } });
      } catch { return 0; }
    },
    external_copy(h, texture) {
      try {
        let src = externalSources.get(get(h), true);
        const dst = get(texture);
        const srcW = src.displayWidth ?? src.visibleRect?.width ?? src.videoWidth ?? src.width;
        const srcH = src.displayHeight ?? src.visibleRect?.height ?? src.videoHeight ?? src.height;
        if (srcW && srcH && (srcW !== dst.width || srcH !== dst.height)) {
          if (!resizeCanvas) resizeCanvas = new OffscreenCanvas(dst.width, dst.height);
          if (resizeCanvas.width !== dst.width) resizeCanvas.width = dst.width;
          if (resizeCanvas.height !== dst.height) resizeCanvas.height = dst.height;
          const ctx2d = resizeCanvas.getContext("2d");
          ctx2d.clearRect(0, 0, dst.width, dst.height);
          ctx2d.drawImage(src, 0, 0, dst.width, dst.height);
          src = resizeCanvas;
        }
        gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D, dst.glTex); resetUnpack();
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, src);
        return 1;
      } catch { return 0; }
    },
    ...passOps.imports,
  };

  return {
    backend: "webgl2", imports, objects, diagnostics,
    get device() { return gl; },
    get generation() { return generation; },
    get stats() { return stats; },
    onTiming(cb) { onTiming = cb; void onTiming; },
    async ready() { if (diagnostics.length) throw new Error(diagnostics.join("\n")); },
    dispose() { externalSources.destroy(); resizeCanvas = null; destroyInternalGL(gl, !gl.isContextLost()); },
    forceExternalCopy(on) { copyExternal = Boolean(on); },
    setCanvas(c) { if (c) targetCanvas = c.canvas ?? c; },
    setDevice(nextGl) {
      externalSources.destroy();
      destroyInternalGL(gl, nextGl !== gl && !gl.isContextLost());
      objects.drop(deviceHandle);
      gl = nextGl; targetCanvas = nextGl.canvas ?? targetCanvas;
      generation++; diagnostics.length = 0; passOps.resetPassState();
      deviceHandle = objects.put(nextGl); initGLState();
    },
    async check() {
      await this.ready();
      if (!gl.isContextLost()) {
        gl.flush();
        for (let i = 0; i < 16; i++) {
          const err = gl.getError();
          if (err === gl.NO_ERROR) break;
          diagnostics.push(`WebGL2 error: 0x${err.toString(16)}`);
        }
      }
      if (diagnostics.length) throw new Error(diagnostics.join("\n"));
    },
    wrapTexture(glTex, { width, height, format = "rgba8unorm", srgb = false, depth = 1, dimension = 2 }) {
      const ownerGl = gl, ownerGen = generation;
      const isSrgb = Boolean(srgb || (typeof format === "string" && format.endsWith("-srgb")));
      const formatIndex = typeof format === "number" ? format : isSrgb ? 3 : Math.max(0, FORMATS.indexOf(format));
      return {
        kind: "texture", glTex, fbo: null, fboGl: ownerGl, fboGen: ownerGen, width, height, depth, dimension,
        target: dimension === 3 ? gl.TEXTURE_3D : gl.TEXTURE_2D,
        format: typeof format === "string" ? format : (FORMATS[format] ?? "rgba8unorm"),
        formatIndex, srgb: isSrgb, borrowed: true,
        destroy() { if (this.fbo && canDelete(this.fboGl ?? ownerGl, this.fboGen ?? ownerGen)) (this.fboGl ?? ownerGl).deleteFramebuffer(this.fbo); },
      };
    },
  };
}
