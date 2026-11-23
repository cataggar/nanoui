import assert from "node:assert/strict";

export async function runRpcSuite(browser, baseUrl, comparePage) {
  const errors = [];
  const ctx = await browser.newContext({
    viewport: { width: 420, height: 300 },
    deviceScaleFactor: 2,
  });

  try {
    // 1. Main-thread canvas + real browser APIs + synchronous DOM reentrancy + idle Promise wakeup.
    const page = await ctx.newPage();
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(baseUrl);

    await page.evaluate(async () => {
      const style = document.createElement("style");
      style.textContent =
        "html,body{margin:0;width:100%;height:100%;background:#fafafa}" +
        "canvas{display:block;width:100%;height:100%;touch-action:none}";
      document.head.append(style);
      const canvas = document.createElement("canvas");
      document.body.replaceChildren(canvas);

      const { start } = await import("./nanoui.js");
      window.demoEvents = [];
      window.nanoui = await start({
        canvas,
        url: "./rpc-demo.wasm",
        host: {
          DemoHost: {
            delayedColor: (ms, nextHex) =>
              new Promise((resolve) => setTimeout(() => resolve(nextHex), ms)),
            readBanner: (key) => (key === "greeting" ? "Hello Browser Host" : null),
          },
        },
        onError: (err) => {
          throw err;
        },
      });
      window.offDemo = window.nanoui.rpc.onDemoUpdated((ev) => window.demoEvents.push(ev));
    });

    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() >= 1);
    await page.waitForTimeout(100);
    const initialParity = await comparePage(page);
    assert.ok(initialParity.mean < 0.05, `initial rpc-demo parity failed: ${initialParity.mean}`);

    const baselineLive = await page.evaluate(() => window.nanoui.js.liveCount());
    assert.equal(baselineLive, 2, "expected emitter + host persistent handles");

    // HostClient sync call + real localStorage round-trip from Zig.
    const browserApiCheck = await page.evaluate(async () => {
      const rpc = window.nanoui.rpc;
      localStorage.removeItem("nanoui-e2e-key");
      const bannerHit = await rpc.DemoService.readHostBanner("greeting");
      const bannerMiss = await rpc.DemoService.readHostBanner("other");
      const stored = await rpc.DemoService.storageRoundTrip("nanoui-e2e-key", "stored-from-zig");
      const directJs = localStorage.getItem("nanoui-e2e-key");
      const missing = await rpc.DemoService.storageRoundTrip("nanoui-missing-key", null);
      return { bannerHit, bannerMiss, stored, directJs, missing };
    });
    assert.deepEqual(browserApiCheck, {
      bannerHit: "Hello Browser Host",
      bannerMiss: null,
      stored: "stored-from-zig",
      directJs: "stored-from-zig",
      missing: null,
    });

    // DOM element creation via js.Handle + synchronous DOM click callback reentrancy guard.
    const domReentrant = await page.evaluate(async () => {
      const { rpc, js } = window.nanoui;
      const btn = await rpc.DemoService.createDomButton("Launch", "primary");
      const isButton = btn instanceof HTMLButtonElement;
      const text = btn.textContent;
      const variant = btn.getAttribute("data-variant");
      btn.setAttribute("data-role", "probe-trigger");

      let listenerSawHostCall = false;
      let queuedClickPromise = null;
      btn.addEventListener("click", () => {
        listenerSawHostCall = js.isInHostCall();
        queuedClickPromise = rpc.DemoService.recordClick("dom-sync-listener", 7);
      });

      const role = await rpc.DemoService.inspectAndClickDom(btn);
      const clickTotal = await queuedClickPromise;
      const state = await rpc.DemoService.getClickState();
      return { isButton, text, variant, role, listenerSawHostCall, clickTotal, state };
    });
    assert.deepEqual(domReentrant, {
      isButton: true,
      text: "Launch",
      variant: "primary",
      role: "probe-trigger",
      listenerSawHostCall: true,
      clickTotal: 7,
      // clicks=7, reentrant_observed=0 (proving recordClick did NOT re-enter Wasm mid-call!)
      state: { count: 700, source: "dom-sync-listener" },
    });

    // Layer 1 real browser fetch(baseUrl + '/nanoui.d.ts') Promise chain (status + >256B text).
    await page.evaluate(async () => {
      await window.nanoui.rpc.DemoService.startFetchText(`${location.origin}/nanoui.d.ts`);
    });
    await page.waitForFunction(() => window.demoEvents.some((e) => e.source === "fetch"));
    const fetchState = await page.evaluate(() => window.nanoui.rpc.DemoService.pollFetch());
    assert.equal(fetchState.done, true);
    assert.equal(fetchState.status, 200);
    assert.ok(fetchState.byte_len > 500, `expected nanoui.d.ts > 500B, got ${fetchState.byte_len}`);
    assert.equal(fetchState.has_webruntime, true);
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    assert.ok((await comparePage(page)).mean < 0.05);

    // Idle-surface Promise wakeup ("Nothing polls" invariant).
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    const idleCallbacksBefore = await page.evaluate(() => window.nanoui.host.stats.callbacks);
    await page.waitForTimeout(300);
    const idleCallbacksAfter = await page.evaluate(() => window.nanoui.host.stats.callbacks);
    assert.equal(idleCallbacksAfter, idleCallbacksBefore, "idle surface must register 0 rAF callbacks");

    await page.evaluate(() => window.nanoui.rpc.DemoService.awaitDelayedColor(260, 0xe11d48));
    // Flush the immediate RPC call's frame while the 260ms timer Promise is still pending.
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    const preSettleFrames = await page.evaluate(() => window.nanoui.exports.nanoui_web_frames());
    const preSettleColor = await page.evaluate(() => window.nanoui.exports.demo_color() >>> 0);
    assert.notEqual(preSettleColor, 0xe11d48);
    const preSettleShot = await page.screenshot({ scale: "device" });

    // With zero mouse/keyboard input, promise settlement must wake the surface and repaint.
    await page.waitForFunction(
      (prev) => window.nanoui.exports.nanoui_web_frames() > prev && (window.nanoui.exports.demo_color() >>> 0) === 0xe11d48,
      preSettleFrames,
    );
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    const postSettleShot = await page.screenshot({ scale: "device" });
    assert.ok(!preSettleShot.equals(postSettleShot), "canvas pixels did not change after delayed Promise wakeup");
    const wokeParity = await comparePage(page);
    assert.ok(wokeParity.mean < 0.05, `post-wakeup parity failed: ${wokeParity.mean}`);

    // Verify surface goes right back to 0 idle callbacks after settling.
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    const settledCallbacks = await page.evaluate(() => window.nanoui.host.stats.callbacks);
    await page.waitForTimeout(300);
    assert.equal(
      await page.evaluate(() => window.nanoui.host.stats.callbacks),
      settledCallbacks,
      "surface continued polling after Promise wakeup settled",
    );

    // Verify zero handle leaks and clean teardown.
    const mainCleanup = await page.evaluate(async () => {
      const liveBeforeDestroy = window.nanoui.js.liveCount();
      const eventCount = window.demoEvents.length;
      window.offDemo();
      await window.nanoui.gpu.check();
      window.nanoui.rpc.destroy();
      const liveAfterRpcDestroy = window.nanoui.js.liveCount();
      window.nanoui.destroy();
      return {
        liveBeforeDestroy,
        liveAfterRpcDestroy,
        gpuObjects: window.nanoui.gpu.objects.size,
        eventCount,
      };
    });
    assert.equal(mainCleanup.liveBeforeDestroy, baselineLive, "main-thread browser RPC leaked JS handles");
    assert.equal(mainCleanup.liveAfterRpcDestroy, 0, "rpc.destroy did not release persistent handles");
    assert.equal(mainCleanup.gpuObjects, 1, "GPU object table leaked handles");
    assert.ok(mainCleanup.eventCount >= 2, "expected DemoUpdated events");

    // 2. Dedicated OffscreenCanvas Web Worker RPC (`worker.js` + `createWorkerRPC`).
    const workerResults = await page.evaluate(async () => {
      const { createWorkerRPC } = await import("./nanoui.js");
      const canvas = document.createElement("canvas");
      canvas.style.width = "420px";
      canvas.style.height = "300px";
      document.body.replaceChildren(canvas);

      const worker = new Worker("./worker.js", { type: "module" });
      let infoSeq = 9000;
      const infoPending = new Map();
      const ready = new Promise((resolve, reject) => {
        worker.addEventListener("message", ({ data }) => {
          if (data?.ready) resolve(data);
          else if (data?.error && !data?.rpcReply) reject(new Error(data.error));
          else if (data?.id && infoPending.has(data.id)) {
            const fn = infoPending.get(data.id);
            infoPending.delete(data.id);
            fn(data);
          }
        });
      });
      const queryInfo = () =>
        new Promise((resolve) => {
          const id = ++infoSeq;
          infoPending.set(id, resolve);
          worker.postMessage({ info: id });
        });

      const offscreen = canvas.transferControlToOffscreen();
      worker.postMessage(
        { canvas: offscreen, url: "./rpc-demo.wasm", width: 420, height: 300, scale: 1 },
        [offscreen],
      );
      await ready;

      const workerRpc = createWorkerRPC(worker);
      // Wait for initial Worker frame.
      const deadline0 = Date.now() + 3000;
      let before = await queryInfo();
      while (before.frames < 1 && Date.now() < deadline0) {
        await new Promise((r) => setTimeout(r, 20));
        before = await queryInfo();
      }

      // Structured RPC call -> resolves on main thread AND triggers Worker canvas redraw.
      const report = await workerRpc.DemoService.compute({
        op: "add",
        base: 5,
        entries: [
          { label: "w1", value: 10 },
          { label: "w2", value: 7.5 },
        ],
        state: { idle: {} },
        tag: "worker-run",
      });

      const deadline1 = Date.now() + 3000;
      let afterCompute = await queryInfo();
      while (afterCompute.frames <= before.frames && Date.now() < deadline1) {
        await new Promise((r) => setTimeout(r, 20));
        afterCompute = await queryInfo();
      }

      // Uint8Array round-trip without detaching caller's ArrayBuffer.
      const buf = new Uint8Array([1, 2, 3, 4]);
      const echoed = await workerRpc.DemoService.echoBytes(buf, 0x10);
      const callerBytesAfter = [...buf];
      const callerLenAfter = buf.byteLength;

      // Zig error propagation across Worker boundary.
      let zigErrMsg = "";
      try {
        await workerRpc.DemoService.failIfZero(0);
      } catch (err) {
        zigErrMsg = err.message;
      }

      // Non-cloneable argument (`() => {}`) rejects cleanly without crashing Worker.
      let cloneArgErr = "";
      try {
        await workerRpc.DemoService.inspectAndClickDom(() => {});
      } catch (err) {
        cloneArgErr = `${err.name}:${err.message}`;
      }

      // Non-cloneable Worker return (`js.Handle` to function) rejects cleanly without crashing Worker.
      let cloneRetErr = "";
      try {
        await workerRpc.DemoService.makeUncloneableHandle();
      } catch (err) {
        cloneRetErr = err.message;
      }

      // Subsequent Worker RPC call still succeeds!
      const recovery = await workerRpc.DemoService.compute({
        op: "mul",
        base: 2,
        entries: [{ label: "ok", value: 6 }],
        state: { running: 1 },
        tag: "recovered",
      });
      const afterRecovery = await queryInfo();

      workerRpc.destroy();
      let afterDestroyErr = "";
      try {
        await workerRpc.DemoService.failIfZero(2);
      } catch (err) {
        afterDestroyErr = err.message;
      }
      worker.postMessage({ destroy: true });

      return {
        beforeFrames: before.frames,
        afterFrames: afterCompute.frames,
        afterValue: afterCompute.value,
        report,
        echoedIsUint8: echoed instanceof Uint8Array,
        echoedBytes: [...echoed],
        callerLenAfter,
        callerBytesAfter,
        zigErrMsg,
        cloneArgErr,
        cloneRetErr,
        recovery,
        recoveryValue: afterRecovery.value,
        afterDestroyErr,
      };
    });

    assert.ok(workerResults.beforeFrames >= 1);
    assert.ok(workerResults.afterFrames > workerResults.beforeFrames, "Worker RPC did not redraw OffscreenCanvas");
    assert.equal(workerResults.afterValue, 1);
    assert.deepEqual(workerResults.report, {
      total: 22.5,
      count: 2,
      summary: "worker-run:2:22.5",
      next: { running: 2 },
    });
    assert.equal(workerResults.echoedIsUint8, true);
    assert.deepEqual(workerResults.echoedBytes, [17, 18, 19, 20]);
    assert.equal(workerResults.callerLenAfter, 4, "caller Uint8Array buffer was detached!");
    assert.deepEqual(workerResults.callerBytesAfter, [1, 2, 3, 4]);
    assert.match(workerResults.zigErrMsg, /DemoService\.failIfZero: DivisionByZero/);
    assert.match(workerResults.cloneArgErr, /DataCloneError|clone/i);
    assert.match(workerResults.cloneRetErr, /clone/i);
    assert.deepEqual(workerResults.recovery, {
      total: 12,
      count: 1,
      summary: "recovered:1:12.0",
      next: { completed: { label: "step-2", value: 12, note: "done" } },
    });
    assert.equal(workerResults.recoveryValue, 3);
    assert.match(workerResults.afterDestroyErr, /Worker RPC client is destroyed/);

    const missingErrors = await page.evaluate(async () => {
      const { load, start } = await import("./nanoui.js");
      const errs = [];
      for (const fn of [
        () => load({ url: "./missing-404.wasm" }),
        () => {
          const c = document.createElement("canvas");
          return start({ canvas: c, url: "./missing-404.wasm" });
        },
      ]) {
        try {
          await fn();
          errs.push("expected failure");
        } catch (err) {
          errs.push(`${err.name}: ${err.message}`);
        }
      }
      return errs;
    });
    for (const msg of missingErrors) {
      assert.match(msg, /^Error: Loading wasm: HTTP 404/);
    }
    assert.deepEqual(errors, []);

    console.log("browser rpc ok: main-thread Web APIs, reentrancy, idle Promise wakeup, OffscreenCanvas Worker RPC");
  } finally {
    await ctx.close();
  }
}
