// Typed RPC client, event subscriptions, and Worker proxy for `src/web/rpc.zig`.
const textEncoder = new TextEncoder();
const RESERVED_PROPS = new Set(["then", "catch", "finally", "toJSON", "constructor", "prototype"]);

function toOnMethod(eventName) {
  let out = "on", upper = true;
  for (let i = 0; i < eventName.length; i++) {
    const ch = eventName[i];
    if (ch === "-" || ch === "_" || ch === ":" || ch === ".") {
      upper = true;
      continue;
    }
    out += upper ? ch.toUpperCase() : ch;
    upper = false;
  }
  return out;
}

function makeServiceProxy(svcName, callFn) {
  const methods = new Map();
  return new Proxy(Object.create(null), {
    get(_target, methodProp) {
      if (typeof methodProp !== "string" || RESERVED_PROPS.has(methodProp) || methodProp.startsWith("__")) {
        return undefined;
      }
      let fn = methods.get(methodProp);
      if (!fn) {
        const fullName = `${svcName}.${methodProp}`;
        fn = (...args) => callFn(fullName, ...args);
        methods.set(methodProp, fn);
      }
      return fn;
    },
  });
}

export function createRPC({ js, memory, exports, host }) {
  let currentHost = host;
  let destroyed = false;
  let attachedEmitter = false;
  let hostSynced = false;
  const listeners = new Map();
  const serviceCache = new Map();
  const eventHelperCache = new Map();

  function addListener(key, fn) {
    if (typeof fn !== "function") throw new TypeError("RPC event listener must be a function");
    let set = listeners.get(key);
    if (!set) {
      set = new Set();
      listeners.set(key, set);
    }
    set.add(fn);
    return () => {
      const cur = listeners.get(key);
      if (!cur) return;
      cur.delete(fn);
      if (cur.size === 0) listeners.delete(key);
    };
  }

  function on(event, fn) {
    return addListener(String(event), fn);
  }

  function once(event, fn) {
    if (typeof fn !== "function") throw new TypeError("RPC event listener must be a function");
    const off = on(event, payload => {
      off();
      fn(payload);
    });
    return off;
  }

  function emitFromZig(eventName, payload) {
    if (destroyed) return;
    const rawKey = String(eventName);
    const direct = listeners.get(rawKey);
    if (direct && direct.size > 0) {
      for (const fn of [...direct]) fn(payload);
    }
    const methodKey = toOnMethod(rawKey);
    if (methodKey !== rawKey) {
      const typed = listeners.get(methodKey);
      if (typed && typed.size > 0) {
        for (const fn of [...typed]) fn(payload);
      }
    }
  }

  function attach() {
    if (destroyed) return;
    const exp = exports?.();
    if (!exp) return;
    if (!attachedEmitter && typeof exp.nanoui_rpc_set_emitter === "function") {
      attachedEmitter = true;
      exp.nanoui_rpc_set_emitter(js.allocHandle(emitFromZig));
    }
    if (!hostSynced && currentHost !== undefined && typeof exp.nanoui_rpc_set_host === "function") {
      hostSynced = true;
      exp.nanoui_rpc_set_host(js.allocHandle(currentHost));
    }
  }

  function setHost(nextHost) {
    if (destroyed) return;
    currentHost = nextHost;
    const exp = exports?.();
    if (exp && typeof exp.nanoui_rpc_set_host === "function") {
      hostSynced = true;
      exp.nanoui_rpc_set_host(js.allocHandle(nextHost));
    } else {
      hostSynced = false;
    }
  }

  async function call(method, ...args) {
    const name = String(method);
    while (js.isInHostCall()) await Promise.resolve();
    if (destroyed) throw new Error(`${name}: RPC runtime is destroyed`);
    attach();
    const exp = exports?.();
    if (!exp || typeof exp.nanoui_rpc_call !== "function" || typeof exp.nanoui_rpc_scratch !== "function") {
      throw new Error(`${name}: No RPC services bound`);
    }
    const methodBytes = textEncoder.encode(name);
    const basePtr = exp.nanoui_rpc_scratch(methodBytes.byteLength) >>> 0;
    if (basePtr === 0) throw new Error(`${name}: OutOfMemory`);
    const methodPtr = basePtr + 4;
    if (methodBytes.byteLength > 0) {
      new Uint8Array(memory().buffer, methodPtr, methodBytes.byteLength).set(methodBytes);
    }
    const argsHandle = js.allocHandle(args);
    let retRaw;
    try {
      retRaw = exp.nanoui_rpc_call(methodPtr, methodBytes.byteLength, argsHandle, basePtr) >>> 0;
    } finally {
      js.releaseHandle(argsHandle);
    }
    const isErr = new DataView(memory().buffer).getUint32(basePtr, true);
    const val = js.getValue(retRaw);
    js.releaseHandle(retRaw);
    if (isErr !== 0) throw new Error(String(val));
    return val;
  }

  function destroy() {
    if (destroyed) return;
    destroyed = true;
    listeners.clear();
    serviceCache.clear();
    eventHelperCache.clear();
    currentHost = undefined;
    try { exports?.()?.nanoui_rpc_destroy?.(); } catch {}
  }

  const base = { call, on, once, setHost, attach, destroy };
  return new Proxy(base, {
    get(target, prop) {
      if (typeof prop !== "string") return undefined;
      if (Object.hasOwn(target, prop)) return target[prop];
      if (RESERVED_PROPS.has(prop) || prop.startsWith("__")) return undefined;
      if (prop === "toString" || prop === "valueOf") return Object.prototype[prop];
      if (prop.length > 2 && prop.startsWith("on") && prop[2] >= "A" && prop[2] <= "Z") {
        let helper = eventHelperCache.get(prop);
        if (!helper) {
          helper = listener => addListener(prop, listener);
          eventHelperCache.set(prop, helper);
        }
        return helper;
      }
      let svc = serviceCache.get(prop);
      if (!svc) {
        svc = makeServiceProxy(prop, call);
        serviceCache.set(prop, svc);
      }
      return svc;
    },
  });
}

export function createWorkerRPC(worker) {
  let nextId = 1, destroyed = false;
  const pending = new Map();
  const serviceCache = new Map();

  function onMessage(ev) {
    const reply = ev?.data?.rpcReply;
    if (!reply) return;
    const entry = pending.get(reply.id);
    if (!entry) return;
    pending.delete(reply.id);
    if (reply.ok) entry.resolve(reply.value);
    else entry.reject(new Error(reply.error ?? "Worker RPC error"));
  }
  worker.addEventListener("message", onMessage);

  function call(method, ...args) {
    if (destroyed) return Promise.reject(new Error(`${method}: Worker RPC client is destroyed`));
    const id = nextId++;
    const safeArgs = args.map(a => (a instanceof Uint8Array ? a.slice() : a));
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      try {
        worker.postMessage({ rpcCall: { id, method: String(method), args: safeArgs } });
      } catch (err) {
        pending.delete(id);
        reject(err);
      }
    });
  }

  function destroy() {
    if (destroyed) return;
    destroyed = true;
    worker.removeEventListener("message", onMessage);
    for (const entry of pending.values()) entry.reject(new Error("Worker RPC client destroyed"));
    pending.clear();
    serviceCache.clear();
  }

  const base = { call, destroy };
  return new Proxy(base, {
    get(target, prop) {
      if (typeof prop !== "string") return undefined;
      if (Object.hasOwn(target, prop)) return target[prop];
      if (RESERVED_PROPS.has(prop) || prop.startsWith("__")) return undefined;
      let svc = serviceCache.get(prop);
      if (!svc) {
        svc = makeServiceProxy(prop, call);
        serviceCache.set(prop, svc);
      }
      return svc;
    },
  });
}
