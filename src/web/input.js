// Browser keyboard, EditContext / fallback textarea IME, and clipboard bridge.
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const SPECIAL_KEYS = {
  Backspace: 0x7f, Delete: 0xf728, ArrowUp: 0xf700, ArrowDown: 0xf701, ArrowLeft: 0xf702, ArrowRight: 0xf703,
  Home: 0xf729, End: 0xf72b, PageUp: 0xf72c, PageDown: 0xf72d, Enter: 0x0d, Tab: 0x09, Escape: 0x1b,
  F1: 0xf704, F2: 0xf705, F3: 0xf706, F4: 0xf707, F5: 0xf708, F6: 0xf709,
  F7: 0xf70a, F8: 0xf70b, F9: 0xf70c, F10: 0xf70d, F11: 0xf70e, F12: 0xf70f,
};
const MODIFIER_KEYS = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "NumLock", "ScrollLock", "AltGraph"]);
const RESERVED_PRIMARY = new Set(["r", "l", "t", "w", "n", "q", "j", "u", "d", "p", "+", "=", "-", "_", "0"]);
const RESERVED_DEVTOOLS = new Set(["i", "j", "c"]);

const detectApple = () => /Mac|iPhone|iPad|iPod/i.test(globalThis.navigator?.platform || globalThis.navigator?.userAgent || "");
const isMacLineKey = code => code === 0xf702 || code === 0xf703 || code === 0x7f || code === 0xf728;
const makeRect = (x, y, width, height) => typeof DOMRect === "function"
  ? new DOMRect(x, y, width, height)
  : { x, y, width, height, left: x, top: y, right: x + width, bottom: y + height };

function chordLetter(e) {
  if (typeof e.key === "string" && e.key.length === 1) return e.key.toLowerCase();
  if (typeof e.code === "string" && /^Key[A-Z]$/.test(e.code)) return e.code.slice(3).toLowerCase();
  if (typeof e.code === "string" && /^Digit[0-9]$/.test(e.code)) return e.code.slice(5);
  return "";
}

function isBrowserReserved(e) {
  if (e.key === "F5" || e.key === "F11" || e.key === "F12") return true;
  if (e.getModifierState?.("AltGraph") || (e.ctrlKey && e.altKey && !e.metaKey)) return false;
  if (!(e.ctrlKey || e.metaKey)) return false;
  const k = chordLetter(e);
  if (!k) return false;
  if (e.shiftKey && RESERVED_DEVTOOLS.has(k)) return true;
  return !e.altKey && RESERVED_PRIMARY.has(k);
}

export function createInput({ canvas, exports, memory, ime = "auto", requestFrame, flushFrame }) {
  const isApple = detectApple();
  const hasEditContext = typeof globalThis.EditContext === "function";
  const mode = ime === "textarea" || (ime !== "editcontext" && !hasEditContext) ? "textarea" : (hasEditContext ? "editcontext" : "textarea");
  const listeners = [];
  const on = (target, type, fn, opts) => {
    if (!target?.addEventListener) return;
    target.addEventListener(type, fn, opts);
    listeners.push(() => target.removeEventListener(type, fn, opts));
  };

  const hadTabIndex = canvas.hasAttribute?.("tabindex") ?? false;
  const prevTabIndex = canvas.tabIndex;
  const prevOutline = canvas.style?.outline ?? "";
  if (!hadTabIndex && (canvas.tabIndex === undefined || canvas.tabIndex < 0)) {
    canvas.tabIndex = 0;
    if (canvas.style) canvas.style.outline = "none";
  }

  let destroyed = false, focused = false, isPassword = false, composing = false, justEndedComposition = false;
  let pendingDirty = false, canvasActive = true, inClipboardEvent = false, pasteHandledInTurn = false;
  let lastWritten = null, handledKeyEvent = null, lastCaretRect = { x: 0, y: 0, w: 1, h: 16 };
  let editContext = null, editContextAttached = false, textarea = null;
  let trackedId = "", trackedText = "", trackedSelStart = 0, trackedSelEnd = 0;

  function flushIfDirty() {
    if (pendingDirty && !destroyed) {
      pendingDirty = false;
      flushFrame?.();
    }
  }

  function hasCanvasDomFocus() {
    if (typeof document === "undefined") return true;
    const ae = document.activeElement;
    return ae === canvas || ae === textarea;
  }

  function hasExternalFocusableSiblings() {
    if (typeof document === "undefined" || !document.querySelectorAll) return false;
    for (const el of document.querySelectorAll("a[href],button,input,select,textarea,[tabindex]")) {
      if (el !== canvas && el !== textarea && el.tabIndex >= 0 && !el.disabled) return true;
    }
    return false;
  }

  function isOurFocus(forTab = false) {
    if (typeof document === "undefined") return true;
    const ae = document.activeElement;
    if (ae === canvas || ae === textarea) return true;
    if (ae && ae !== document.body && ae !== document.documentElement) return false;
    if (!canvasActive) return false;
    return !(forTab && hasExternalFocusableSiblings());
  }

  function writeUtf8(str) {
    if (!exports.nanoui_web_input_ptr) return -1;
    const bytes = encoder.encode(str);
    const ptr = exports.nanoui_web_input_ptr(bytes.length);
    if (!ptr && bytes.length > 0) return -1;
    if (bytes.length > 0) {
      const mem = memory?.();
      if (!mem) return -1;
      new Uint8Array(mem.buffer, ptr, bytes.length).set(bytes);
    }
    return bytes.length;
  }

  function readImeInfo() {
    if (!exports.nanoui_web_ime_info || !exports.nanoui_web_input_ptr) return null;
    const rawPtr = exports.nanoui_web_input_ptr(44);
    if (!rawPtr) return null;
    const alignedPtr = (rawPtr + 3) & ~3;
    if (!exports.nanoui_web_ime_info(alignedPtr)) return null;
    const mem = memory?.();
    if (!mem) return null;
    const u = new Uint32Array(mem.buffer, alignedPtr, 10);
    const f = new Float32Array(mem.buffer, alignedPtr, 10);
    const flags = u[8];
    return {
      idKey: `${u[1]}:${u[0]}`, selStart: u[2], selEnd: u[3],
      caretRect: { x: f[4], y: f[5], w: Math.max(1, f[6]), h: Math.max(1, f[7]) },
      isPassword: (flags & 1) !== 0, isMultiline: (flags & 2) !== 0,
      hasMarked: (flags & 4) !== 0, backward: (flags & 8) !== 0, textByteLen: u[9],
    };
  }

  function readFocusedText(byteLen) {
    const ptr = byteLen && exports.nanoui_web_ime_text ? exports.nanoui_web_ime_text() : 0;
    const mem = ptr ? memory?.() : null;
    return mem ? decoder.decode(new Uint8Array(mem.buffer, ptr, byteLen)) : "";
  }

  function toViewportRect(r) {
    const cr = canvas.getBoundingClientRect?.() ?? { left: 0, top: 0, width: canvas.width || 1, height: canvas.height || 1 };
    const sx = canvas.clientWidth > 0 && cr.width > 0 ? cr.width / canvas.clientWidth : 1;
    const sy = canvas.clientHeight > 0 && cr.height > 0 ? cr.height / canvas.clientHeight : 1;
    return makeRect(cr.left + r.x * sx, cr.top + r.y * sy, Math.max(1, r.w * sx), Math.max(1, r.h * sy));
  }

  function isAltGraph(e, info) {
    return Boolean(e.getModifierState?.("AltGraph")) ||
      (Boolean(e.ctrlKey) && Boolean(e.altKey) && !e.metaKey && Boolean(info && !info.isSpecial && info.typed >= 0x20));
  }

  function computeMods(e, code, altGr = false) {
    let ctrl = altGr ? false : Boolean(e.ctrlKey);
    let alt = altGr ? false : Boolean(e.altKey);
    let cmd = Boolean(e.metaKey);
    if (!altGr && isApple && e.metaKey) {
      if (isMacLineKey(code)) cmd = true;
      else { ctrl = true; cmd = false; }
    }
    return Number(Boolean(e.shiftKey)) | (Number(ctrl) << 1) |
      (Number(alt) << 2) | (Number(cmd) << 3) | (Number(Boolean(e.repeat)) << 4);
  }

  function extractKey(e) {
    if (MODIFIER_KEYS.has(e.key)) return { modifierOnly: true, code: 0, typed: 0, isSpecial: false };
    const special = SPECIAL_KEYS[e.key];
    if (special !== undefined) return { modifierOnly: false, code: special, typed: 0, isSpecial: true };
    if (typeof e.key !== "string" || !e.key) return null;
    const chars = Array.from(e.key);
    if (chars.length !== 1) return null;
    const cp = chars[0].codePointAt(0);
    const altGr = Boolean(e.getModifierState?.("AltGraph")) || (Boolean(e.ctrlKey) && Boolean(e.altKey) && !e.metaKey && cp >= 0x20);
    let code = cp;
    if (!altGr && (e.ctrlKey || e.metaKey) && typeof e.code === "string") {
      if (/^Key[A-Z]$/.test(e.code)) code = e.code.charCodeAt(3) + 32;
      else if (/^Digit[0-9]$/.test(e.code)) code = e.code.charCodeAt(5);
    }
    return { modifierOnly: false, code, typed: cp >= 0x20 && cp !== 0x7f ? cp : 0, isSpecial: false };
  }

  function focusActiveTarget() {
    if (destroyed) return;
    canvasActive = true;
    const target = mode === "textarea" && textarea && focused && !isPassword ? textarea : canvas;
    target.focus?.({ preventScroll: true });
  }

  if (mode === "editcontext") {
    editContext = new globalThis.EditContext();
    on(editContext, "compositionstart", () => {
      flushIfDirty();
      composing = true;
    });
    on(editContext, "textupdate", e => {
      if (destroyed) return;
      if (!composing) flushIfDirty();
      const text = e.text ?? "";
      const rangeStart = e.updateRangeStart ?? trackedSelStart;
      const rangeEnd = e.updateRangeEnd ?? trackedSelEnd;
      trackedText = trackedText.slice(0, rangeStart) + text + trackedText.slice(rangeEnd);
      trackedSelStart = e.selectionStart ?? (rangeStart + text.length);
      trackedSelEnd = e.selectionEnd ?? trackedSelStart;
      const byteLen = writeUtf8(text);
      if (byteLen < 0) return;
      if (composing) {
        const relStart = Math.max(0, Math.min(text.length, trackedSelStart - rangeStart));
        const relEnd = Math.max(relStart, Math.min(text.length, trackedSelEnd - rangeStart));
        exports.nanoui_web_ime_set_marked(byteLen, relStart, relEnd);
      } else {
        exports.nanoui_web_ime_replace_utf16(rangeStart, rangeEnd, byteLen);
        const endPos = rangeStart + text.length;
        if (trackedSelStart !== endPos || trackedSelEnd !== endPos) {
          exports.nanoui_web_ime_select(trackedSelStart, trackedSelEnd);
        }
      }
      pendingDirty = true;
      requestFrame?.();
    });
    on(editContext, "compositionend", e => {
      if (destroyed || !composing) return;
      composing = false;
      const byteLen = writeUtf8(e.data ?? "");
      if (byteLen >= 0) {
        exports.nanoui_web_ime_commit(byteLen);
        pendingDirty = true;
      }
      requestFrame?.();
    });
    on(editContext, "characterboundsupdate", e => {
      const start = e.rangeStart ?? 0, end = Math.max(start, e.rangeEnd ?? start);
      const rect = toViewportRect(lastCaretRect), bounds = [];
      for (let i = start; i < end; i++) bounds.push(rect);
      editContext.updateCharacterBounds?.(start, bounds);
    });
  } else if (typeof document !== "undefined") {
    textarea = document.createElement("textarea");
    for (const [k, v] of [["autocapitalize", "off"], ["autocomplete", "off"], ["autocorrect", "off"], ["spellcheck", "false"], ["aria-hidden", "true"]]) {
      textarea.setAttribute(k, v);
    }
    textarea.tabIndex = -1;
    Object.assign(textarea.style, {
      position: "fixed", left: "0px", top: "0px", width: "1px", height: "1px",
      padding: "0", border: "0", margin: "0", opacity: "0", pointerEvents: "none",
      resize: "none", overflow: "hidden", whiteSpace: "pre", zIndex: "-1",
    });
    (canvas.parentElement || document.body || document.documentElement)?.appendChild(textarea);

    const sendTextareaMarked = text => {
      const byteLen = writeUtf8(text);
      if (byteLen < 0) return;
      const s0 = Math.max(0, Math.min(text.length, textarea.selectionStart ?? text.length));
      const s1 = Math.max(s0, Math.min(text.length, textarea.selectionEnd ?? s0));
      exports.nanoui_web_ime_set_marked(byteLen, s0, s1);
      pendingDirty = true;
      requestFrame?.();
    };
    on(textarea, "compositionstart", () => {
      flushIfDirty();
      composing = true;
      justEndedComposition = false;
    });
    on(textarea, "compositionupdate", e => { if (!destroyed && composing) sendTextareaMarked(e.data ?? textarea.value ?? ""); });
    on(textarea, "compositionend", e => {
      if (destroyed || !composing) return;
      composing = false;
      const committed = e.data ?? textarea.value ?? "";
      textarea.value = "";
      justEndedComposition = true;
      const byteLen = writeUtf8(committed);
      if (byteLen >= 0) {
        exports.nanoui_web_ime_commit(byteLen);
        pendingDirty = true;
      }
      requestFrame?.();
    });
    on(textarea, "input", e => {
      if (destroyed) return;
      if (!composing && !e.isComposing && (e.inputType === "insertCompositionText" || e.inputType === "insertFromComposition" || justEndedComposition)) {
        textarea.value = "";
        justEndedComposition = false;
        return;
      }
      if (composing || e.isComposing) {
        sendTextareaMarked(textarea.value || e.data || "");
        return;
      }
      flushIfDirty();
      if (e.inputType === "deleteContentBackward" || e.inputType === "deleteContentForward") {
        textarea.value = "";
        exports.nanoui_web_key(0, e.inputType === "deleteContentBackward" ? 0x7f : 0xf728, 0, 0);
        pendingDirty = true;
        requestFrame?.();
        return;
      }
      if (e.inputType === "insertFromPaste") {
        const pasted = textarea.value || e.data || "";
        textarea.value = "";
        if (!pasteHandledInTurn && pasted) pasteText(pasted);
        return;
      }
      const inserted = textarea.value || e.data || "";
      textarea.value = "";
      if (!inserted) return;
      const byteLen = writeUtf8(inserted);
      if (byteLen >= 0) {
        exports.nanoui_web_ime_commit(byteLen);
        pendingDirty = true;
        requestFrame?.();
      }
    });
  }

  function onKeyDown(e) {
    if (destroyed || handledKeyEvent === e) return;
    if (e.target !== canvas && e.target !== textarea && !isOurFocus(e.key === "Tab")) return;
    handledKeyEvent = e;
    if (composing || e.isComposing || e.keyCode === 229) return;
    justEndedComposition = false;
    if (isBrowserReserved(e)) return;

    const info = extractKey(e);
    if (!info) return;
    const altGr = isAltGraph(e, info);
    const primary = isApple ? e.metaKey : e.ctrlKey;
    const letter = chordLetter(e);
    if (!altGr && primary && !e.altKey && !e.shiftKey && (letter === "c" || letter === "x" || letter === "v")) {
      return;
    }

    const mods = computeMods(e, info.code, altGr);
    if (info.modifierOnly) { exports.nanoui_web_key(3, 0, mods, 0); return; }

    flushIfDirty();
    const plainPrintable = !info.isSpecial && (altGr || (!e.ctrlKey && !e.metaKey && !e.altKey)) && info.typed !== 0;
    const imeTargetActive = focused && !isPassword && e.isTrusted && (
      (mode === "editcontext" && editContextAttached && (typeof document === "undefined" || document.activeElement === canvas)) ||
      (mode === "textarea" && typeof document !== "undefined" && document.activeElement === textarea)
    );
    if (plainPrintable && imeTargetActive) return;

    const consumed = exports.nanoui_web_key(0, info.code, mods, info.typed);
    pendingDirty = true;
    if (consumed) e.preventDefault();
  }

  function onKeyUp(e) {
    if (destroyed || handledKeyEvent === e) return;
    if (e.target !== canvas && e.target !== textarea && !isOurFocus(false)) return;
    handledKeyEvent = e;
    if (composing || e.isComposing || e.keyCode === 229) return;
    const info = extractKey(e);
    if (!info) return;
    exports.nanoui_web_key(info.modifierOnly ? 3 : 1, info.code, computeMods(e, info.code, isAltGraph(e, info)), 0);
  }

  function pasteText(text) {
    if (destroyed || !text || !exports.nanoui_web_paste) return false;
    flushIfDirty();
    const byteLen = writeUtf8(text);
    if (byteLen < 0) return false;
    exports.nanoui_web_paste(byteLen);
    pendingDirty = true;
    requestFrame?.();
    return true;
  }

  function runClipboardOp(isCut) {
    if (destroyed || !exports.nanoui_web_clipboard_op) return null;
    flushIfDirty();
    lastWritten = null;
    const rc = exports.nanoui_web_clipboard_op(isCut ? 1 : 0);
    if (rc === 2) flushFrame?.();
    return rc && lastWritten !== null ? lastWritten : null;
  }

  const copy = () => runClipboardOp(false);
  const cut = () => runClipboardOp(true);

  function handleCopyOrCut(e, isCut) {
    if (destroyed || !isOurFocus(false)) return;
    inClipboardEvent = true;
    try {
      const text = runClipboardOp(isCut);
      if (text !== null) { e.clipboardData?.setData("text/plain", text); e.preventDefault(); }
    } finally {
      inClipboardEvent = false;
    }
  }

  function handlePaste(e) {
    if (destroyed || !isOurFocus(false)) return;
    const text = e.clipboardData?.getData("text/plain") ?? "";
    if (!text) return;
    pasteHandledInTurn = true;
    queueMicrotask(() => { pasteHandledInTurn = false; });
    if (pasteText(text)) e.preventDefault();
  }

  on(canvas, "pointerdown", () => focusActiveTarget());
  on(canvas, "focus", () => { canvasActive = true; });
  on(canvas, "keydown", onKeyDown);
  on(canvas, "keyup", onKeyUp);
  if (textarea) {
    on(textarea, "focus", () => { canvasActive = true; });
    on(textarea, "keydown", onKeyDown);
    on(textarea, "keyup", onKeyUp);
  }
  if (typeof document !== "undefined") {
    on(document, "pointerdown", e => {
      if (e.target !== canvas && e.target !== textarea) {
        canvasActive = false;
        if (!destroyed) exports.nanoui_web_key(2, 0, 0, 0);
      }
    });
    on(document, "focusin", e => {
      if (e.target === canvas || e.target === textarea) canvasActive = true;
      else if (e.target && e.target !== document.body && e.target !== document.documentElement) {
        canvasActive = false;
        if (!destroyed) exports.nanoui_web_key(2, 0, 0, 0);
      }
    });
  }
  if (typeof globalThis.addEventListener === "function") {
    on(globalThis, "keydown", onKeyDown);
    on(globalThis, "keyup", onKeyUp);
    on(globalThis, "blur", () => { if (!destroyed) exports.nanoui_web_key(2, 0, 0, 0); });
  }
  const clipTarget = typeof document !== "undefined" ? document : globalThis;
  on(clipTarget, "copy", e => handleCopyOrCut(e, false));
  on(clipTarget, "cut", e => handleCopyOrCut(e, true));
  on(clipTarget, "paste", handlePaste);

  function syncAfterFrame() {
    if (destroyed) return;
    pendingDirty = false;
    const info = readImeInfo();
    focused = Boolean(info);
    isPassword = Boolean(info?.isPassword);
    if (info) lastCaretRect = info.caretRect;

    if (mode === "editcontext" && editContext) {
      if (!info || info.isPassword) {
        if (editContextAttached) { canvas.editContext = null; editContextAttached = false; }
        composing = false;
        trackedId = ""; trackedText = ""; trackedSelStart = 0; trackedSelEnd = 0;
        return;
      }
      if (!editContextAttached) { canvas.editContext = editContext; editContextAttached = true; }
      const cr = canvas.getBoundingClientRect?.();
      if (cr) {
        editContext.updateControlBounds?.(makeRect(cr.left, cr.top, cr.width, cr.height));
        editContext.updateSelectionBounds?.(toViewportRect(info.caretRect));
      }
      if (!composing && !info.hasMarked) {
        const nextText = readFocusedText(info.textByteLen);
        if (info.idKey !== trackedId || nextText !== trackedText) {
          const prevLen = trackedText.length;
          trackedId = info.idKey; trackedText = nextText;
          trackedSelStart = info.selStart; trackedSelEnd = info.selEnd;
          editContext.updateText?.(0, prevLen, nextText);
          editContext.updateSelection?.(info.selStart, info.selEnd);
        } else if (info.selStart !== trackedSelStart || info.selEnd !== trackedSelEnd) {
          trackedSelStart = info.selStart; trackedSelEnd = info.selEnd;
          editContext.updateSelection?.(info.selStart, info.selEnd);
        }
      }
      return;
    }

    if (textarea) {
      if (!info || info.isPassword) {
        composing = false;
        if (textarea.value !== "") textarea.value = "";
        if (typeof document !== "undefined" && document.activeElement === textarea) {
          canvas.focus?.({ preventScroll: true });
        }
        return;
      }
      const rect = toViewportRect(info.caretRect);
      textarea.style.left = `${Math.round(rect.x)}px`;
      textarea.style.top = `${Math.round(rect.y)}px`;
      textarea.style.height = `${Math.max(1, Math.round(rect.height))}px`;
      if (!composing && textarea.value !== "") textarea.value = "";
      if (hasCanvasDomFocus() && typeof document !== "undefined" && document.activeElement !== textarea) {
        textarea.focus?.({ preventScroll: true });
      }
    }
  }

  return {
    get mode() { return mode; },
    get editContext() { return editContext; },
    get textarea() { return textarea; },
    get focused() { return focused; },
    syncAfterFrame,
    onClipboardWrite(text) {
      lastWritten = text;
      if (!inClipboardEvent) globalThis.navigator?.clipboard?.writeText?.(text)?.catch?.(() => {});
    },
    pasteText, copy, cut,
    destroy() {
      if (destroyed) return;
      destroyed = true;
      for (const off of listeners) off();
      listeners.length = 0;
      if (editContextAttached) { canvas.editContext = null; editContextAttached = false; }
      textarea?.remove?.();
      textarea = null;
      if (!hadTabIndex) {
        canvas.removeAttribute?.("tabindex");
        if (canvas.style) canvas.style.outline = prevOutline;
      } else canvas.tabIndex = prevTabIndex;
    },
  };
}
