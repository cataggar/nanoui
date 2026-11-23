// Optional execution of the compile-only probe, without a browser or preopens.
// Run `zig build web-check` first, then `node tools/web/check.mjs` (Node 20+).
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";
import { createJSBridge } from "../../zig-out/web/js.js";
import { createRPC } from "../../zig-out/web/rpc.js";

for (const mode of ["debug", "small"]) {
  const path = new URL(`../../zig-out/web/nanoui-web-check-${mode}.wasm`, import.meta.url);
  const bytes = await readFile(path);
  const mod = await WebAssembly.compile(bytes);
  const importModules = new Set(WebAssembly.Module.imports(mod).map((imp) => imp.module));
  assert.deepEqual([...importModules], ["wasi_snapshot_preview1"], `${mode}: unexpected non-WASI imports`);
  const wasi = new WASI({ version: "preview1", args: [], env: {}, preopens: {} });
  const { instance } = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  wasi.initialize(instance);
  const status = instance.exports.nanoui_web_check();
  if (status !== 0) throw new Error(`${mode}: UI probe failed (${status})`);
  console.log(`${mode}: UI probe passed (${bytes.length} bytes)`);
}

// Build-time TypeScript declaration checks + headless Node JS Bridge & RPC E2E suite.
const baseDts = await readFile(new URL("../../zig-out/web/nanoui.d.ts", import.meta.url), "utf8");
assert.match(baseDts, /export interface JSBridge\b/);
assert.match(baseDts, /export type RpcClient</);
assert.match(baseDts, /export type WorkerRpcClient</);
assert.match(baseDts, /export interface WebRuntime</);

const unhandledRejections = [];
const onUnhandled = (reason) => unhandledRejections.push(reason);
process.on("unhandledRejection", onUnhandled);

try {
  for (const mode of ["debug", "small"]) {
    const dts = await readFile(new URL(`../../zig-out/web/nanoui-rpc-check-${mode}.d.ts`, import.meta.url), "utf8");
    assert.match(dts, /export type MathOp = "add" \| "sub" \| "mul" \| "div";/);
    assert.match(dts, /export interface MetricEntry \{[\s\S]*?note\?: string \| null;/);
    assert.match(dts, /export type JobState = \{ idle: Record<string, never> \} \| \{ running: number \} \| \{ completed: MetricEntry \} \| \{ failed: string \};/);
    assert.match(dts, /echoBytes\(arg0: Uint8Array, arg1: number\): Promise<Uint8Array>;/);
    assert.match(dts, /passthroughHandle\(arg0: unknown, arg1: string\): Promise<unknown>;/);
    assert.match(dts, /divide\(arg0: number, arg1: number\): Promise<number>;/);
    assert.match(dts, /computeBatch\(arg0: BatchRequest\): Promise<BatchReport>;/);
    assert.match(dts, /syncFormat\(arg0: string, arg1: number\): string \| Promise<string>;/);
    assert.match(dts, /asyncCompute\(arg0: MetricEntry\): MetricEntry \| Promise<MetricEntry>;/);
    assert.match(dts, /transformBytes\(arg0: Uint8Array\): Uint8Array \| Promise<Uint8Array>;/);
    assert.match(dts, /inspectHandle\(arg0: unknown\): string \| Promise<string>;/);
    assert.match(dts, /readBanner\(arg0: string\): \(string \| null\) \| Promise<string \| null>;/);
    assert.match(dts, /onCounterChanged\(listener: \(payload: CounterEvent\) => void\): \(\) => void;/);
    assert.match(dts, /export type AppRuntime = WebRuntime<RpcServices, RpcHost, RpcEvents>;/);

    const wasmBytes = await readFile(new URL(`../../zig-out/web/nanoui-rpc-check-${mode}.wasm`, import.meta.url));
    const wasmMod = await WebAssembly.compile(wasmBytes);
    const rpcImports = new Set(WebAssembly.Module.imports(wasmMod).map((imp) => imp.module));
    assert.ok(!rpcImports.has("nanoui_web") && !rpcImports.has("nanoui_gpu"), `${mode}: unexpected surface/gpu imports`);

    let instance = null;
    let jsWakes = 0;
    const jsBridge = createJSBridge({
      memory: () => instance?.exports?.memory ?? null,
      exports: () => instance?.exports ?? null,
    });
    jsBridge.setWake(() => {
      jsWakes += 1;
    });

    const hostImpl = {
      CheckHost: {
        syncFormat(prefix, value) {
          return `${prefix}#${value}`;
        },
        async asyncCompute(entry) {
          await new Promise((r) => setTimeout(r, 5));
          return { label: entry.label.toUpperCase(), value: entry.value * 2.5, note: `ok:${entry.label}` };
        },
        async transformBytes(payload) {
          assert.ok(payload instanceof Uint8Array);
          await Promise.resolve();
          return Uint8Array.from(payload, (b) => (b + 1) & 0xff);
        },
        inspectHandle(handle) {
          return `${typeof handle.sym}:${handle.name}`;
        },
      },
    };

    const rpc = createRPC({
      js: jsBridge,
      memory: () => instance.exports.memory,
      exports: () => instance.exports,
      host: hostImpl,
    });

    const wasi = new WASI({ version: "preview1", args: [], env: {}, preopens: {} });
    instance = await WebAssembly.instantiate(wasmMod, {
      wasi_snapshot_preview1: wasi.wasiImport,
      nanoui_js: jsBridge.imports,
    });
    wasi.initialize(instance);
    const exp = instance.exports;

    // Layer 1: handles, free-list reuse, stale generation, BigInt > 2^53, >256B UTF-8 & bytes.
    const longUtf8 = "🚀漢字🙂Ω".repeat(90);
    const longBytes = new Uint8Array(2048);
    for (let i = 0; i < longBytes.length; i += 1) longBytes[i] = i === 0 ? 0xaa : i === 2047 ? 0x55 : i & 0xff;
    globalThis.__checkBigInt = 0xfedcba9876543210n;
    globalThis.__checkLongUtf8 = longUtf8;
    globalThis.__checkLongBytes = longBytes;
    assert.equal(exp.rpc_check_handles_and_types(), 0, `${mode}: Layer 1 handles/types check failed`);
    assert.equal(globalThis.__zigEchoUtf8, longUtf8);
    assert.ok(globalThis.__zigEchoBytes instanceof Uint8Array);
    assert.deepEqual(globalThis.__zigEchoBytes, longBytes);
    assert.equal(jsBridge.liveCount(), 0, `${mode}: Layer 1 leaked handles`);

    // Layer 1: structured JS exception formatting without unwinding Wasm.
    globalThis.__throwCase = (kind) => {
      if (kind === 0) throw new TypeError("bad arg");
      if (kind === 1) throw "plain string";
      if (kind === 2) throw { code: 42 };
      const circular = { tag: "loop" };
      circular.self = circular;
      throw circular;
    };
    globalThis.__ThrowingCtor = class {
      constructor() {
        throw new RangeError("bad ctor");
      }
    };
    assert.equal(exp.rpc_check_exceptions(), 0, `${mode}: Layer 1 exception formatting failed`);
    assert.equal(jsBridge.liveCount(), 0);

    // Layer 1: explicit memory.grow mid-flight (host read_pending + async Uint8Array slice safety).
    const beforeGrowBuffer = exp.memory.buffer;
    globalThis.__growDuringHostCall = () => {
      const pages = exp.rpc_check_force_grow(4);
      assert.ok(pages > 64, `${mode}: expected memory growth`);
      const bytes = new Uint8Array(4096);
      bytes.fill(0x77);
      bytes[0] = 0x11;
      bytes[4095] = 0xee;
      return { text: `G${"x".repeat(4094)}Z`, bytes };
    };
    globalThis.__asyncConsumeBytes = async (sliceFromZig) => {
      assert.ok(sliceFromZig instanceof Uint8Array);
      await new Promise((r) => setTimeout(r, 10));
      const dst = new Uint8Array(sliceFromZig.length);
      dst.set(sliceFromZig);
      let sum = 0;
      for (let i = 0; i < dst.length; i += 1) {
        assert.equal(dst[i], (i * 7 + 3) & 0xff);
        sum = (sum + dst[i]) >>> 0;
      }
      return sum;
    };
    assert.equal(exp.rpc_check_grow_midflight(), 0, `${mode}: mid-flight memory.grow failed`);
    assert.notEqual(exp.memory.buffer, beforeGrowBuffer, `${mode}: ArrayBuffer did not detach on grow`);
    await new Promise((r) => setTimeout(r, 30));
    let expectedSum = 0;
    for (let i = 0; i < 1024; i += 1) expectedSum = (expectedSum + ((i * 7 + 3) & 0xff)) >>> 0;
    assert.equal(exp.rpc_check_grow_result() >>> 0, expectedSum, `${mode}: async grown slice checksum mismatch`);
    assert.equal(exp.rpc_check_pending_callbacks(), 0);
    assert.equal(jsBridge.liveCount(), 0);

    // Layer 1: js.then + js.cancel on resolved and rejected Promises.
    let settleResolvers = null;
    globalThis.__makeTestPromises = () => {
      const ctl = {};
      const mk = (k) =>
        new Promise((res, rej) => {
          ctl[k] = { res, rej };
        });
      const out = {
        resolve: mk("resolve"),
        reject: mk("reject"),
        cancelResolve: mk("cancelResolve"),
        cancelReject: mk("cancelReject"),
      };
      settleResolvers = ctl;
      return out;
    };
    const wakesBeforePromises = jsWakes;
    const zigWakesBeforePromises = exp.rpc_check_zig_wakes();
    assert.equal(exp.rpc_check_promises(), 0, `${mode}: rpc_check_promises setup failed`);
    settleResolvers.cancelResolve.res("cancelled-value");
    settleResolvers.cancelReject.rej(new Error("cancelled-rejection"));
    settleResolvers.resolve.res(`resolved:${"R".repeat(300)}`);
    settleResolvers.reject.rej(new RangeError(`over-256:${"E".repeat(300)}`));
    await new Promise((r) => setTimeout(r, 15));
    assert.equal(exp.rpc_check_promise_state(), 0x0101, `${mode}: unexpected promise state`);
    assert.equal(exp.rpc_check_pending_callbacks(), 0);
    assert.equal(jsWakes - wakesBeforePromises, 4, `${mode}: expected 4 JS settle notifications`);
    assert.equal(
      exp.rpc_check_zig_wakes() - zigWakesBeforePromises,
      2,
      `${mode}: cancelled promises must not trigger Zig wake_hook`,
    );
    assert.equal(jsBridge.liveCount(), 0);

    // Layer 2: attach RPC + bind MathService.
    assert.equal(exp.rpc_check_init(), 0);
    rpc.attach();
    const baselineLive = jsBridge.liveCount();
    assert.equal(baselineLive, 2, `${mode}: expected emitter + host handles`);

    const seenEvents = [];
    const seenOnce = [];
    const offCounter = rpc.onCounterChanged((ev) => seenEvents.push(ev));
    rpc.once("counter-changed", (ev) => seenOnce.push(ev));

    // Nested structs, enums, optionals, tagged unions, and Call.arena allocations.
    const rep1 = await rpc.MathService.computeBatch({
      op: "add",
      base: 10,
      entries: [
        { label: "a", value: 2.5, note: "first" },
        { label: "b", value: 7.25 },
      ],
      state: { idle: {} },
      tag: "alpha",
    });
    assert.deepEqual(rep1, { total: 19.75, count: 2, summary: "alpha:2:19.75", next: { running: 2 } });

    const rep2 = await rpc.MathService.computeBatch({
      op: "mul",
      base: 3,
      entries: [{ label: "x", value: 4 }],
      state: { running: 4 },
      tag: null,
    });
    assert.deepEqual(rep2, {
      total: 12,
      count: 1,
      summary: "batch:1:12.00",
      next: { completed: { label: "step-5", value: 12, note: "done" } },
    });

    // Binary Uint8Array (`rpc.Bytes`) without base64 + mid-RPC 4 MiB memory.grow.
    const rawIn = new Uint8Array([0xde, 0xad, 0xbe, 0xef, 0x00, 0xff]);
    const xored = await rpc.MathService.echoBytes(rawIn, 0x5a);
    assert.ok(xored instanceof Uint8Array);
    assert.deepEqual([...xored], [...rawIn].map((b) => b ^ 0x5a));
    assert.equal(await rpc.MathService.fnv1a32(new Uint8Array([104, 105])), 0x683af69a);

    const grownOut = await rpc.MathService.growAndEcho(4, "grown", new Uint8Array([65, 66, 67]));
    assert.ok(grownOut instanceof Uint8Array);
    assert.equal(new TextDecoder().decode(grownOut), "grown:ABC");

    // Opaque JS object handle passthrough (`Object.is` identity preserved).
    const tokenObj = { sym: Symbol("opaque"), name: "identity-probe" };
    const returnedObj = await rpc.MathService.passthroughHandle(tokenObj, "touched-by-zig");
    assert.ok(Object.is(returnedObj, tokenObj), `${mode}: js.Handle identity lost`);
    assert.equal(tokenObj.zigTag, "touched-by-zig");
    assert.equal(await rpc.MathService.callHostHandleSync(tokenObj), "symbol:identity-probe");

    // Zig error union & argument mismatch rejections.
    await assert.rejects(() => rpc.MathService.divide(10, 0), /MathService\.divide: DivisionByZero/);
    await assert.rejects(() => rpc.MathService.divide(10), /MathService\.divide: MissingArgument/);
    await assert.rejects(() => rpc.MathService.divide(10, 2, 99), /MathService\.divide: TooManyArguments/);
    await assert.rejects(() => rpc.MathService.noSuchMethod(), /UnknownMethod/);
    await assert.rejects(() => rpc.UnknownService.ping(), /UnknownService/);

    // Layer 2 HostClient: sync ok, sync rejecting async host without unhandled rejection, async ok/err.
    assert.equal(await rpc.MathService.callHostSync("item", 42), "item#42");
    await assert.rejects(
      () => rpc.MathService.callHostAsyncInSync({ label: "async-in-sync", value: 1 }),
      /MathService\.callHostAsyncInSync: AsyncHostResult/,
    );
    await new Promise((r) => setTimeout(r, 15));
    assert.equal(unhandledRejections.length, 0, `${mode}: AsyncHostResult leaked unhandled rejection`);

    await rpc.MathService.startHostCompute({ label: "lat", value: 8 });
    await new Promise((r) => setTimeout(r, 20));
    assert.deepEqual(await rpc.MathService.pollAsync(), {
      settled: 1,
      ok: true,
      value: 20,
      label: "ok:lat",
      byte_sum: 0,
    });

    await rpc.MathService.startHostBytes(new Uint8Array([10, 20, 30]));
    await new Promise((r) => setTimeout(r, 15));
    assert.deepEqual(await rpc.MathService.pollAsync(), {
      settled: 2,
      ok: true,
      value: 20,
      label: "bytes-ok",
      byte_sum: 63,
    });

    // Synchronous return value + async rejection through HostClient.call via rpc.setHost.
    rpc.setHost({
      CheckHost: {
        syncFormat: (p, v) => `${p}:${v}`,
        asyncCompute(entry) {
          if (entry.value < 0) return Promise.reject(new TypeError("negative metric"));
          return { label: entry.label, value: entry.value + 100, note: "sync-host-return" };
        },
        transformBytes: (b) => b,
        inspectHandle: () => "ok",
      },
    });
    await rpc.MathService.startHostCompute({ label: "imm", value: 5 });
    await new Promise((r) => setTimeout(r, 10));
    assert.deepEqual(await rpc.MathService.pollAsync(), {
      settled: 3,
      ok: true,
      value: 105,
      label: "sync-host-return",
      byte_sum: 63,
    });

    await rpc.MathService.startHostCompute({ label: "neg", value: -1 });
    await new Promise((r) => setTimeout(r, 10));
    assert.deepEqual(await rpc.MathService.pollAsync(), {
      settled: 4,
      ok: false,
      value: -1,
      label: "TypeError: negative metric",
      byte_sum: 63,
    });

    // Event.emit + unsubscribe check.
    assert.equal(await rpc.MathService.emitCounter(5, "manual"), 7);
    assert.deepEqual(seenOnce, [{ count: 1, source: "alpha" }]);
    assert.equal(seenEvents.length, 3);
    offCounter();
    assert.equal(await rpc.MathService.emitCounter(1, "after-off"), 8);
    assert.equal(seenEvents.length, 3, `${mode}: unsubscribed listener still fired`);
    assert.ok(exp.rpc_check_zig_wakes() >= 8);

    // Zero handle leaks before & after destroy.
    assert.equal(jsBridge.liveCount(), baselineLive, `${mode}: leaked per-call handles`);
    rpc.destroy();
    assert.equal(jsBridge.liveCount(), 0, `${mode}: rpc.destroy did not release persistent handles`);
    jsBridge.destroy();
    assert.equal(jsBridge.liveCount(), 0);
    assert.equal(unhandledRejections.length, 0);
    console.log(`${mode}: RPC probe passed (${wasmBytes.length} bytes)`);
  }
} finally {
  process.off("unhandledRejection", onUnhandled);
  delete globalThis.__checkBigInt;
  delete globalThis.__checkLongUtf8;
  delete globalThis.__checkLongBytes;
  delete globalThis.__zigEchoUtf8;
  delete globalThis.__zigEchoBytes;
  delete globalThis.__throwCase;
  delete globalThis.__ThrowingCtor;
  delete globalThis.__growDuringHostCall;
  delete globalThis.__asyncConsumeBytes;
  delete globalThis.__makeTestPromises;
}
