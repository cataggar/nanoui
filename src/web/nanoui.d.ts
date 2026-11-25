// TypeScript declarations for nanoui's browser runtime (`nanoui.js`, `js.js`, `rpc.js`).

export type CanvasTextureFormat = "bgra8unorm" | "rgba8unorm" | "rgba16float" | (string & {});

export type DefaultServices = Record<
  string,
  Record<string, (...args: unknown[]) => Promise<unknown>>
>;

export interface JSBridge {
  readonly imports: WebAssembly.ModuleImports;
  formatError(err: unknown): string;
  allocHandle(value: unknown): number;
  getValue(handle: number): unknown;
  releaseHandle(handle: number): void;
  liveCount(): number;
  isInHostCall(): boolean;
  setWake(fn: (() => void) | null): void;
  destroy(): void;
}

export type RpcClient<
  Services = DefaultServices,
  Events = Record<string, never>,
  Host = unknown,
> = Services &
  Events & {
    call(method: string, ...args: unknown[]): Promise<unknown>;
    on(event: string, listener: (payload: unknown) => void): () => void;
    once(event: string, listener: (payload: unknown) => void): () => void;
    setHost(host: Host | undefined): void;
    destroy(): void;
  };

export type WorkerRpcClient<Services = DefaultServices> = Services & {
  call(method: string, ...args: unknown[]): Promise<unknown>;
  destroy(): void;
};

export interface LoadOptions<Host = Record<string, unknown>> {
  url: string | URL;
  baseUrl?: string | URL;
  imageConcurrency?: number;
  imageFetch?: (url: string, init: RequestInit) => Promise<Response>;
  gpu?: "auto" | "webgpu" | "webgl2";
  canvas?: HTMLCanvasElement | OffscreenCanvas;
  device?: unknown;
  format?: CanvasTextureFormat;
  imports?: WebAssembly.Imports;
  asyncPipelines?: boolean;
  host?: Host;
}

export interface StartOptions<Host = Record<string, unknown>> extends LoadOptions<Host> {
  canvas: HTMLCanvasElement | OffscreenCanvas;
  width?: number;
  height?: number;
  scale?: number;
  ime?: "auto" | "editcontext" | "textarea";
  requestAnimationFrame?: (callback: FrameRequestCallback) => number;
  cancelAnimationFrame?: (handle: number) => void;
  onDeviceLost?: (info: unknown) => void;
  onError?: (error: unknown) => void;
}

export interface WebRuntime<
  Services = DefaultServices,
  Host = Record<string, unknown>,
  Events = Record<string, never>,
> {
  backend: "webgpu" | "webgl2";
  instance: WebAssembly.Instance;
  exports: WebAssembly.Exports;
  readonly memory: WebAssembly.Memory;
  readonly device: unknown;
  gpu: unknown;
  js: JSBridge;
  rpc: RpcClient<Services, Events, Host>;
  host?: unknown;
  setDevice?: (device: unknown) => Promise<void>;
  requestFrame?: () => void;
  destroy(): void;
}

export function load<
  Services = DefaultServices,
  Host = Record<string, unknown>,
  Events = Record<string, never>,
>(options: LoadOptions<Host>): Promise<WebRuntime<Services, Host, Events>>;

export function start<
  Services = DefaultServices,
  Host = Record<string, unknown>,
  Events = Record<string, never>,
>(options: StartOptions<Host>): Promise<WebRuntime<Services, Host, Events>>;

export function createWorkerRPC<Services = DefaultServices>(
  worker: Worker,
): WorkerRpcClient<Services>;
