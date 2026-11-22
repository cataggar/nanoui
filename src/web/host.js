// Canvas lifecycle, keyboard/IME/clipboard attachment, and event delivery.
import { createInput } from "./input.js";

const clipboardDecoder = new TextDecoder();
const CURSORS = [
  "default", "pointer", "text", "ew-resize", "ns-resize",
  "grab", "grabbing", "not-allowed", "crosshair", "default",
];

export function createHost(canvasOrOptions, maybeOptions = {}) {
  const isOptionsBag = Boolean(
    canvasOrOptions && typeof canvasOrOptions === "object" &&
    "canvas" in canvasOrOptions && typeof canvasOrOptions.getContext !== "function" &&
    typeof canvasOrOptions.addEventListener !== "function",
  );
  const options = isOptionsBag ? canvasOrOptions : maybeOptions;
  const canvas = isOptionsBag ? options.canvas : canvasOrOptions;
  let runtime, context, frame = null, timer = null, observer, media;
  let inputController = null, lastClipboardText = "", lastCursor = "default", webglContextWatched = false;
  let stopped = false, lost = false, paused = true, generation = 0, forceRecovery = false;
  const listeners = [];
  const inputEvents = [];
  const unwind = Symbol("nanoui.run");
  const stats = { callbacks: 0 };
  const raf = options.requestAnimationFrame ?? globalThis.requestAnimationFrame.bind(globalThis);
  const caf = options.cancelAnimationFrame ?? globalThis.cancelAnimationFrame.bind(globalThis);
  const on = (object, name, fn, opts) => { object.addEventListener(name, fn, opts); listeners.push(() => object.removeEventListener(name, fn, opts)); };
  const getMemory = () => options.memory?.() ?? runtime?.exports?.memory ?? runtime?.memory ?? null;
  const isWebGL2 = () => runtime?.backend === "webgl2" || runtime?.gpu?.imports?.backend?.() === 1;

  function syncCursor() {
    if (!canvas?.style || !runtime?.exports?.nanoui_web_cursor) return;
    const next = CURSORS[runtime.exports.nanoui_web_cursor()] ?? "default";
    if (next !== lastCursor) {
      lastCursor = next;
      canvas.style.cursor = next;
    }
  }

  function runFrame(time = performance.now()) {
    if (stopped || lost || !runtime) return 0;
    // Preserve button transitions across frames. A quick down/up in
    // one browser task must still produce a pressed frame for drags.
    while (inputEvents.length) {
      const event = inputEvents.shift();
      if (event[0] === "pinch") runtime.exports.nanoui_web_pinch(...event.slice(1));
      else if (event[0] === "key") runtime.exports.nanoui_web_key(...event.slice(1));
      else runtime.exports.nanoui_web_pointer(...event);
      if (event[0] !== 0 && !(event[0] === "key" && event[1] === 3)) break;
    }
    const submitted = runtime.gpu?.stats?.frames;
    const more = runtime.exports.nanoui_web_frame(time);
    const sample = runtime.gpu?.stats?.samples?.at(-1);
    if (sample && runtime.gpu.stats.frames !== submitted) {
      sample.log_index = runtime.exports.nanoui_web_last_record();
    }
    syncCursor();
    inputController?.syncAfterFrame();
    return more;
  }

  function flushFrame() {
    if (stopped || lost || paused || !runtime) return false;
    const more = runFrame(performance.now());
    if (more || inputEvents.length) request();
    return true;
  }

  function request() {
    if (stopped || lost || paused || frame !== null) return;
    if (timer !== null) { clearTimeout(timer); timer = null; }
    frame = raf(time => {
      frame = null;
      stats.callbacks++;
      // A device replacement pauses until its pipelines compile; a frame
      // queued before it must not draw with the placeholders.
      if (!stopped && !lost && !paused) {
        const more = runFrame(time);
        if (more || inputEvents.length) request();
      }
    });
  }
  function after(ms) {
    if (stopped || lost || frame !== null || timer !== null) return;
    timer = setTimeout(() => { timer = null; request(); }, Math.max(0, ms));
  }
  function resize(width, height, scale = options.scale ?? globalThis.devicePixelRatio ?? 1) {
    if (stopped || !runtime) return;
    if (width === undefined) {
      const rect = canvas.getBoundingClientRect?.();
      width = Math.round((rect?.width ?? canvas.width / scale) * scale);
      height = Math.round((rect?.height ?? canvas.height / scale) * scale);
    }
    if (width < 1 || height < 1) return;
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
    runtime.exports.nanoui_web_resize(width, height, scale);
  }
  function pointer(kind, x, y, button = 0, mods = 0, clicks = 1) {
    if (stopped || lost) return;
    const event=[kind,x,y,button,mods,clicks];
    if(kind===0 && inputEvents.at(-1)?.[0]===0)inputEvents[inputEvents.length-1]=event;
    else inputEvents.push(event);
    request();
  }
  function pinch(x, y, factor, dx = 0, dy = 0) {
    if (stopped || lost || !Number.isFinite(factor) || factor <= 0) return;
    const last = inputEvents.at(-1);
    if (last?.[0] === "pinch") {
      last[1] = x;
      last[2] = y;
      last[3] *= factor;
      last[4] += dx;
      last[5] += dy;
    } else inputEvents.push(["pinch", x, y, factor, dx, dy]);
    request();
  }
  function wheel(x, y, dx, dy) {
    if (!stopped && !lost) runtime.exports.nanoui_web_wheel(x, y, dx, dy);
  }
  function key(kind, code, mods, typed = 0) {
    if (stopped) return;
    if (kind === 2) {
      // If focus is gone, releases still need to arrive after recovery.
      if (lost) inputEvents.length = 0;
    } else if (lost) return;
    inputEvents.push(["key", kind, code, mods, typed]);
    request();
  }
  function configure() {
    if (!runtime?.gpu) return;
    if (isWebGL2()) {
      runtime.gpu.setCanvas(canvas);
      return;
    }
    context.configure({ device: runtime.gpu.device, format: options.format,
      alphaMode: "opaque", usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST });
    runtime.gpu.setCanvas(context);
  }
  function watchDevice() {
    if (isWebGL2()) {
      if (webglContextWatched || !canvas?.addEventListener) return;
      webglContextWatched = true;
      on(canvas, "webglcontextlost", e => {
        e.preventDefault();
        if (stopped) return;
        lost = true;
        runtime?.exports?.nanoui_web_device_lost?.();
        if (frame !== null) { caf(frame); frame = null; }
        if (timer !== null) { clearTimeout(timer); timer = null; }
        options.onDeviceLost?.({ backend: "webgl2", reason: "webglcontextlost" });
      });
      on(canvas, "webglcontextrestored", () => {
        if (stopped || !runtime?.gpu) return;
        setDevice(runtime.gpu.device).catch(error => options.onError?.(error));
      });
      return;
    }
    const device = runtime?.gpu?.device;
    if (!device?.lost?.then) return;
    const current = ++generation;
    device.lost.then(async info => {
      if (stopped || current !== generation) return;
      lost = true;
      runtime.exports.nanoui_web_device_lost();
      if (frame !== null) { caf(frame); frame = null; }
      if (timer !== null) { clearTimeout(timer); timer = null; }
      const recover = info.reason !== "destroyed" || forceRecovery;
      forceRecovery = false;
      options.onDeviceLost?.(info);
      if (options.ownsDevice && recover) {
        try { await setDevice(await options.acquireDevice()); }
        catch (error) { options.onError?.(error); }
      }
    });
  }
  async function setDevice(device) {
    if (stopped) return;
    paused = true;
    if (frame !== null) { caf(frame); frame = null; }
    if (timer !== null) { clearTimeout(timer); timer = null; }
    runtime.gpu.setDevice(device);
    configure();
    if (runtime.exports.nanoui_web_device()) throw new Error("Could not recreate GPU renderer");
    await runtime.gpu.ready();
    lost = false; paused = false;
    watchDevice();
    request();
  }
  function clipboardWrite(ptr, len) {
    const mem = getMemory();
    lastClipboardText = mem && len > 0 ? clipboardDecoder.decode(new Uint8Array(mem.buffer, ptr, len)) : "";
    inputController?.onClipboardWrite(lastClipboardText);
  }
  return {
    stats, unwind, requestFrame: request, frame: runFrame, flushFrame, resize, pointer, wheel, pinch, key, setDevice,
    get clipboardText() { return lastClipboardText; },
    get input() { return inputController; },
    imports: {
      request_frame: request,
      request_after: after,
      now_ms: () => performance.now(),
      clipboard_write: clipboardWrite,
      run_forever() { throw unwind; },
    },
    attach(value) {
      runtime = value?.exports ? value : { exports: value, gpu: null };
      if (runtime.gpu) {
        if (!isWebGL2()) {
          context = canvas.getContext("webgpu");
          if (!context) throw new Error("Canvas WebGPU context is unavailable");
        }
        configure();
        runtime.gpu.onTiming?.(sample => {
          if (sample.log_index !== undefined && sample.log_index !== 0xffffffff) {
            runtime.exports.nanoui_web_gpu_time(sample.log_index, sample.gpu_ms);
          }
        });
        watchDevice();
      }
      inputController?.destroy();
      inputController = null;
      if (typeof document !== "undefined" && canvas?.addEventListener) {
        inputController = createInput({
          canvas,
          exports: runtime.exports,
          memory: getMemory,
          ime: options.ime ?? "auto",
          requestFrame: request,
          flushFrame,
        });
      }
    },
    listen() {
      paused = false;
      resize(options.width, options.height, options.scale);
      if (canvas.getBoundingClientRect) {
        const coords = e => { const r = canvas.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
        const touches = touchInput(pointer, pinch);
        let pressed, lastClick;
        const near = (point, x, y) => Math.hypot(x - point.x, y - point.y) <= 5;
        const touchAction = canvas.style.touchAction;
        canvas.style.touchAction = "none";
        listeners.push(() => { canvas.style.touchAction = touchAction; });
        for (const [event, kind] of [["pointermove", 0], ["pointerdown", 1], ["pointerup", 2], ["pointercancel", 3]]) {
          on(canvas, event, e => {
            const mods = Number(e.shiftKey) | (Number(e.ctrlKey) << 1) | (Number(e.altKey) << 2) | (Number(e.metaKey) << 3);
            if (kind === 1) canvas.setPointerCapture(e.pointerId);
            const [x, y] = coords(e);
            if (e.pointerType === "touch") touches.event(kind, e.pointerId, x, y);
            else {
              if (kind === 1) {
                const repeated = e.button === 0 && lastClick && e.timeStamp - lastClick.time <= 500 && near(lastClick, x, y);
                pressed = e.button === 0 ? { x, y, clicks: repeated ? Math.min(lastClick.clicks + 1, 3) : 1 } : null;
                lastClick = null;
              } else if (kind === 2 || kind === 3) {
                if (kind === 2 && pressed && near(pressed, x, y)) lastClick = { ...pressed, time: e.timeStamp };
                pressed = null;
              }
              pointer(kind, x, y, e.button, mods, pressed?.clicks ?? 1);
            }
            if (kind === 2 || kind === 3) { if (canvas.hasPointerCapture(e.pointerId)) canvas.releasePointerCapture(e.pointerId); }
            e.preventDefault();
          });
        }
        // Off the canvas with no button held: move the UI pointer outside,
        // as the native mouse-exit paths do, so nothing stays hovered. A
        // held button keeps the capture, and its release reports the exit.
        on(canvas, "pointerleave", e => {
          if (e.pointerType !== "touch" && e.buttons === 0) pointer(0, -1e6, -1e6, 0, 0, 1);
        });
        on(canvas, "lostpointercapture", e => {
          if (e.pointerType === "touch") touches.event(3, e.pointerId, ...coords(e));
        });
        // Safari reports a cumulative scale; Chromium and Firefox use
        // ctrl-modified wheel deltas for trackpad pinch gestures.
        let gestureScale = null;
        on(canvas, "gesturestart", e => {
          gestureScale = touches.active() ? null : 1;
          e.preventDefault();
        }, { passive: false });
        on(canvas, "gesturechange", e => {
          if (gestureScale !== null && !touches.active() && e.scale > 0) {
            pinch(...coords(e), e.scale / gestureScale);
            gestureScale = e.scale;
          }
          e.preventDefault();
        }, { passive: false });
        on(canvas, "gestureend", e => {
          gestureScale = null;
          e.preventDefault();
        }, { passive: false });
        on(canvas, "wheel", e => {
          const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? canvas.clientHeight : 1;
          if (e.ctrlKey && e.deltaY !== 0) {
            if (gestureScale === null && !touches.active())
              pinch(...coords(e), Math.exp(Math.max(-1, Math.min(1, -e.deltaY * unit * 0.01))));
          } else wheel(...coords(e), -e.deltaX * unit, -e.deltaY * unit);
          e.preventDefault();
        }, { passive: false });
        on(canvas, "contextmenu", e => e.preventDefault());
        observer = new ResizeObserver(entries => {
          const box = entries[0].devicePixelContentBoxSize?.[0];
          const dpr = options.scale ?? globalThis.devicePixelRatio ?? 1;
          const expected = Math.round(entries[0].contentRect.width * dpr);
          if (box && Math.abs(box.inlineSize - expected) <= 1) resize(box.inlineSize, box.blockSize); else resize();
        });
        try { observer.observe(canvas, { box: "device-pixel-content-box" }); }
        catch { observer.observe(canvas); }
        const dprChanged = () => {
          media?.removeEventListener("change", dprChanged);
          media = matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
          media.addEventListener("change", dprChanged, { once: true });
          resize();
        };
        dprChanged();
        listeners.push(() => media?.removeEventListener("change", dprChanged));
      }
    },
    debugLoseDevice() {
      if (runtime?.gpu?.device?.destroy) {
        forceRecovery = true;
        runtime.gpu.device.destroy();
      } else {
        const ext = runtime?.gpu?.device?.getExtension?.("WEBGL_lose_context");
        if (ext) {
          ext.loseContext();
          setTimeout(() => { if (!stopped) ext.restoreContext(); }, 30);
        }
      }
    },
    destroy() {
      if (stopped) return;
      stopped = true; generation++;
      inputEvents.length = 0;
      if (frame !== null) caf(frame);
      if (timer !== null) clearTimeout(timer);
      observer?.disconnect();
      inputController?.destroy();
      inputController = null;
      if (canvas?.style) canvas.style.cursor = "";
      for (const off of listeners) off();
      runtime?.exports?.nanoui_web_destroy?.();
      context?.unconfigure?.();
      runtime?.gpu?.dispose?.();
      if (options.ownsDevice) runtime?.device?.destroy?.();
    },
  };
}


// A finger becomes an editor pointer on a drag or a tap. A second finger
// takes over as a pinch, canceling any speculative edit from the first.
function touchInput(pointer, pinch) {
  const contacts = new Map();
  let dragging = false;
  let multi = false;
  let baseline;
  const dragThreshold = 5;

  function measure() {
    const [a, b] = contacts.values();
    if (!b) return undefined;
    return {
      x: (a.x + b.x) / 2,
      y: (a.y + b.y) / 2,
      distance: Math.hypot(a.x - b.x, a.y - b.y),
    };
  }

  function event(kind, id, x, y) {
    if (kind === 1) {
      contacts.set(id, { x, y, startX: x, startY: y });
      if (contacts.size >= 2) {
        if (dragging) pointer(3, x, y);
        multi = true;
        dragging = false;
        baseline = measure();
      }
      return;
    }
    const contact = contacts.get(id);
    if (!contact) return;
    if (kind === 0) {
      contact.x = x;
      contact.y = y;
      if (multi) {
        const next = measure();
        if (next && baseline && next.distance >= 1 && baseline.distance >= 1)
          pinch(next.x, next.y, next.distance / baseline.distance, next.x - baseline.x, next.y - baseline.y);
        baseline = next;
      } else {
        if (!dragging && Math.hypot(x - contact.startX, y - contact.startY) >= dragThreshold) {
          pointer(1, contact.startX, contact.startY);
          dragging = true;
        }
        if (dragging) pointer(0, x, y);
      }
      return;
    }
    if (!multi) {
      if (kind === 2 && !dragging) pointer(1, contact.startX, contact.startY);
      if (dragging || kind === 2) pointer(kind, x, y);
    }
    contacts.delete(id);
    baseline = measure();
    if (contacts.size === 0) {
      dragging = false;
      multi = false;
    }
  }

  return { active: () => contacts.size > 0, event };
}
