/**
 * Node.js/TypeScript client library for kgd (Kitty Graphics Daemon).
 *
 * Provides a Promise-based API over Unix domain sockets using the
 * msgpack-RPC protocol. Supports all 12 RPC methods and 4 server
 * notification types.
 *
 * @example
 * ```ts
 * import { Client } from "@kgd/client";
 *
 * const client = await Client.connect({ clientType: "myapp" });
 * const handle = await client.upload(imageData, "png", 800, 600);
 * const pid = await client.place(handle, { type: "absolute", row: 5, col: 10 }, 20, 15);
 * await client.unplace(pid);
 * await client.free(handle);
 * client.close();
 * ```
 *
 * @module
 */

import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import {
  type DecodedMessage,
  type ResponseMessage,
  type NotificationMessage,
  MSG_RESPONSE,
  MSG_NOTIFICATION,
  METHOD_HELLO,
  METHOD_UPLOAD,
  METHOD_PLACE,
  METHOD_UNPLACE,
  METHOD_UNPLACE_ALL,
  METHOD_FREE,
  METHOD_REGISTER_WIN,
  METHOD_UPDATE_SCROLL,
  METHOD_UNREGISTER_WIN,
  METHOD_LIST,
  METHOD_STATUS,
  METHOD_STOP,
  NOTIFY_EVICTED,
  NOTIFY_TOPOLOGY_CHANGED,
  NOTIFY_VISIBILITY_CHANGED,
  NOTIFY_THEME_CHANGED,
  encodeRequest,
  encodeNotification,
  messageStream,
} from "./protocol.js";

// Re-export protocol constants for advanced users.
export {
  MSG_REQUEST,
  MSG_RESPONSE,
  MSG_NOTIFICATION,
  METHOD_HELLO,
  METHOD_UPLOAD,
  METHOD_PLACE,
  METHOD_UNPLACE,
  METHOD_UNPLACE_ALL,
  METHOD_FREE,
  METHOD_REGISTER_WIN,
  METHOD_UPDATE_SCROLL,
  METHOD_UNREGISTER_WIN,
  METHOD_LIST,
  METHOD_STATUS,
  METHOD_STOP,
  NOTIFY_EVICTED,
  NOTIFY_TOPOLOGY_CHANGED,
  NOTIFY_VISIBILITY_CHANGED,
  NOTIFY_THEME_CHANGED,
  encodeRequest,
  encodeNotification,
  messageStream,
  parseMessage,
} from "./protocol.js";

export type { DecodedMessage, ResponseMessage, NotificationMessage } from "./protocol.js";

// ---------------------------------------------------------------------------
// Error classes
// ---------------------------------------------------------------------------

/** Base error class for all kgd client errors. */
export class KgdError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "KgdError";
  }
}

/** Error returned by the daemon in an RPC response. */
export class RpcError extends KgdError {
  constructor(message: string) {
    super(message);
    this.name = "RpcError";
  }
}

/** Thrown when an RPC call exceeds the configured timeout. */
export class TimeoutError extends KgdError {
  constructor(message: string) {
    super(message);
    this.name = "TimeoutError";
  }
}

/** Thrown when the socket connection fails or is lost. */
export class ConnectionError extends KgdError {
  constructor(message: string) {
    super(message);
    this.name = "ConnectionError";
  }
}

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/** RGB color with 16-bit per channel precision. */
export interface Color {
  /** Red channel (0-65535). */
  r: number;
  /** Green channel (0-65535). */
  g: number;
  /** Blue channel (0-65535). */
  b: number;
}

/**
 * Describes a logical position for a placement.
 *
 * The `type` field determines which other fields are relevant:
 * - `"absolute"`: `row` and `col` are terminal-absolute coordinates.
 * - `"pane"`: `paneId`, `row`, `col` are relative to a tmux pane.
 * - `"nvim_win"`: `winId`, `bufLine`, `col` identify a neovim window position.
 */
export interface Anchor {
  /** Anchor type: "absolute", "pane", or "nvim_win". */
  type: string;
  /** Tmux pane identifier (e.g., "%0"). Only for type "pane". */
  paneId?: string;
  /** Neovim window ID. Only for type "nvim_win". */
  winId?: number;
  /** Buffer line number in neovim. Only for type "nvim_win". */
  bufLine?: number;
  /** Row offset within the anchor context. */
  row?: number;
  /** Column offset within the anchor context. */
  col?: number;
}

/** Describes a single active placement returned by {@link Client.list}. */
export interface PlacementInfo {
  /** Unique placement identifier. */
  placementId: number;
  /** UUID of the owning client. */
  clientId: string;
  /** Upload handle this placement references. */
  handle: number;
  /** Whether the placement is currently visible on screen. */
  visible: boolean;
  /** Resolved absolute row. */
  row: number;
  /** Resolved absolute column. */
  col: number;
}

/** Daemon status information returned by {@link Client.status}. */
export interface StatusResult {
  /** Number of connected clients. */
  clients: number;
  /** Total active placements. */
  placements: number;
  /** Total uploaded images in cache. */
  images: number;
  /** Terminal column count. */
  cols: number;
  /** Terminal row count. */
  rows: number;
}

/** Options for connecting to the kgd daemon. */
export interface Options {
  /** Explicit Unix socket path. Overrides environment variables. */
  socketPath?: string;
  /** Session identifier for grouping clients. */
  sessionId?: string;
  /** Client type identifier (e.g., "myapp", "nvim"). */
  clientType?: string;
  /** Human-readable label for this client. */
  label?: string;
  /** Whether to auto-launch the daemon if not running. Defaults to true. */
  autoLaunch?: boolean;
  /** Timeout in milliseconds for auto-launch waiting. Defaults to 5000. */
  launchTimeout?: number;
}

/** Options for placing an image. */
export interface PlaceOpts {
  /** Upload handle returned by {@link Client.upload}. */
  handle: number;
  /** Logical position for the placement. */
  anchor: Anchor;
  /** Display width in terminal cells. */
  width: number;
  /** Display height in terminal cells. */
  height: number;
  /** Source crop X offset in pixels. */
  srcX?: number;
  /** Source crop Y offset in pixels. */
  srcY?: number;
  /** Source crop width in pixels. */
  srcW?: number;
  /** Source crop height in pixels. */
  srcH?: number;
  /** Z-index for stacking order. */
  zIndex?: number;
}

/** Result from a successful {@link Client.hello} call. */
export interface HelloResult {
  /** UUID assigned to this client by the daemon. */
  clientId: string;
  /** Terminal column count. */
  cols: number;
  /** Terminal row count. */
  rows: number;
  /** Width of a single cell in pixels. */
  cellWidth: number;
  /** Height of a single cell in pixels. */
  cellHeight: number;
  /** Whether the terminal is inside a tmux session. */
  inTmux: boolean;
  /** Terminal foreground color. */
  fg: Color;
  /** Terminal background color. */
  bg: Color;
}

// ---------------------------------------------------------------------------
// Notification event types
// ---------------------------------------------------------------------------

/** Event map for the {@link Client} EventEmitter. */
export interface ClientEvents {
  /** Emitted when the daemon evicts an image from its cache. */
  evicted: [handle: number];
  /** Emitted when the terminal topology changes (resize, tmux split). */
  topology_changed: [cols: number, rows: number, cellWidth: number, cellHeight: number];
  /** Emitted when a placement's visibility changes. */
  visibility_changed: [placementId: number, visible: boolean];
  /** Emitted when the terminal's theme colors change. */
  theme_changed: [fg: Color, bg: Color];
  /** Emitted when the connection is closed. */
  close: [];
  /** Emitted on connection errors. */
  error: [error: Error];
}

// ---------------------------------------------------------------------------
// Helper: Anchor serialization
// ---------------------------------------------------------------------------

/**
 * Serialize an {@link Anchor} to the wire format, omitting zero-valued fields.
 */
function serializeAnchor(anchor: Anchor): Record<string, unknown> {
  const d: Record<string, unknown> = { type: anchor.type };
  if (anchor.paneId) d["pane_id"] = anchor.paneId;
  if (anchor.winId) d["win_id"] = anchor.winId;
  if (anchor.bufLine) d["buf_line"] = anchor.bufLine;
  if (anchor.row) d["row"] = anchor.row;
  if (anchor.col) d["col"] = anchor.col;
  return d;
}

/**
 * Parse a Color from a raw msgpack dict, defaulting to zero.
 */
function parseColor(raw: unknown): Color {
  if (typeof raw === "object" && raw !== null) {
    const obj = raw as Record<string, unknown>;
    return {
      r: typeof obj["r"] === "number" ? obj["r"] : 0,
      g: typeof obj["g"] === "number" ? obj["g"] : 0,
      b: typeof obj["b"] === "number" ? obj["b"] : 0,
    };
  }
  return { r: 0, g: 0, b: 0 };
}

// ---------------------------------------------------------------------------
// Socket path resolution
// ---------------------------------------------------------------------------

/**
 * Resolve the daemon socket path.
 *
 * Resolution order:
 * 1. Explicit `socketPath` option
 * 2. `$KGD_SOCKET` environment variable
 * 3. `$XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock`
 * 4. `/tmp/kgd-default.sock`
 */
function resolveSocketPath(socketPath?: string): string {
  if (socketPath) return socketPath;

  const envSocket = process.env["KGD_SOCKET"];
  if (envSocket) return envSocket;

  const runtimeDir = process.env["XDG_RUNTIME_DIR"] || tmpdir();
  const kittyId = process.env["KITTY_WINDOW_ID"] || "default";
  return join(runtimeDir, `kgd-${kittyId}.sock`);
}

// ---------------------------------------------------------------------------
// Daemon auto-launch
// ---------------------------------------------------------------------------

/**
 * Ensure the kgd daemon is listening at the given socket path.
 *
 * First tries to connect. If that fails, spawns `kgd serve --socket <path>`
 * as a detached background process and polls until the socket is accepting
 * connections or the timeout is reached.
 */
async function ensureDaemon(socketPath: string, timeoutMs: number): Promise<void> {
  // Try connecting to see if daemon is already running.
  const alive = await probeSocket(socketPath);
  if (alive) return;

  // Spawn the daemon.
  const child = spawn("kgd", ["serve", "--socket", socketPath], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();

  // Poll until the socket is accepting connections.
  const deadline = Date.now() + timeoutMs;
  const pollInterval = 100;
  while (Date.now() < deadline) {
    await sleep(pollInterval);
    const ready = await probeSocket(socketPath);
    if (ready) return;
  }

  throw new TimeoutError("timed out waiting for kgd daemon to start");
}

/**
 * Attempt a quick connect/disconnect to check if a Unix socket is listening.
 */
function probeSocket(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const sock = net.createConnection({ path: socketPath }, () => {
      sock.destroy();
      resolve(true);
    });
    sock.on("error", () => {
      sock.destroy();
      resolve(false);
    });
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Pending request tracking
// ---------------------------------------------------------------------------

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/**
 * Connection to the kgd (Kitty Graphics Daemon).
 *
 * The client communicates over a Unix domain socket using the msgpack-RPC
 * protocol. All RPC methods return Promises. Server notifications are
 * delivered through the EventEmitter interface.
 *
 * Use the static {@link Client.connect} method to create a connected,
 * authenticated instance.
 *
 * @example
 * ```ts
 * const client = await Client.connect({ clientType: "myapp" });
 *
 * client.on("topology_changed", (cols, rows, cw, ch) => {
 *   console.log(`Terminal resized to ${cols}x${rows}`);
 * });
 *
 * const handle = await client.upload(pngData, "png", 800, 600);
 * const pid = await client.place(handle, { type: "absolute", row: 0, col: 0 }, 40, 20);
 *
 * client.close();
 * ```
 */
export class Client extends EventEmitter<ClientEvents> {
  private readonly socket: net.Socket;
  private nextId = 0;
  private readonly pending = new Map<number, PendingRequest>();
  private closed = false;
  private readerAbort: AbortController | null = null;

  /** Default timeout for RPC calls in milliseconds. */
  public timeout = 10_000;

  // Hello result fields, populated after connect().

  /** UUID assigned to this client by the daemon. */
  public clientId = "";
  /** Terminal column count. */
  public cols = 0;
  /** Terminal row count. */
  public rows = 0;
  /** Width of a single cell in pixels. */
  public cellWidth = 0;
  /** Height of a single cell in pixels. */
  public cellHeight = 0;
  /** Whether the terminal is inside a tmux session. */
  public inTmux = false;
  /** Terminal foreground color. */
  public fg: Color = { r: 0, g: 0, b: 0 };
  /** Terminal background color. */
  public bg: Color = { r: 0, g: 0, b: 0 };

  /**
   * Create a Client wrapping an already-connected socket.
   *
   * Prefer {@link Client.connect} which handles socket creation, daemon
   * auto-launch, and the hello handshake.
   */
  constructor(socket: net.Socket) {
    super();
    this.socket = socket;

    this.socket.on("error", (err: Error) => {
      this.emit("error", new ConnectionError(err.message));
    });

    this.socket.on("close", () => {
      this.handleClose();
    });
  }

  /**
   * Connect to the kgd daemon and perform the hello handshake.
   *
   * @param opts - Connection and client identification options.
   * @returns A connected, authenticated Client instance.
   *
   * @throws {ConnectionError} If the socket connection fails.
   * @throws {TimeoutError} If auto-launch or the hello handshake times out.
   * @throws {RpcError} If the daemon rejects the hello.
   */
  static async connect(opts: Options = {}): Promise<Client> {
    const socketPath = resolveSocketPath(opts.socketPath);
    const autoLaunch = opts.autoLaunch !== false;
    const launchTimeout = opts.launchTimeout ?? 5000;

    if (autoLaunch) {
      await ensureDaemon(socketPath, launchTimeout);
    }

    const socket = await new Promise<net.Socket>((resolve, reject) => {
      const sock = net.createConnection({ path: socketPath }, () => {
        resolve(sock);
      });
      sock.on("error", (err: Error) => {
        reject(new ConnectionError(`failed to connect to ${socketPath}: ${err.message}`));
      });
    });

    const client = new Client(socket);
    client.startReader();

    // Perform hello handshake.
    const helloParams: Record<string, unknown> = {
      client_type: opts.clientType ?? "",
      pid: process.pid,
      label: opts.label ?? "",
    };
    if (opts.sessionId) {
      helloParams["session_id"] = opts.sessionId;
    }

    const result = await client.call(METHOD_HELLO, helloParams);
    if (typeof result === "object" && result !== null) {
      const r = result as Record<string, unknown>;
      client.clientId = (r["client_id"] as string) ?? "";
      client.cols = (r["cols"] as number) ?? 0;
      client.rows = (r["rows"] as number) ?? 0;
      client.cellWidth = (r["cell_width"] as number) ?? 0;
      client.cellHeight = (r["cell_height"] as number) ?? 0;
      client.inTmux = (r["in_tmux"] as boolean) ?? false;
      client.fg = parseColor(r["fg"]);
      client.bg = parseColor(r["bg"]);
    }

    return client;
  }

  // -----------------------------------------------------------------------
  // RPC methods (request/response)
  // -----------------------------------------------------------------------

  /**
   * Upload image data to the daemon.
   *
   * @param data - Raw image bytes.
   * @param format - Image format: "png", "rgb", or "rgba".
   * @param width - Image width in pixels.
   * @param height - Image height in pixels.
   * @returns An opaque handle for use with {@link place} and {@link free}.
   *
   * @throws {RpcError} If the upload is rejected by the daemon.
   * @throws {TimeoutError} If the call exceeds the configured timeout.
   */
  async upload(data: Uint8Array, format: string, width: number, height: number): Promise<number> {
    const result = await this.call(METHOD_UPLOAD, {
      data,
      format,
      width,
      height,
    });
    if (typeof result === "object" && result !== null) {
      return ((result as Record<string, unknown>)["handle"] as number) ?? 0;
    }
    throw new RpcError(`unexpected upload result: ${JSON.stringify(result)}`);
  }

  /**
   * Place an image at a logical position on screen.
   *
   * @param handle - Upload handle from {@link upload}.
   * @param anchor - Logical position descriptor.
   * @param width - Display width in terminal cells.
   * @param height - Display height in terminal cells.
   * @param opts - Optional source crop and z-index parameters.
   * @returns A placement ID for use with {@link unplace}.
   *
   * @throws {RpcError} If the placement is rejected by the daemon.
   * @throws {TimeoutError} If the call exceeds the configured timeout.
   */
  async place(
    handle: number,
    anchor: Anchor,
    width: number,
    height: number,
    opts?: { srcX?: number; srcY?: number; srcW?: number; srcH?: number; zIndex?: number },
  ): Promise<number> {
    const params: Record<string, unknown> = {
      handle,
      anchor: serializeAnchor(anchor),
      width,
      height,
    };
    if (opts?.srcX) params["src_x"] = opts.srcX;
    if (opts?.srcY) params["src_y"] = opts.srcY;
    if (opts?.srcW) params["src_w"] = opts.srcW;
    if (opts?.srcH) params["src_h"] = opts.srcH;
    if (opts?.zIndex) params["z_index"] = opts.zIndex;

    const result = await this.call(METHOD_PLACE, params);
    if (typeof result === "object" && result !== null) {
      return ((result as Record<string, unknown>)["placement_id"] as number) ?? 0;
    }
    throw new RpcError(`unexpected place result: ${JSON.stringify(result)}`);
  }

  /**
   * Place an image using a single options object.
   *
   * This is an alternative to the positional-argument {@link place} method.
   *
   * @param opts - All placement parameters.
   * @returns A placement ID for use with {@link unplace}.
   */
  async placeOpts(opts: PlaceOpts): Promise<number> {
    return this.place(opts.handle, opts.anchor, opts.width, opts.height, {
      srcX: opts.srcX,
      srcY: opts.srcY,
      srcW: opts.srcW,
      srcH: opts.srcH,
      zIndex: opts.zIndex,
    });
  }

  /**
   * Remove a placement by ID.
   *
   * @param placementId - The ID returned by {@link place}.
   */
  async unplace(placementId: number): Promise<void> {
    await this.call(METHOD_UNPLACE, { placement_id: placementId });
  }

  /**
   * Release an uploaded image handle.
   *
   * All placements referencing this handle are removed automatically.
   *
   * @param handle - The handle returned by {@link upload}.
   */
  async free(handle: number): Promise<void> {
    await this.call(METHOD_FREE, { handle });
  }

  /**
   * List all active placements.
   *
   * @returns Array of placement descriptors.
   */
  async list(): Promise<PlacementInfo[]> {
    const result = await this.call(METHOD_LIST, null);
    if (typeof result === "object" && result !== null) {
      const r = result as Record<string, unknown>;
      const raw = r["placements"];
      if (Array.isArray(raw)) {
        return raw.map((p: unknown) => {
          const obj = p as Record<string, unknown>;
          return {
            placementId: (obj["placement_id"] as number) ?? 0,
            clientId: (obj["client_id"] as string) ?? "",
            handle: (obj["handle"] as number) ?? 0,
            visible: (obj["visible"] as boolean) ?? false,
            row: (obj["row"] as number) ?? 0,
            col: (obj["col"] as number) ?? 0,
          };
        });
      }
    }
    return [];
  }

  /**
   * Query daemon status information.
   *
   * @returns Status counters and terminal dimensions.
   */
  async status(): Promise<StatusResult> {
    const result = await this.call(METHOD_STATUS, null);
    if (typeof result === "object" && result !== null) {
      const r = result as Record<string, unknown>;
      return {
        clients: (r["clients"] as number) ?? 0,
        placements: (r["placements"] as number) ?? 0,
        images: (r["images"] as number) ?? 0,
        cols: (r["cols"] as number) ?? 0,
        rows: (r["rows"] as number) ?? 0,
      };
    }
    return { clients: 0, placements: 0, images: 0, cols: 0, rows: 0 };
  }

  // -----------------------------------------------------------------------
  // RPC methods (notifications — fire and forget)
  // -----------------------------------------------------------------------

  /**
   * Remove all placements for this client.
   *
   * This is a fire-and-forget notification; it does not wait for a response.
   */
  unplaceAll(): void {
    this.notify(METHOD_UNPLACE_ALL, null);
  }

  /**
   * Register a neovim window geometry for anchor resolution.
   *
   * @param winId - Neovim window ID.
   * @param paneId - Tmux pane containing the window.
   * @param top - Window top row within the pane.
   * @param left - Window left column within the pane.
   * @param width - Window width in cells.
   * @param height - Window height in cells.
   * @param scrollTop - Current scroll position (first visible buffer line).
   */
  registerWin(
    winId: number,
    paneId = "",
    top = 0,
    left = 0,
    width = 0,
    height = 0,
    scrollTop = 0,
  ): void {
    this.notify(METHOD_REGISTER_WIN, {
      win_id: winId,
      pane_id: paneId,
      top,
      left,
      width,
      height,
      scroll_top: scrollTop,
    });
  }

  /**
   * Update the scroll position for a previously registered neovim window.
   *
   * @param winId - Neovim window ID.
   * @param scrollTop - New first visible buffer line.
   */
  updateScroll(winId: number, scrollTop: number): void {
    this.notify(METHOD_UPDATE_SCROLL, {
      win_id: winId,
      scroll_top: scrollTop,
    });
  }

  /**
   * Unregister a neovim window.
   *
   * @param winId - Neovim window ID to remove.
   */
  unregisterWin(winId: number): void {
    this.notify(METHOD_UNREGISTER_WIN, { win_id: winId });
  }

  /**
   * Request the daemon to shut down gracefully.
   */
  stop(): void {
    this.notify(METHOD_STOP, null);
  }

  /**
   * Close the connection to the daemon.
   *
   * Rejects all pending RPC calls with a {@link ConnectionError}.
   */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.readerAbort?.abort();
    this.socket.destroy();
    this.rejectAllPending(new ConnectionError("connection closed"));
    this.emit("close");
  }

  // -----------------------------------------------------------------------
  // Low-level transport
  // -----------------------------------------------------------------------

  /**
   * Send an RPC request and wait for the matching response.
   *
   * @param method - RPC method name.
   * @param params - Parameter dict, or null.
   * @param timeout - Override the default timeout in milliseconds.
   * @returns The result field from the response.
   *
   * @throws {RpcError} If the response contains an error.
   * @throws {TimeoutError} If no response arrives within the timeout.
   * @throws {ConnectionError} If the connection is lost before a response.
   */
  call(method: string, params: Record<string, unknown> | null, timeout?: number): Promise<unknown> {
    if (this.closed) {
      return Promise.reject(new ConnectionError("connection closed"));
    }

    const msgid = this.nextId++;
    const data = encodeRequest(msgid, method, params);

    return new Promise<unknown>((resolve, reject) => {
      const timeoutMs = timeout ?? this.timeout;
      const timer = setTimeout(() => {
        this.pending.delete(msgid);
        reject(new TimeoutError(`RPC call "${method}" timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      this.pending.set(msgid, { resolve, reject, timer });

      this.socket.write(data, (err) => {
        if (err) {
          clearTimeout(timer);
          this.pending.delete(msgid);
          reject(new ConnectionError(`write failed: ${err.message}`));
        }
      });
    });
  }

  /**
   * Send a fire-and-forget notification.
   *
   * @param method - Notification method name.
   * @param params - Parameter dict, or null.
   */
  notify(method: string, params: Record<string, unknown> | null): void {
    if (this.closed) return;
    const data = encodeNotification(method, params);
    this.socket.write(data);
  }

  // -----------------------------------------------------------------------
  // Internal reader
  // -----------------------------------------------------------------------

  /** Start the background reader that processes incoming messages. */
  private startReader(): void {
    this.readerAbort = new AbortController();
    const signal = this.readerAbort.signal;

    // Use an async IIFE that consumes the socket as an async iterable.
    void (async () => {
      try {
        for await (const msg of messageStream(this.socket)) {
          if (signal.aborted) break;
          this.dispatchMessage(msg);
        }
      } catch (err: unknown) {
        if (signal.aborted) return;
        const message = err instanceof Error ? err.message : String(err);
        this.emit("error", new ConnectionError(`reader error: ${message}`));
      } finally {
        if (!this.closed) {
          this.handleClose();
        }
      }
    })();
  }

  /** Route a decoded message to the appropriate handler. */
  private dispatchMessage(msg: DecodedMessage): void {
    if (msg.type === MSG_RESPONSE) {
      this.handleResponse(msg);
    } else if (msg.type === MSG_NOTIFICATION) {
      this.handleNotification(msg);
    }
  }

  /** Resolve or reject the pending Promise for a response. */
  private handleResponse(msg: ResponseMessage): void {
    const pending = this.pending.get(msg.msgid);
    if (!pending) return;

    clearTimeout(pending.timer);
    this.pending.delete(msg.msgid);

    if (msg.error !== null && msg.error !== undefined) {
      let errorMsg: string;
      if (typeof msg.error === "object" && msg.error !== null && "message" in msg.error) {
        errorMsg = String((msg.error as Record<string, unknown>)["message"]);
      } else {
        errorMsg = `RPC error: ${JSON.stringify(msg.error)}`;
      }
      pending.reject(new RpcError(errorMsg));
    } else {
      pending.resolve(msg.result);
    }
  }

  /** Emit typed events for server notifications. */
  private handleNotification(msg: NotificationMessage): void {
    const p = msg.params;

    switch (msg.method) {
      case NOTIFY_EVICTED:
        this.emit("evicted", (p["handle"] as number) ?? 0);
        break;
      case NOTIFY_TOPOLOGY_CHANGED:
        this.emit(
          "topology_changed",
          (p["cols"] as number) ?? 0,
          (p["rows"] as number) ?? 0,
          (p["cell_width"] as number) ?? 0,
          (p["cell_height"] as number) ?? 0,
        );
        break;
      case NOTIFY_VISIBILITY_CHANGED:
        this.emit(
          "visibility_changed",
          (p["placement_id"] as number) ?? 0,
          (p["visible"] as boolean) ?? false,
        );
        break;
      case NOTIFY_THEME_CHANGED:
        this.emit("theme_changed", parseColor(p["fg"]), parseColor(p["bg"]));
        break;
    }
  }

  /** Clean up on connection close. */
  private handleClose(): void {
    if (this.closed) return;
    this.closed = true;
    this.rejectAllPending(new ConnectionError("connection closed"));
    this.emit("close");
  }

  /** Reject all pending RPC calls. */
  private rejectAllPending(error: Error): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
      this.pending.delete(id);
    }
  }
}
