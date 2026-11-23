// Generational JS handle table, stack-marshalled call bridge, and Promise continuations.
const FREE = Symbol("nanoui.js.free");
const INVALID_HANDLE = Symbol("nanoui.js.invalid");
const STATUS_OK = 0, STATUS_EXCEPTION = 1, STATUS_INVALID_HANDLE = 2, STATUS_TYPE_MISMATCH = 3;
const RAW_ERR_EXCEPTION = 0xFFFFFFFF, RAW_ERR_INVALID_HANDLE = 0xFFFFFFFE, RAW_ERR_OOM = 0xFFFFFFFC;
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();
const emptyBytes = new Uint8Array(0);
const TYPE_MAP = { boolean: 2, number: 3, bigint: 4, string: 5, symbol: 6, function: 7 };

export function formatError(err) {
  try {
    if (err === INVALID_HANDLE) return "Invalid JS handle";
    if (typeof err === "string") return err;
    if (err !== null && typeof err === "object") {
      if (err instanceof Error || typeof err.message === "string") {
        const name = typeof err.name === "string" ? err.name : "";
        const msg = typeof err.message === "string" ? err.message : "";
        return name && name !== "Error" ? (msg ? `${name}: ${msg}` : name) : (msg || name || "Error");
      }
      try {
        const json = JSON.stringify(err);
        if (json !== undefined) return json;
      } catch {}
    }
    return String(err);
  } catch {
    return "Unprintable JS error";
  }
}

export function createJSBridge(memoryOrOptions, maybeExports) {
  const isOpts = memoryOrOptions !== null && typeof memoryOrOptions === "object" && typeof memoryOrOptions !== "function";
  const getMemory = isOpts ? memoryOrOptions.memory : memoryOrOptions;
  const getExports = isOpts ? memoryOrOptions.exports : maybeExports;
  let onWake = isOpts ? (memoryOrOptions.wake ?? null) : null;
  let destroyed = false, pendingRead = null, lastErrBytes = emptyBytes, callDepth = 0;
  const slots = [undefined, null, false, true, globalThis];
  const gens = [0, 0, 0, 0, 0];
  const free = [];

  function allocDynamic(val) {
    let idx;
    if (free.length > 0) idx = free.pop();
    else {
      idx = slots.length;
      if (idx > 0xFFFFFF) return RAW_ERR_OOM;
      gens.push(1);
    }
    slots[idx] = val;
    return ((gens[idx] << 24) | idx) >>> 0;
  }

  function allocSlot(val) {
    if (val === undefined) return 0;
    if (val === null) return 1;
    if (val === false) return 2;
    if (val === true) return 3;
    if (val === globalThis) return 4;
    return allocDynamic(val);
  }

  function readSlot(raw) {
    const u = raw >>> 0;
    if (u <= 4) return slots[u];
    const idx = u & 0xFFFFFF, gen = u >>> 24;
    if (gen === 0 || gen === 0xFF || idx < 5 || idx >= slots.length || gens[idx] !== gen) throw INVALID_HANDLE;
    const val = slots[idx];
    if (val === FREE) throw INVALID_HANDLE;
    return val;
  }

  function releaseSlot(raw) {
    const u = raw >>> 0;
    if (u <= 4) return;
    const idx = u & 0xFFFFFF, gen = u >>> 24;
    if (gen === 0 || gen === 0xFF || idx < 5 || idx >= slots.length || gens[idx] !== gen || slots[idx] === FREE) return;
    slots[idx] = FREE;
    gens[idx] = (gen % 254) + 1;
    free.push(idx);
  }

  function rawErr(err) {
    if (err === INVALID_HANDLE) return RAW_ERR_INVALID_HANDLE;
    lastErrBytes = textEncoder.encode(formatError(err));
    return RAW_ERR_EXCEPTION;
  }

  function statusErr(err) {
    if (err === INVALID_HANDLE) return STATUS_INVALID_HANDLE;
    lastErrBytes = textEncoder.encode(formatError(err));
    return STATUS_EXCEPTION;
  }

  function readUtf8(ptr, len) {
    const n = len >>> 0;
    return n === 0 ? "" : textDecoder.decode(new Uint8Array(getMemory().buffer, ptr >>> 0, n));
  }

  function copyBytes(ptr, len) {
    const n = len >>> 0;
    return n === 0 ? new Uint8Array(0) : new Uint8Array(getMemory().buffer, ptr >>> 0, n).slice();
  }

  function decodeOneArg(buf, view, off) {
    switch (view.getUint32(off, true)) {
      case 0: return undefined;
      case 1: return null;
      case 2: return view.getUint32(off + 4, true) !== 0;
      case 3: return view.getInt32(off + 4, true);
      case 4: return view.getUint32(off + 4, true);
      case 5: return view.getFloat64(off + 8, true);
      case 6: return view.getBigUint64(off + 8, true);
      case 7: return view.getUint32(off + 4, true);
      case 8: {
        const n = view.getUint32(off + 8, true);
        return n === 0 ? "" : textDecoder.decode(new Uint8Array(buf, view.getUint32(off + 4, true), n));
      }
      case 9: {
        const n = view.getUint32(off + 8, true);
        return n === 0 ? new Uint8Array(0) : new Uint8Array(buf, view.getUint32(off + 4, true), n).slice();
      }
      case 10: return readSlot(view.getUint32(off + 4, true));
      default: throw INVALID_HANDLE;
    }
  }

  function decodeArgs(argsPtr, argsLen) {
    const count = argsLen >>> 0;
    if (count === 0) return [];
    const buf = getMemory().buffer, view = new DataView(buf), base = argsPtr >>> 0, out = new Array(count);
    for (let i = 0; i < count; i++) out[i] = decodeOneArg(buf, view, base + i * 16);
    return out;
  }

  function writeOrStash(bytes, dstPtr, dstCap, outLenPtr) {
    const buf = getMemory().buffer, cap = dstCap >>> 0;
    new DataView(buf).setUint32(outLenPtr >>> 0, bytes.byteLength, true);
    if (bytes.byteLength <= cap) {
      if (bytes.byteLength > 0) new Uint8Array(buf, dstPtr >>> 0, bytes.byteLength).set(bytes);
      pendingRead = null;
    } else pendingRead = bytes;
    return STATUS_OK;
  }

  function asByteView(val) {
    if (val instanceof Uint8Array) return val;
    if (val instanceof ArrayBuffer) return new Uint8Array(val);
    return ArrayBuffer.isView(val) ? new Uint8Array(val.buffer, val.byteOffset, val.byteLength) : null;
  }

  const imports = {
    obj_new: () => allocDynamic({}),
    arr_new: () => allocDynamic([]),
    num_new: v => allocDynamic(v),
    bigint_new: v => allocDynamic(BigInt.asUintN(64, v)),
    str_new(ptr, len) { try { return allocDynamic(readUtf8(ptr, len)); } catch (e) { return rawErr(e); } },
    bytes_new(ptr, len) { try { return allocDynamic(copyBytes(ptr, len)); } catch (e) { return rawErr(e); } },
    dup(raw) {
      const u = raw >>> 0;
      if (u <= 4) return u;
      try { return allocDynamic(readSlot(u)); } catch { return RAW_ERR_INVALID_HANDLE; }
    },
    release: releaseSlot,
    live_count: () => (slots.length - 5 - free.length) >>> 0,
    value_kind(raw, outPtr) {
      try {
        const val = readSlot(raw);
        const kind = val === undefined ? 0 : val === null ? 1 : (TYPE_MAP[typeof val] ?? 8);
        let flags = kind;
        if (Array.isArray(val)) flags |= 16;
        if (val instanceof Promise || (val !== null && (kind === 7 || kind === 8) && typeof val.then === "function")) flags |= 32;
        if (asByteView(val) !== null) flags |= 64;
        new DataView(getMemory().buffer).setUint32(outPtr >>> 0, flags >>> 0, true);
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
    },
    prop_get(raw, keyPtr, keyLen) {
      callDepth++;
      try { return allocSlot(readSlot(raw)[readUtf8(keyPtr, keyLen)]); }
      catch (e) { return rawErr(e); }
      finally { callDepth--; }
    },
    idx_get(raw, index) { try { return allocSlot(readSlot(raw)[index >>> 0]); } catch (e) { return rawErr(e); } },
    prop_set(raw, keyPtr, keyLen, valPtr) {
      callDepth++;
      try {
        const target = readSlot(raw), key = readUtf8(keyPtr, keyLen), buf = getMemory().buffer;
        target[key] = decodeOneArg(buf, new DataView(buf), valPtr >>> 0);
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
      finally { callDepth--; }
    },
    idx_set(raw, index, valPtr) {
      try {
        const target = readSlot(raw), buf = getMemory().buffer;
        target[index >>> 0] = decodeOneArg(buf, new DataView(buf), valPtr >>> 0);
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
    },
    prop_has(raw, keyPtr, keyLen, outPtr) {
      try {
        new DataView(getMemory().buffer).setUint32(outPtr >>> 0, (readUtf8(keyPtr, keyLen) in readSlot(raw)) ? 1 : 0, true);
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
    },
    prop_del(raw, keyPtr, keyLen) {
      callDepth++;
      try { delete readSlot(raw)[readUtf8(keyPtr, keyLen)]; return STATUS_OK; }
      catch (e) { return statusErr(e); }
      finally { callDepth--; }
    },
    value_len(raw, outPtr) {
      try {
        const val = readSlot(raw), bv = asByteView(val);
        let n;
        if (bv !== null) n = bv.byteLength;
        else if (typeof val === "string") n = textEncoder.encode(val).byteLength;
        else if (val !== null && typeof val === "object" && typeof val.length === "number") n = val.length >>> 0;
        else return STATUS_TYPE_MISMATCH;
        new DataView(getMemory().buffer).setUint32(outPtr >>> 0, n >>> 0, true);
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
    },
    as_number(raw, outPtr) {
      try {
        const val = readSlot(raw);
        if (typeof val !== "number") return STATUS_TYPE_MISMATCH;
        new DataView(getMemory().buffer).setFloat64(outPtr >>> 0, val, true);
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
    },
    as_int(raw, signed, outPtr) {
      try {
        const val = readSlot(raw), dv = new DataView(getMemory().buffer);
        const bi = typeof val === "bigint" ? val : (typeof val === "number" && Number.isSafeInteger(val) ? BigInt(val) : null);
        if (bi === null) return STATUS_TYPE_MISMATCH;
        if (signed) {
          if (bi < -0x8000000000000000n || bi > 0x7FFFFFFFFFFFFFFFn) return STATUS_TYPE_MISMATCH;
          dv.setBigInt64(outPtr >>> 0, bi, true);
        } else {
          if (bi < 0n || bi > 0xFFFFFFFFFFFFFFFFn) return STATUS_TYPE_MISMATCH;
          dv.setBigUint64(outPtr >>> 0, bi, true);
        }
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
    },
    read_buf(mode, raw, dstPtr, dstCap, outLenPtr) {
      try {
        if (mode === 3) return writeOrStash(lastErrBytes, dstPtr, dstCap, outLenPtr);
        const val = readSlot(raw);
        if (mode === 0) return typeof val === "string" ? writeOrStash(textEncoder.encode(val), dstPtr, dstCap, outLenPtr) : STATUS_TYPE_MISMATCH;
        if (mode === 1) {
          const bv = asByteView(val);
          return bv !== null ? writeOrStash(bv.byteLength > (dstCap >>> 0) ? bv.slice() : bv, dstPtr, dstCap, outLenPtr) : STATUS_TYPE_MISMATCH;
        }
        const json = JSON.stringify(val);
        return json === undefined ? STATUS_TYPE_MISMATCH : writeOrStash(textEncoder.encode(json), dstPtr, dstCap, outLenPtr);
      } catch (e) { return statusErr(e); }
    },
    read_pending(dstPtr, dstLen) {
      const src = pendingRead, n = dstLen >>> 0;
      pendingRead = null;
      if (src && n > 0) new Uint8Array(getMemory().buffer, dstPtr >>> 0, n).set(src.subarray(0, n));
    },
    json_parse(ptr, len) { try { return allocSlot(JSON.parse(readUtf8(ptr, len))); } catch (e) { return rawErr(e); } },
    call(fnRaw, thisRaw, argsPtr, argsLen) {
      callDepth++;
      try { return allocSlot(Reflect.apply(readSlot(fnRaw), readSlot(thisRaw), decodeArgs(argsPtr, argsLen))); }
      catch (e) { return rawErr(e); }
      finally { callDepth--; }
    },
    invoke(raw, namePtr, nameLen, argsPtr, argsLen) {
      callDepth++;
      try {
        const target = readSlot(raw), method = readUtf8(namePtr, nameLen), jsArgs = decodeArgs(argsPtr, argsLen);
        return allocSlot(Reflect.apply(target[method], target, jsArgs));
      } catch (e) { return rawErr(e); }
      finally { callDepth--; }
    },
    construct(ctorRaw, argsPtr, argsLen) {
      callDepth++;
      try { return allocSlot(Reflect.construct(readSlot(ctorRaw), decodeArgs(argsPtr, argsLen))); }
      catch (e) { return rawErr(e); }
      finally { callDepth--; }
    },
    promise_then(raw, cbId) {
      try {
        const val = readSlot(raw), id = cbId >>> 0;
        if (id === 0) {
          Promise.resolve(val).catch(() => {});
          return STATUS_OK;
        }
        Promise.resolve(val).then(
          res => {
            if (destroyed) return;
            getExports()?.nanoui_js_settle?.(id, 1, allocSlot(res));
            onWake?.();
          },
          reason => {
            if (destroyed) return;
            getExports()?.nanoui_js_settle?.(id, 0, allocDynamic(formatError(reason)));
            onWake?.();
          },
        );
        return STATUS_OK;
      } catch (e) { return statusErr(e); }
    },
  };

  return {
    imports,
    formatError,
    allocHandle: allocSlot,
    getValue: readSlot,
    releaseHandle: releaseSlot,
    liveCount: () => (slots.length - 5 - free.length) >>> 0,
    isInHostCall: () => callDepth > 0,
    setWake(fn) { onWake = fn; },
    destroy() {
      destroyed = true;
      callDepth = 0;
      pendingRead = null;
      lastErrBytes = emptyBytes;
      slots.length = 5;
      gens.length = 5;
      free.length = 0;
      onWake = null;
    },
  };
}
