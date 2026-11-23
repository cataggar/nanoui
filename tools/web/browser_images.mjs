import assert from "node:assert/strict";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

function encodeSolidRgbaPng(width, height, [r, g, b, a]) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const stride = 1 + width * 4;
  const raw = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const row = y * stride;
    raw[row] = 0;
    for (let x = 0; x < width; x++) {
      const off = row + 1 + x * 4;
      raw[off] = r;
      raw[off + 1] = g;
      raw[off + 2] = b;
      raw[off + 3] = a;
    }
  }
  const idat = deflateSync(raw);
  return Buffer.concat([sig, pngChunk("IHDR", ihdr), pngChunk("IDAT", idat), pngChunk("IEND", Buffer.alloc(0))]);
}

async function generateFixtures(dir) {
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });
  await Promise.all([
    writeFile(join(dir, "solid-red.png"), encodeSolidRgbaPng(32, 32, [220, 40, 60, 255])),
    writeFile(join(dir, "translucent-teal.png"), encodeSolidRgbaPng(32, 32, [0, 180, 160, 128])),
    writeFile(join(dir, "oversized-blue.png"), encodeSolidRgbaPng(256, 128, [30, 90, 230, 255])),
  ]);
  const batch = [];
  for (let i = 0; i < 120; i++) {
    const rgb = [(37 + i * 53) & 255, (91 + i * 97) & 255, (151 + i * 149) & 255, 255];
    batch.push(writeFile(join(dir, `item-${i}.png`), encodeSolidRgbaPng(16, 16, rgb)));
  }
  await Promise.all(batch);
}

async function sampleShot(page, points) {
  const png = await page.screenshot({ scale: "device" });
  return page.evaluate(async ({ b64, pts }) => {
    const bytes = Uint8Array.from(atob(b64), ch => ch.charCodeAt(0));
    const bmp = await createImageBitmap(new Blob([bytes], { type: "image/png" }));
    const scratch = document.createElement("canvas");
    scratch.width = bmp.width;
    scratch.height = bmp.height;
    const ctx = scratch.getContext("2d");
    ctx.drawImage(bmp, 0, 0);
    bmp.close();
    const img = ctx.getImageData(0, 0, scratch.width, scratch.height).data;
    return pts.map(([x, y]) => {
      const idx = (y * scratch.width + x) * 4;
      return [img[idx], img[idx + 1], img[idx + 2], img[idx + 3]];
    });
  }, { b64: png.toString("base64"), pts: points });
}

function assertRgbNear(actual, expected, tol, label) {
  for (let c = 0; c < 3; c++) {
    const diff = Math.abs(actual[c] - expected[c]);
    assert.ok(
      diff <= tol,
      `${label} channel ${c}: got [${actual.slice(0, 3)}], expected [${expected}] (±${tol})`,
    );
  }
}

export async function runImageCacheSuite(browser, baseUrl) {
  const fixturesDir = fileURLToPath(new URL("../../zig-out/web/test-images", import.meta.url));
  await generateFixtures(fixturesDir);
  const tealSamples = {};

  try {
    for (const backend of ["webgpu", "webgl2"]) {
      const ctx = await browser.newContext({ viewport: { width: 420, height: 300 }, deviceScaleFactor: 1 });
      const page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", e => errors.push(e.message));
      await page.goto(`${baseUrl}/`);
      await page.evaluate(async gpu => {
        document.documentElement.style.margin = "0";
        document.body.style.margin = "0";
        document.body.replaceChildren();
        const canvas = document.createElement("canvas");
        canvas.style.display = "block";
        canvas.style.width = "420px";
        canvas.style.height = "300px";
        document.body.append(canvas);
        const { start } = await import("./nanoui.js");
        window.nanoui = await start({
          canvas,
          url: "./images_test.wasm",
          gpu,
          width: 420,
          height: 300,
          scale: 1,
        });
      }, backend);

      assert.equal(await page.evaluate(() => window.nanoui.backend), backend);

      // Mode 0: wait for 3 ready slots + 1 failed (404) slot, then let 0.08s fade settle.
      await page.waitForFunction(() => {
        const e = window.nanoui?.exports;
        return e && e.img_test_visible_ready() >= 3 && e.img_test_visible_failed() >= 1 && e.img_test_animating() === 0;
      });
      await page.waitForTimeout(250);
      await page.evaluate(() => window.nanoui.gpu.check());

      const mode0Meta = await page.evaluate(() => ({
        ready: window.nanoui.exports.img_test_ready_count(),
        bytes: window.nanoui.exports.img_test_total_bytes(),
      }));
      assert.equal(mode0Meta.ready, 3, `${backend}: duplicate Slot 0 must share one cache entry`);
      assert.ok(mode0Meta.bytes <= 32768, `${backend}: 256x128 oversized-blue must downscale before upload (${mode0Meta.bytes} bytes)`);

      const [slot0, slot1, slot2, slot3Failed, dupSlot0] = await sampleShot(page, [
        [48, 48],
        [128, 48],
        [208, 48],
        [288, 48],
        [48, 128],
      ]);
      assertRgbNear(slot0, [220, 40, 60], 5, `${backend} slot0 solid-red`);
      assertRgbNear(dupSlot0, [220, 40, 60], 5, `${backend} dup-slot0 solid-red`);
      assertRgbNear(slot1, [127, 217, 207], 6, `${backend} slot1 premultiplied translucent-teal`);
      assertRgbNear(slot2, [30, 90, 230], 5, `${backend} slot2 downscaled oversized-blue`);
      assert.ok(
        slot3Failed[0] < 252 || slot3Failed[1] < 252 || slot3Failed[2] < 252,
        `${backend} slot3 404 must render placeholder fallback over white`,
      );
      tealSamples[backend] = slot1;

      // Test runtime.images.putBlob(svgBlob) -> "nanoui-blob:1" on Slot 3.
      const blobUri = await page.evaluate(() => {
        const r = window.nanoui;
        const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="rgb(150,50,200)"/></svg>';
        const uri = r.images.putBlob(new Blob([svg], { type: "image/svg+xml" }));
        const bytes = new TextEncoder().encode(uri);
        const ptr = r.exports.nanoui_web_input_ptr(bytes.length);
        new Uint8Array(r.exports.memory.buffer, ptr, bytes.length).set(bytes);
        r.exports.img_test_set_custom_url(ptr, bytes.length);
        r.requestFrame();
        return uri;
      });
      assert.equal(blobUri, "nanoui-blob:1");
      await page.waitForFunction(() => {
        const e = window.nanoui.exports;
        return e.img_test_visible_ready() >= 4 && e.img_test_visible_failed() === 0 && e.img_test_animating() === 0;
      });
      await page.waitForTimeout(250);
      await page.evaluate(() => window.nanoui.gpu.check());
      const [slot3Blob] = await sampleShot(page, [[288, 48]]);
      assertRgbNear(slot3Blob, [150, 50, 200], 5, `${backend} slot3 SVG blob`);

      // Zero idle frames check once fade-in settles.
      const callbacksBeforeIdle = await page.evaluate(() => window.nanoui.host.stats.callbacks);
      await page.waitForTimeout(600);
      assert.equal(
        await page.evaluate(() => window.nanoui.host.stats.callbacks),
        callbacksBeforeIdle,
        `${backend}: zero idle animation callbacks after image settle`,
      );

      // Device / context-loss recovery check.
      const genBeforeLoss = await page.evaluate(() => window.nanoui.gpu.generation);
      if (backend === "webgpu") {
        await page.evaluate(() => window.nanoui.host.debugLoseDevice());
      } else {
        await page.evaluate(async () => {
          const ext = document.querySelector("canvas").getContext("webgl2").getExtension("WEBGL_lose_context");
          if (!ext) throw new Error("WEBGL_lose_context unavailable");
          ext.loseContext();
          await new Promise(resolve => setTimeout(resolve, 100));
          ext.restoreContext();
        });
      }
      await page.waitForFunction(
        prevGen =>
          window.nanoui.gpu.generation > prevGen &&
          window.nanoui.exports.img_test_cache_generation() > prevGen &&
          window.nanoui.exports.img_test_visible_ready() >= 4 &&
          window.nanoui.exports.img_test_animating() === 0,
        genBeforeLoss,
      );
      await page.waitForTimeout(250);
      await page.evaluate(() => window.nanoui.gpu.check());
      const [rec0, rec1, rec2, rec3] = await sampleShot(page, [
        [48, 48],
        [128, 48],
        [208, 48],
        [288, 48],
      ]);
      assertRgbNear(rec0, [220, 40, 60], 5, `${backend} recovered slot0`);
      assertRgbNear(rec1, [127, 217, 207], 6, `${backend} recovered slot1`);
      assertRgbNear(rec2, [30, 90, 230], 5, `${backend} recovered slot2`);
      assertRgbNear(rec3, [150, 50, 200], 5, `${backend} recovered slot3`);

      // Mode 1: virtualized ui.list scroll & bounded LRU VRAM check.
      const baseGpuObjects = await page.evaluate(() => {
        const r = window.nanoui;
        // Drop renderer's Mode 0 sample cache baseline reading right before Mode 1.
        const base = r.gpu.objects.size - r.images.stats.owned;
        r.exports.img_test_set_mode(1);
        r.requestFrame();
        return base;
      });
      const scrollSteps = [];
      for (let y = 0; y < 3600; y += 220) scrollSteps.push(y);
      scrollSteps.push(3600);
      for (const y of scrollSteps) {
        await page.evaluate(scrollY => {
          window.nanoui.exports.img_test_scroll_to(scrollY);
          window.nanoui.requestFrame();
        }, y);
        await page.waitForTimeout(80);
      }
      await page.waitForTimeout(150);
      await page.evaluate(() => window.nanoui.gpu.check());

      const lruStats = await page.evaluate(() => ({
        readyCount: window.nanoui.exports.img_test_ready_count(),
        gpuObjects: window.nanoui.gpu.objects.size,
        imageStats: window.nanoui.images.stats,
      }));
      assert.ok(lruStats.readyCount <= 16, `${backend}: LRU ready_count bounded (${lruStats.readyCount})`);
      assert.ok(lruStats.imageStats.owned <= 16, `${backend}: owned GPU textures bounded (${lruStats.imageStats.owned})`);
      assert.ok(
        lruStats.gpuObjects - baseGpuObjects <= 32,
        `${backend}: gpu.objects slots freed on eviction (${lruStats.gpuObjects} vs base ${baseGpuObjects})`,
      );
      assert.ok(
        lruStats.imageStats.completed >= 25,
        `${backend}: scrolled through >= 25 thumbnails (got ${lruStats.imageStats.completed})`,
      );

      // Mid-flight teardown leak check: start new fetches at y=4200, then immediately check & destroy.
      const teardownStats = await page.evaluate(async () => {
        const r = window.nanoui;
        r.exports.img_test_scroll_to(4200);
        r.host.flushFrame();
        r.requestFrame();
        const inFlightBefore = r.images.stats.active + r.images.stats.queued;
        await r.gpu.check();
        r.destroy();
        const immediateObjects = r.gpu.objects.size;
        const immediateOwned = r.images.stats.owned;
        await new Promise(resolve => setTimeout(resolve, 100));
        return {
          inFlightBefore,
          immediateObjects,
          immediateOwned,
          settledObjects: r.gpu.objects.size,
          settledOwned: r.images.stats.owned,
        };
      });
      assert.ok(teardownStats.inFlightBefore > 0, `${backend}: jump scroll started mid-flight fetches`);
      assert.equal(teardownStats.immediateObjects, 1, `${backend}: immediate GPU handle leak after destroy`);
      assert.equal(teardownStats.immediateOwned, 0, `${backend}: immediate owned image handles after destroy`);
      assert.equal(teardownStats.settledObjects, 1, `${backend}: settled GPU handle leak after mid-flight abort`);
      assert.equal(teardownStats.settledOwned, 0, `${backend}: settled owned image handles after mid-flight abort`);

      assert.deepEqual(errors, []);
      await ctx.close();
    }

    // Cross-backend alpha blending parity (WebGPU vs WebGL2 <= 3 per channel).
    for (let c = 0; c < 3; c++) {
      const diff = Math.abs(tealSamples.webgpu[c] - tealSamples.webgl2[c]);
      assert.ok(
        diff <= 3,
        `WebGPU [${tealSamples.webgpu.slice(0, 3)}] vs WebGL2 [${tealSamples.webgl2.slice(0, 3)}] channel ${c} diff ${diff} > 3`,
      );
    }

    // Dedicated Worker (OffscreenCanvas via ./worker.js) test.
    {
      const ctx = await browser.newContext({ viewport: { width: 420, height: 300 }, deviceScaleFactor: 1 });
      const page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", e => errors.push(e.message));
      await page.goto(`${baseUrl}/`);
      await page.evaluate(async () => {
        document.documentElement.style.margin = "0";
        document.body.style.margin = "0";
        document.body.replaceChildren();
        const canvas = document.createElement("canvas");
        canvas.style.display = "block";
        canvas.style.width = "420px";
        canvas.style.height = "300px";
        document.body.append(canvas);
        const worker = new Worker("./worker.js", { type: "module" });
        let seq = 0;
        const pending = new Map();
        worker.onmessage = ({ data }) => {
          if (data.error) throw new Error(data.error);
          const fn = pending.get(data.id ?? "ready");
          if (fn) {
            pending.delete(data.id ?? "ready");
            fn(data);
          }
        };
        const ready = new Promise(resolve => pending.set("ready", resolve));
        const offscreen = canvas.transferControlToOffscreen();
        worker.postMessage(
          {
            canvas: offscreen,
            url: "./images_test.wasm",
            baseUrl: location.href,
            width: 420,
            height: 300,
            scale: 1,
          },
          [offscreen],
        );
        await ready;
        window.imgWorker = {
          worker,
          info: () =>
            new Promise(resolve => {
              const id = ++seq;
              pending.set(id, resolve);
              worker.postMessage({ info: id });
            }),
        };
      });

      const workerLoaded = await page.evaluate(async () => {
        const deadline = Date.now() + 8000;
        while (Date.now() < deadline) {
          const info = await window.imgWorker.info();
          if (info.images && info.images.completed >= 3 && info.images.failed >= 1) return info;
          await new Promise(resolve => setTimeout(resolve, 40));
        }
        return window.imgWorker.info();
      });
      assert.ok(workerLoaded.images.completed >= 3, `Worker completed >= 3 images (got ${workerLoaded.images?.completed})`);
      assert.ok(workerLoaded.images.failed >= 1, `Worker recorded >= 1 failed image (got ${workerLoaded.images?.failed})`);

      // Wait for Worker fade-in animation to settle, then verify zero idle frames over 500ms.
      await page.waitForTimeout(300);
      const workerSettled = await page.evaluate(() => window.imgWorker.info());
      await page.waitForTimeout(500);
      const workerIdle = await page.evaluate(() => window.imgWorker.info());
      assert.equal(workerIdle.callbacks, workerSettled.callbacks, "Worker zero idle callbacks after settle");

      await page.evaluate(() => window.imgWorker.worker.postMessage({ destroy: true }));
      assert.deepEqual(errors, []);
      await ctx.close();
    }
  } finally {
    await rm(fixturesDir, { recursive: true, force: true });
  }
}
