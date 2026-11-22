import { createGPU } from "./gpu.js";
import { createWebGL2, getWebGL2Context } from "./webgl2.js";
import { createWASI } from "./wasi.js";
import { createHost } from "./host.js";

function isWebGL2Device(dev) {
  return Boolean(
    dev && ((typeof WebGL2RenderingContext !== "undefined" && dev instanceof WebGL2RenderingContext) ||
      typeof dev.createVertexArray === "function"),
  );
}

async function acquireWebGPUAdapter() {
  const navGpu = globalThis.navigator?.gpu;
  if (!navGpu?.requestAdapter) return null;
  let adapter = null;
  try { adapter = await navGpu.requestAdapter({ powerPreference: "high-performance" }); } catch {}
  if (!adapter) {
    try { adapter = await navGpu.requestAdapter({ forceFallbackAdapter: true }); } catch {}
  }
  return adapter;
}

async function acquireWebGPUDevice(withFeatures = false) {
  const adapter = await acquireWebGPUAdapter();
  if (!adapter) throw new Error("WebGPU is unavailable");
  if (!withFeatures) return adapter.requestDevice();
  const requiredFeatures = ["timestamp-query", "float32-filterable", "texture-formats-tier1"]
    .filter(f => adapter.features?.has(f));
  return adapter.requestDevice({ requiredFeatures });
}

function createScratchCanvas() {
  if (typeof OffscreenCanvas !== "undefined") return new OffscreenCanvas(1, 1);
  if (typeof document !== "undefined") return document.createElement("canvas");
  throw new Error("No canvas available for WebGL2");
}

// Reactor loader, usable in either the main thread or a dedicated Worker.
// Inject a GPUDevice or WebGL2RenderingContext to share it with a compositor.
export async function load({
  url,
  gpu: gpuPref = "auto",
  canvas,
  device,
  format,
  imports = {},
  asyncPipelines = false,
}) {
  if (gpuPref !== "auto" && gpuPref !== "webgpu" && gpuPref !== "webgl2") {
    throw new Error(`Unsupported GPU preference: ${gpuPref}`);
  }
  let useWebGL2 = gpuPref === "webgl2" || (gpuPref === "auto" && isWebGL2Device(device));
  let ownsDevice = false;
  let activeDevice = device;

  if (useWebGL2) {
    if (!activeDevice) activeDevice = getWebGL2Context(canvas ?? createScratchCanvas());
  } else {
    try {
      if (!activeDevice) {
        activeDevice = await acquireWebGPUDevice(false);
        ownsDevice = true;
      }
    } catch (error) {
      if (gpuPref === "webgpu") throw error;
      useWebGL2 = true;
      activeDevice = getWebGL2Context(canvas ?? createScratchCanvas());
    }
  }

  let instance;
  const runtime = {};
  const done = (token, status) => {
    instance.exports.nanoui_gpu_done(token, status);
    runtime.onReadback?.(status);
  };
  const gpu = useWebGL2
    ? createWebGL2({ gl: activeDevice, canvas, memory: () => instance.exports.memory, done })
    : createGPU({
        device: activeDevice,
        format: format ?? globalThis.navigator?.gpu?.getPreferredCanvasFormat?.() ?? "bgra8unorm",
        asyncPipelines,
        memory: () => instance.exports.memory,
        done,
      });

  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Loading wasm: HTTP ${response.status}`);
    ({ instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {
      wasi_snapshot_preview1: createWASI(() => instance.exports.memory),
      nanoui_gpu: gpu.imports,
      ...imports,
    }));
    instance.exports._initialize?.();
  } catch (error) {
    gpu.dispose();
    if (ownsDevice && !useWebGL2) activeDevice.destroy();
    throw error;
  }

  Object.assign(runtime, {
    backend: gpu.backend,
    instance,
    exports: instance.exports,
    gpu,
  });
  Object.defineProperty(runtime, "memory", { get: () => instance.exports.memory, enumerable: true, configurable: true });
  Object.defineProperty(runtime, "device", { get: () => gpu.device, enumerable: true, configurable: true });
  return runtime;
}

export async function start(options) {
  const { canvas, gpu: gpuPref = "auto", ime = "auto" } = options;
  if (gpuPref !== "auto" && gpuPref !== "webgpu" && gpuPref !== "webgl2") {
    throw new Error(`Unsupported GPU preference: ${gpuPref}`);
  }
  const acquireDevice = () => acquireWebGPUDevice(true);
  let useWebGL2 = gpuPref === "webgl2" || (gpuPref === "auto" && isWebGL2Device(options.device));
  let device = options.device;
  let gl = null;
  let ownsDevice = false;

  if (useWebGL2) {
    gl = device ?? getWebGL2Context(canvas);
  } else {
    try {
      if (!device) {
        device = await acquireDevice();
        ownsDevice = true;
      }
      const probeCtx = canvas?.getContext?.("webgpu");
      if (!probeCtx) throw new Error("Canvas WebGPU context is unavailable");
    } catch (webgpuError) {
      if (ownsDevice && device) {
        device.destroy();
        device = null;
        ownsDevice = false;
      }
      if (gpuPref === "webgpu") throw webgpuError;
      useWebGL2 = true;
      gl = getWebGL2Context(canvas);
    }
  }

  const format = useWebGL2
    ? "rgba8unorm"
    : (options.format ?? globalThis.navigator?.gpu?.getPreferredCanvasFormat?.() ?? "bgra8unorm");
  const host = createHost({
    ...options,
    canvas,
    ime,
    format,
    ownsDevice: useWebGL2 ? false : !options.device,
    acquireDevice,
  });

  let runtime;
  try {
    runtime = await load({
      ...options,
      gpu: useWebGL2 ? "webgl2" : "webgpu",
      canvas,
      asyncPipelines: !useWebGL2,
      device: useWebGL2 ? gl : device,
      format,
      imports: { ...options.imports, nanoui_web: host.imports },
    });
    host.attach(runtime);
    try { runtime.exports._start(); }
    catch (error) { if (error !== host.unwind) throw error; }
    await runtime.gpu.ready();
    host.listen();
    return Object.assign(runtime, {
      host,
      setDevice: host.setDevice,
      requestFrame: () => host.requestFrame(),
      destroy() {
        host.destroy();
      },
    });
  } catch (error) {
    host.destroy();
    if (!runtime && ownsDevice && !useWebGL2 && device) device.destroy();
    throw error;
  }
}
