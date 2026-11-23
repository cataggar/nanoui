// Off-render-path async image fetch, decode, resize, coalescing, and GPU upload.

const decoder = new TextDecoder();
const STATUS_OK = 1;
const STATUS_FAILED = 2;
const STATUS_STALE = 3;

export function createImageLoader({
  gpu,
  memory,
  getExports,
  baseUrl,
  maxConcurrent = 6,
} = {}) {
  let resolvedBase = baseUrl ? String(baseUrl) : undefined;
  let concurrency = Math.max(1, Math.min(64, (maxConcurrent >>> 0) || 6));
  let disposed = false;
  let activeCount = 0;
  let completedCount = 0;
  let failedCount = 0;
  let coalescedCount = 0;
  let blobSeq = 0;

  const blobs = new Map();
  const ownedHandles = new Map();
  const queue = [];
  const inFlight = new Map();
  const waiterByReqId = new Map();

  function safeReleaseGpu(handle) {
    if (!handle) return;
    try { gpu?.imports?.release?.(handle); } catch {}
  }

  function releaseOwned(handle, serial) {
    handle >>>= 0;
    serial >>>= 0;
    if (!handle || !serial) return;
    if (ownedHandles.get(handle) !== serial) return;
    ownedHandles.delete(handle);
    if ((gpu?.imports?.resource_serial?.(handle) >>> 0) === serial) {
      safeReleaseGpu(handle);
    }
  }

  function deliver(cacheId, reqId, handle, serial, width, height, byteLen, status) {
    handle >>>= 0;
    serial >>>= 0;
    const exports = getExports?.();
    if (disposed || typeof exports?.nanoui_web_image_complete !== "function") {
      if (handle !== 0) {
        ownedHandles.delete(handle);
        safeReleaseGpu(handle);
      }
      return;
    }
    if (handle !== 0) {
      ownedHandles.set(handle, serial);
    }
    exports.nanoui_web_image_complete(
      cacheId >>> 0,
      reqId >>> 0,
      handle,
      serial,
      width >>> 0,
      height >>> 0,
      byteLen >>> 0,
      status >>> 0,
    );
  }

  function deferFailure(cacheId, reqId, status) {
    const waiter = { cacheId, reqId, gen: 0, cancelled: false };
    const stubJob = { key: "", started: true, waiters: [waiter], controller: null };
    waiterByReqId.set(reqId, { job: stubJob, waiter });
    queueMicrotask(() => {
      if (waiterByReqId.get(reqId)?.waiter === waiter) waiterByReqId.delete(reqId);
      if (disposed || waiter.cancelled) return;
      if (status === STATUS_FAILED) failedCount++;
      deliver(cacheId, reqId, 0, 0, 0, 0, 0, status);
    });
  }

  async function decodeBlobToBitmap(blob, signal) {
    try {
      return await createImageBitmap(blob, {
        premultiplyAlpha: "premultiply",
        colorSpaceConversion: "default",
        imageOrientation: "from-image",
      });
    } catch (err) {
      if (disposed || signal.aborted) throw err;
      if (
        typeof HTMLImageElement !== "undefined" &&
        typeof Image === "function" &&
        typeof URL?.createObjectURL === "function"
      ) {
        const objUrl = URL.createObjectURL(blob);
        try {
          const img = new Image();
          img.decoding = "async";
          img.src = objUrl;
          await img.decode();
          if (disposed || signal.aborted) return null;
          return await createImageBitmap(img, {
            premultiplyAlpha: "premultiply",
            colorSpaceConversion: "default",
          });
        } finally {
          URL.revokeObjectURL(objUrl);
        }
      }
      throw err;
    }
  }

  async function runJob(job) {
    const { signal } = job.controller;
    let bitmap = null;
    let errorStatus = 0;
    try {
      let blob = job.blob;
      job.blob = null;
      if (!blob) {
        const res = await fetch(job.resolvedUrl, { signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        blob = await res.blob();
      }
      if (disposed || signal.aborted) {
        errorStatus = STATUS_STALE;
      } else {
        bitmap = await decodeBlobToBitmap(blob, signal);
        if (disposed || signal.aborted) {
          errorStatus = STATUS_STALE;
        } else if (!bitmap || !(bitmap.width > 0) || !(bitmap.height > 0)) {
          errorStatus = STATUS_FAILED;
        } else {
          const hwMax = gpu?.maxTextureSize?.() || 8192;
          const limW = job.maxW > 0 ? Math.min(job.maxW, hwMax) : hwMax;
          const limH = job.maxH > 0 ? Math.min(job.maxH, hwMax) : hwMax;
          if (bitmap.width > limW || bitmap.height > limH) {
            const scale = Math.min(limW / bitmap.width, limH / bitmap.height);
            const dstW = Math.max(1, Math.round(bitmap.width * scale));
            const dstH = Math.max(1, Math.round(bitmap.height * scale));
            const scaled = await createImageBitmap(bitmap, {
              resizeWidth: dstW,
              resizeHeight: dstH,
              resizeQuality: "high",
              premultiplyAlpha: "premultiply",
              colorSpaceConversion: "default",
            });
            bitmap.close?.();
            bitmap = scaled;
            if (!bitmap || !(bitmap.width > 0) || !(bitmap.height > 0)) {
              errorStatus = STATUS_FAILED;
            }
          }
        }
      }
    } catch {
      errorStatus = signal.aborted ? STATUS_STALE : STATUS_FAILED;
    }

    try {
      const waiters = job.waiters.slice();
      if (inFlight.get(job.key) === job) inFlight.delete(job.key);
      if (disposed) return;

      if (errorStatus !== 0 || signal.aborted) {
        const st = signal.aborted ? STATUS_STALE : errorStatus;
        for (const w of waiters) {
          if (waiterByReqId.get(w.reqId)?.waiter === w) waiterByReqId.delete(w.reqId);
          if (disposed || w.cancelled) continue;
          if (st === STATUS_FAILED) failedCount++;
          deliver(w.cacheId, w.reqId, 0, 0, 0, 0, 0, st);
        }
        return;
      }

      for (const w of waiters) {
        if (disposed) break;
        if (w.cancelled) {
          if (waiterByReqId.get(w.reqId)?.waiter === w) waiterByReqId.delete(w.reqId);
          continue;
        }
        if (
          signal.aborted ||
          !gpu?.device ||
          gpu.isLost?.() ||
          gpu.device.isContextLost?.() ||
          (gpu.imports?.device_generation?.() >>> 0) !== w.gen
        ) {
          if (waiterByReqId.get(w.reqId)?.waiter === w) waiterByReqId.delete(w.reqId);
          deliver(w.cacheId, w.reqId, 0, 0, 0, 0, 0, STATUS_STALE);
          continue;
        }

        let uploaded;
        try {
          uploaded = await gpu.uploadBitmap(bitmap);
        } catch {
          uploaded = {
            handle: 0,
            serial: 0,
            width: 0,
            height: 0,
            stale: Boolean(gpu?.isLost?.() || gpu?.device?.isContextLost?.()),
          };
        }
        if (waiterByReqId.get(w.reqId)?.waiter === w) waiterByReqId.delete(w.reqId);

        if (disposed || w.cancelled) {
          if (uploaded?.handle) safeReleaseGpu(uploaded.handle);
          continue;
        }
        if ((gpu?.imports?.device_generation?.() >>> 0) !== w.gen) {
          if (uploaded?.handle) safeReleaseGpu(uploaded.handle);
          deliver(w.cacheId, w.reqId, 0, 0, 0, 0, 0, STATUS_STALE);
          continue;
        }
        if (!uploaded || !uploaded.handle) {
          const st = uploaded?.stale ? STATUS_STALE : STATUS_FAILED;
          if (st === STATUS_FAILED) failedCount++;
          deliver(w.cacheId, w.reqId, 0, 0, 0, 0, 0, st);
          continue;
        }

        completedCount++;
        const wPx = uploaded.width >>> 0;
        const hPx = uploaded.height >>> 0;
        const byteLen = Math.min(0xffffffff, wPx * hPx * 4) >>> 0;
        deliver(
          w.cacheId,
          w.reqId,
          uploaded.handle >>> 0,
          uploaded.serial >>> 0,
          wPx,
          hPx,
          byteLen,
          STATUS_OK,
        );
      }
    } finally {
      bitmap?.close?.();
      for (const w of job.waiters) {
        if (waiterByReqId.get(w.reqId)?.waiter === w) waiterByReqId.delete(w.reqId);
      }
      if (inFlight.get(job.key) === job) inFlight.delete(job.key);
      activeCount--;
      pump();
    }
  }

  function pump() {
    while (!disposed && activeCount < concurrency && queue.length > 0) {
      const job = queue.pop();
      if (!job || job.waiters.every(w => w.cancelled)) {
        if (job && inFlight.get(job.key) === job) inFlight.delete(job.key);
        continue;
      }
      job.started = true;
      activeCount++;
      runJob(job);
    }
  }

  const imports = {
    request(cacheId, reqId, urlPtr, urlLen, maxW, maxH, gen) {
      cacheId >>>= 0;
      reqId >>>= 0;
      urlPtr >>>= 0;
      urlLen >>>= 0;
      maxW >>>= 0;
      maxH >>>= 0;
      gen >>>= 0;
      if (disposed) return;

      let rawUrl = "";
      try {
        const mem = memory?.();
        if (!mem || urlLen === 0) {
          deferFailure(cacheId, reqId, STATUS_FAILED);
          return;
        }
        rawUrl = decoder.decode(new Uint8Array(mem.buffer, urlPtr, urlLen).slice());
      } catch {
        deferFailure(cacheId, reqId, STATUS_FAILED);
        return;
      }
      if (!rawUrl) {
        deferFailure(cacheId, reqId, STATUS_FAILED);
        return;
      }

      let resolvedUrl;
      let blob = null;
      if (rawUrl.startsWith("nanoui-blob:")) {
        blob = blobs.get(rawUrl) ?? null;
        if (!blob) {
          deferFailure(cacheId, reqId, STATUS_FAILED);
          return;
        }
        resolvedUrl = rawUrl;
      } else {
        try {
          if (resolvedBase) {
            resolvedUrl = new URL(rawUrl, resolvedBase).href;
          } else if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(rawUrl) || rawUrl.startsWith(":")) {
            resolvedUrl = new URL(rawUrl).href;
          } else {
            resolvedUrl = rawUrl;
          }
        } catch {
          deferFailure(cacheId, reqId, STATUS_FAILED);
          return;
        }
      }

      const key = `${resolvedUrl}\0${maxW}\0${maxH}`;
      const waiter = { cacheId, reqId, gen, cancelled: false };
      const existing = inFlight.get(key);
      if (existing) {
        existing.waiters.push(waiter);
        waiterByReqId.set(reqId, { job: existing, waiter });
        coalescedCount++;
        if (!existing.started) {
          const idx = queue.indexOf(existing);
          if (idx !== -1 && idx !== queue.length - 1) {
            queue.splice(idx, 1);
            queue.push(existing);
          }
        }
        return;
      }

      const job = {
        key,
        resolvedUrl,
        blob,
        maxW,
        maxH,
        waiters: [waiter],
        controller: new AbortController(),
        started: false,
      };
      inFlight.set(key, job);
      waiterByReqId.set(reqId, { job, waiter });
      queue.push(job);
      pump();
    },

    cancel(reqId) {
      reqId >>>= 0;
      const entry = waiterByReqId.get(reqId);
      if (!entry) return;
      waiterByReqId.delete(reqId);
      entry.waiter.cancelled = true;
      const { job } = entry;
      if (job.waiters.every(w => w.cancelled)) {
        if (inFlight.get(job.key) === job) inFlight.delete(job.key);
        if (!job.started) {
          const idx = queue.indexOf(job);
          if (idx !== -1) queue.splice(idx, 1);
        }
        job.blob = null;
        try { job.controller?.abort(); } catch {}
      }
    },

    release(handle, serial) {
      releaseOwned(handle, serial);
    },

    set_concurrency(limit) {
      concurrency = Math.max(1, Math.min(64, limit >>> 0));
      pump();
    },
  };

  return {
    imports,
    get stats() {
      return {
        active: activeCount,
        queued: queue.length,
        completed: completedCount,
        failed: failedCount,
        owned: ownedHandles.size,
        coalesced: coalescedCount,
      };
    },
    putBlob(blob) {
      if (disposed) throw new Error("Image loader is disposed");
      if (!blob || typeof blob !== "object") throw new TypeError("Expected a Blob");
      const uri = `nanoui-blob:${++blobSeq}`;
      blobs.set(uri, blob);
      return uri;
    },
    deleteBlob(uri) {
      return blobs.delete(String(uri));
    },
    setBaseUrl(url) {
      resolvedBase = url ? String(url) : undefined;
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const job of queue) {
        job.blob = null;
        for (const w of job.waiters) w.cancelled = true;
        try { job.controller?.abort(); } catch {}
      }
      queue.length = 0;
      for (const job of inFlight.values()) {
        job.blob = null;
        for (const w of job.waiters) w.cancelled = true;
        try { job.controller?.abort(); } catch {}
      }
      inFlight.clear();
      waiterByReqId.clear();
      blobs.clear();
      for (const [handle, serial] of ownedHandles) {
        if ((gpu?.imports?.resource_serial?.(handle) >>> 0) === serial) {
          safeReleaseGpu(handle);
        }
      }
      ownedHandles.clear();
    },
  };
}
