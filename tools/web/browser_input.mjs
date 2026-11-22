import assert from "node:assert/strict";

async function readFocusedField(page) {
  return page.evaluate(() => {
    const e = window.nanoui.exports;
    const raw = e.nanoui_web_input_ptr(44);
    const aligned = (raw + 3) & ~3;
    if (!e.nanoui_web_ime_info(aligned)) return null;
    const u = new Uint32Array(e.memory.buffer, aligned, 10);
    const flags = u[8];
    const byteLen = u[9];
    const ptr = byteLen ? e.nanoui_web_ime_text() : 0;
    const text = ptr ? new TextDecoder().decode(new Uint8Array(e.memory.buffer, ptr, byteLen)) : "";
    return {
      text,
      selStart: u[2],
      selEnd: u[3],
      isPassword: (flags & 1) !== 0,
      isMultiline: (flags & 2) !== 0,
      hasMarked: (flags & 4) !== 0,
    };
  });
}

async function waitNextFrame(page) {
  const before = await page.evaluate(() => window.nanoui.exports.nanoui_web_frames());
  await page.evaluate(() => window.nanoui.requestFrame());
  await page.waitForFunction(b => window.nanoui.exports.nanoui_web_frames() > b, before);
}

async function focusFieldMatching(page, xs, yStart, yEnd, yStep, predicate) {
  for (const x of xs) {
    for (let y = yStart; y <= yEnd; y += yStep) {
      await page.mouse.move(x, y);
      await waitNextFrame(page);
      const cursor = await page.evaluate(() => document.querySelector("canvas").style.cursor);
      if (cursor !== "text") continue;
      await page.mouse.click(x, y);
      await waitNextFrame(page);
      const info = await readFocusedField(page);
      if (info && predicate(info)) return { x, y, info };
    }
  }
  throw new Error("Could not find matching text field on canvas");
}

export async function runWebGL2AndInputSuite(browser, baseUrl, comparePage) {
  // 1. Automatic WebGL2 fallback when navigator.gpu is unavailable + context loss recovery.
  {
    const ctx = await browser.newContext({ viewport: { width: 420, height: 300 }, deviceScaleFactor: 2 });
    const page = await ctx.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.addInitScript(() => {
      Object.defineProperty(navigator, "gpu", { value: undefined, configurable: true });
    });
    await page.goto(`${baseUrl}/index.html`);
    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 1);
    assert.equal(await page.evaluate(() => window.nanoui.backend), "webgl2");
    assert.ok((await comparePage(page)).mean < 0.05, "WebGL2 auto-fallback matches CPU pixels");
    await page.mouse.click(207, 185);
    await page.waitForTimeout(300);
    assert.equal(await page.evaluate(() => Number(window.nanoui.exports.counter_value())), 1);
    const gen = await page.evaluate(() => window.nanoui.gpu.generation);
    await page.evaluate(() => window.nanoui.host.debugLoseDevice());
    await page.waitForFunction(g => window.nanoui.gpu.generation > g, gen);
    await page.waitForTimeout(300);
    assert.ok((await comparePage(page)).mean < 0.05, "WebGL2 recovers from webglcontextlost");
    await page.evaluate(async () => {
      await window.nanoui.gpu.check();
      window.nanoui.destroy();
      if (window.nanoui.gpu.objects.size !== 1) throw new Error("WebGL2 handle leak");
    });

    // Explicit WebGL2 injected context & OffscreenCanvas Worker.
    await page.evaluate(async () => {
      const { start } = await import("./nanoui.js");
      const { getWebGL2Context } = await import("./webgl2.js");
      const old = document.querySelector("canvas"); old.remove();
      const canvas = document.createElement("canvas");
      canvas.style.width = "420px"; canvas.style.height = "300px";
      document.body.append(canvas);
      const gl = getWebGL2Context(canvas);
      const runtime = await start({ canvas, url: "./counter.wasm", device: gl });
      if (runtime.backend !== "webgl2" || runtime.device !== gl) throw new Error("Injected WebGL2 context replaced");
      await runtime.gpu.check();
      runtime.destroy();
    });
    await page.evaluate(async () => {
      const old = document.querySelector("canvas"); old.remove();
      const canvas = document.createElement("canvas");
      canvas.style.width = "420px"; canvas.style.height = "300px";
      document.body.append(canvas);
      const worker = new Worker("./worker.js", { type: "module" });
      let seq = 0; const pending = new Map();
      worker.onmessage = ({ data }) => {
        if (data.error) throw new Error(data.error);
        const f = pending.get(data.id ?? "ready");
        if (f) { pending.delete(data.id ?? "ready"); f(data); }
      };
      const ready = new Promise(resolve => pending.set("ready", resolve));
      const offscreen = canvas.transferControlToOffscreen();
      worker.postMessage({ canvas: offscreen, width: 840, height: 600, scale: 2, gpu: "webgl2" }, [offscreen]);
      const readyInfo = await ready;
      if (readyInfo.backend !== "webgl2") throw new Error(`Worker backend: ${readyInfo.backend}`);
      window.glWorker = {
        worker,
        info: () => new Promise(resolve => { const id = ++seq; pending.set(id, resolve); worker.postMessage({ info: id }); }),
      };
    });
    await page.waitForTimeout(300);
    await page.evaluate(async () => {
      window.glWorker.worker.postMessage({ pointer: [0, 207, 185] });
      window.glWorker.worker.postMessage({ pointer: [1, 207, 185] });
      window.glWorker.worker.postMessage({ pointer: [2, 207, 185] });
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        if ((await window.glWorker.info()).value === 1) break;
        await new Promise(r => setTimeout(r, 40));
      }
    });
    const wInfo = await page.evaluate(() => window.glWorker.info());
    assert.equal(wInfo.backend, "webgl2");
    assert.equal(wInfo.value, 1);
    await page.evaluate(() => window.glWorker.worker.postMessage({ destroy: true }));
    assert.deepEqual(errors, []);
    await ctx.close();
  }

  // 2. Gallery E2E: Keyboard, shortcuts, EditContext IME (CJK + surrogate pairs), password suppression, and clipboard.
  {
    const ctx = await browser.newContext({ viewport: { width: 900, height: 640 }, deviceScaleFactor: 2 });
    const page = await ctx.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.goto(`${baseUrl}/index.html?app=gallery&gpu=webgl2`);
    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 1);
    assert.equal(await page.evaluate(() => window.nanoui.backend), "webgl2");
    assert.equal(await page.evaluate(() => window.nanoui.host.input.mode), "editcontext");

    // Switch to List page (index 3) and focus the filter text field.
    await page.evaluate(() => window.nanoui.exports.gallery_page(3));
    await waitNextFrame(page);
    await focusFieldMatching(page, [320, 260, 380], 50, 180, 12, f => !f.isPassword && !f.isMultiline);

    // Keyboard typing, navigation, selection, undo/redo.
    await page.keyboard.type("Item 42");
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "Item 42");
    await page.keyboard.press("Backspace");
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "Item 4");
    await page.keyboard.press("Control+a");
    await page.keyboard.press("Backspace");
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "");
    await page.keyboard.type("abc");
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "abc");
    await page.keyboard.press("Control+z");
    await waitNextFrame(page);
    const afterUndo = (await readFocusedField(page)).text;
    assert.notEqual(afterUndo, "abc");
    await page.keyboard.press("Control+y");
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "abc");

    // Browser-reserved chords are never preventDefault()ed; app shortcut Ctrl+K is consumed.
    const chordCheck = await page.evaluate(() => {
      const canvas = document.querySelector("canvas");
      const rEvt = new KeyboardEvent("keydown", { key: "r", code: "KeyR", ctrlKey: true, bubbles: true, cancelable: true });
      canvas.dispatchEvent(rEvt);
      const kEvt = new KeyboardEvent("keydown", { key: "k", code: "KeyK", ctrlKey: true, bubbles: true, cancelable: true });
      canvas.dispatchEvent(kEvt);
      return { rPrevented: rEvt.defaultPrevented, kPrevented: kEvt.defaultPrevented };
    });
    assert.equal(chordCheck.rPrevented, false, "Ctrl+R must not be intercepted");
    assert.equal(chordCheck.kPrevented, true, "Ctrl+K app shortcut is consumed");
    await page.keyboard.press("Escape");
    await waitNextFrame(page);

    // Refocus List filter field and test EditContext IME composition + UTF-16 surrogate pairs.
    await page.evaluate(() => window.nanoui.exports.gallery_page(3));
    await waitNextFrame(page);
    await focusFieldMatching(page, [320, 260, 380], 50, 180, 12, f => !f.isPassword && !f.isMultiline);
    await page.keyboard.press("Control+a");
    await page.keyboard.press("Backspace");
    await waitNextFrame(page);

    await page.evaluate(() => {
      const ec = window.nanoui.host.input.editContext;
      const mkUpdate = init => typeof TextUpdateEvent === "function"
        ? new TextUpdateEvent("textupdate", init)
        : Object.assign(new Event("textupdate"), init);
      ec.dispatchEvent(new Event("compositionstart"));
      ec.dispatchEvent(mkUpdate({ text: "にほん", updateRangeStart: 0, updateRangeEnd: 0, selectionStart: 3, selectionEnd: 3 }));
    });
    await waitNextFrame(page);
    {
      const f = await readFocusedField(page);
      assert.equal(f.text, "にほん");
      assert.equal(f.hasMarked, true);
    }
    await page.evaluate(() => {
      const ec = window.nanoui.host.input.editContext;
      const mkUpdate = init => typeof TextUpdateEvent === "function"
        ? new TextUpdateEvent("textupdate", init)
        : Object.assign(new Event("textupdate"), init);
      ec.dispatchEvent(mkUpdate({ text: "日本", updateRangeStart: 0, updateRangeEnd: 3, selectionStart: 2, selectionEnd: 2 }));
      ec.dispatchEvent(new CompositionEvent("compositionend", { data: "日本" }));
    });
    await waitNextFrame(page);
    {
      const f = await readFocusedField(page);
      assert.equal(f.text, "日本");
      assert.equal(f.hasMarked, false);
    }

    // Surrogate-pair UTF-16 indexing: "a😀b" = 4 UTF-16 code units, 6 UTF-8 bytes; replace [3,4) ("b") -> "語".
    await page.evaluate(() => {
      const ec = window.nanoui.host.input.editContext;
      const mkUpdate = init => typeof TextUpdateEvent === "function"
        ? new TextUpdateEvent("textupdate", init)
        : Object.assign(new Event("textupdate"), init);
      ec.dispatchEvent(mkUpdate({ text: "a😀b", updateRangeStart: 0, updateRangeEnd: 2, selectionStart: 4, selectionEnd: 4 }));
      ec.dispatchEvent(mkUpdate({ text: "語", updateRangeStart: 3, updateRangeEnd: 4, selectionStart: 4, selectionEnd: 4 }));
      const cbEvt = typeof CharacterBoundsUpdateEvent === "function"
        ? new CharacterBoundsUpdateEvent("characterboundsupdate", { rangeStart: 0, rangeEnd: 4 })
        : Object.assign(new Event("characterboundsupdate"), { rangeStart: 0, rangeEnd: 4 });
      ec.dispatchEvent(cbEvt);
    });
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "a😀語");

    // Rapid multi-key burst ("he|llo" -> "a", Backspace, "b" -> "hebllo") + AltGr ("€").
    await page.keyboard.press("Control+a");
    await page.keyboard.press("Backspace");
    await page.keyboard.type("hello");
    await waitNextFrame(page);
    await page.evaluate(() => {
      window.nanoui.exports.nanoui_web_ime_select(2, 2);
      window.nanoui.host.flushFrame();
    });
    await page.keyboard.type("a");
    await page.keyboard.press("Backspace");
    await page.keyboard.type("b");
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "hebllo");
    await page.evaluate(() => {
      const canvas = document.querySelector("canvas");
      const evt = new KeyboardEvent("keydown", { key: "€", code: "KeyE", ctrlKey: true, altKey: true, bubbles: true, cancelable: true });
      canvas.dispatchEvent(evt);
    });
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "heb€llo");

    // Clipboard: single-line paste normalizes CRLF -> space, copy & cut populate clipboardData,
    // and real trusted Ctrl+C / Ctrl+X / Ctrl+V paste exactly once without double-insertion.
    await ctx.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.keyboard.press("Control+a");
    await page.keyboard.press("Backspace");
    await waitNextFrame(page);
    await page.evaluate(() => {
      const dt = new DataTransfer();
      dt.setData("text/plain", "hello\r\nworld");
      document.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
    });
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "hello world");

    const clipResult = await page.evaluate(() => {
      window.nanoui.exports.nanoui_web_ime_select(0, 5);
      window.nanoui.host.flushFrame();
      const copyDt = new DataTransfer();
      document.dispatchEvent(new ClipboardEvent("copy", { clipboardData: copyDt, bubbles: true, cancelable: true }));
      const copied = copyDt.getData("text/plain");
      const cutDt = new DataTransfer();
      document.dispatchEvent(new ClipboardEvent("cut", { clipboardData: cutDt, bubbles: true, cancelable: true }));
      return { copied, hostClip: window.nanoui.host.clipboardText, cut: cutDt.getData("text/plain") };
    });
    await waitNextFrame(page);
    assert.equal(clipResult.copied, "hello");
    assert.equal(clipResult.hostClip, "hello");
    assert.equal(clipResult.cut, "hello");
    assert.equal((await readFocusedField(page)).text, " world");

    await page.keyboard.press("Control+a");
    await page.keyboard.press("Control+x");
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "");
    await page.keyboard.press("Control+v");
    await page.waitForTimeout(100);
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, " world", "Ctrl+V must paste once, never twice");

    // Controls page (index 0): Tab to Password & Multiline textArea.
    await page.evaluate(() => window.nanoui.exports.gallery_page(0));
    await waitNextFrame(page);
    const tabToField = async predicate => {
      for (let i = 0; i < 16; i++) {
        await page.keyboard.press("Tab");
        await waitNextFrame(page);
        const info = await readFocusedField(page);
        if (info && predicate(info)) return info;
      }
      throw new Error("Could not Tab to matching text field");
    };

    // Password field detaches EditContext so IME never reads secrets.
    await tabToField(f => f.isPassword);
    assert.equal(await page.evaluate(() => document.querySelector("canvas").editContext), null);

    // Tab cycles focus from password field to multiline textArea and re-attaches EditContext.
    await tabToField(f => f.isMultiline);
    assert.notEqual(await page.evaluate(() => document.querySelector("canvas").editContext), null);
    await page.evaluate(() => {
      const dt = new DataTransfer();
      dt.setData("text/plain", "line1\r\nline2");
      document.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
    });
    await waitNextFrame(page);
    assert.equal((await readFocusedField(page)).text, "line1\nline2");
    await page.evaluate(() => window.nanoui.destroy());
    assert.deepEqual(errors, []);
    await ctx.close();
  }

  // 3. Fallback <textarea> IME mode (?ime=textarea).
  {
    const ctx = await browser.newContext({ viewport: { width: 900, height: 640 }, deviceScaleFactor: 2 });
    const page = await ctx.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.goto(`${baseUrl}/index.html?app=gallery&gpu=webgl2&ime=textarea`);
    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 1);
    assert.equal(await page.evaluate(() => window.nanoui.host.input.mode), "textarea");
    await page.evaluate(() => window.nanoui.exports.gallery_page(3));
    await waitNextFrame(page);
    await focusFieldMatching(page, [320, 260, 380], 50, 180, 12, f => !f.isPassword && !f.isMultiline);
    assert.equal(await page.evaluate(() => document.activeElement === window.nanoui.host.input.textarea), true);

    await page.evaluate(() => {
      const ta = window.nanoui.host.input.textarea;
      ta.dispatchEvent(new CompositionEvent("compositionstart", { data: "" }));
      ta.value = "かん";
      ta.setSelectionRange(2, 2);
      ta.dispatchEvent(new CompositionEvent("compositionupdate", { data: "かん" }));
    });
    await waitNextFrame(page);
    {
      const f = await readFocusedField(page);
      assert.equal(f.text, "かん");
      assert.equal(f.hasMarked, true);
    }
    await page.evaluate(() => {
      const ta = window.nanoui.host.input.textarea;
      ta.value = "漢字";
      ta.dispatchEvent(new CompositionEvent("compositionend", { data: "漢字" }));
      // Firefox dispatches insertCompositionText *after* compositionend.
      ta.dispatchEvent(new InputEvent("input", { data: "漢字", inputType: "insertCompositionText" }));
    });
    await waitNextFrame(page);
    {
      const f = await readFocusedField(page);
      assert.equal(f.text, "漢字");
      assert.equal(f.hasMarked, false);
    }

    // External DOM focus is never stolen back by syncAfterFrame.
    const keptExternalFocus = await page.evaluate(() => {
      const btn = document.createElement("button");
      btn.textContent = "Outside";
      document.body.append(btn);
      btn.focus();
      window.nanoui.host.flushFrame();
      const kept = document.activeElement === btn;
      btn.remove();
      return kept;
    });
    assert.equal(keptExternalFocus, true, "syncAfterFrame must not steal focus from external DOM elements");
    await page.evaluate(() => window.nanoui.destroy());
    assert.deepEqual(errors, []);
    await ctx.close();
  }
}
