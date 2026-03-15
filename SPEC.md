# kgd — Kitty Graphics Daemon

A standalone daemon written in Go that owns all kitty graphics protocol output for a terminal
session, providing a unified, topology-aware placement service to any client (raw processes,
tmux, neovim plugins, molten, image.nvim, mupager, etc.).

## Problem Statement

Every application that uses the kitty graphics protocol today must independently solve:

- **Coordinate translation** — tmux pane offsets, neovim window offsets, absolute terminal coordinates
- **ID namespace management** — kitty image IDs are global per-terminal; multiple apps collide
- **Topology change handling** — tmux splits/resizes, nvim window moves all invalidate placements
- **Visibility tracking** — images scrolled off-screen must be deleted; images returning must be re-placed
- **Upload deduplication** — the same image data gets uploaded multiple times across clients
- **Atomic batching** — multi-image updates must reach the terminal as one write to avoid tearing

The result is that every app (Molten, image.nvim, mupager) reimplements this badly and independently.
The coordinate mismatch between kitty's absolute pixel placement and tmux's passthrough layer is
the root cause of most image rendering bugs in terminal tooling today.

**kgd inverts this.** Clients describe _intent_ ("show this image at this logical position").
kgd resolves intent to terminal coordinates continuously, handling all topology changes transparently.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        kgd daemon                               │
│                                                                 │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │  RPC server │  │ Topology     │  │  Placement engine      │ │
│  │  (Unix sock)│  │ tracker      │  │  - ID allocator        │ │
│  │             │  │ - tmux ctrl  │  │  - Upload cache (LRU)  │ │
│  │  clients:   │  │ - nvim wins  │  │  - Coordinate resolver │ │
│  │  - mupager  │  │ - SIGWINCH   │  │                        │ │
│  │  - molten   │  └──────────────┘  └────────────────────────┘ │
│  │  - image.nvim                           │                   │
│  │  - raw procs│                           ▼                   │
│  └─────────────┘                    ┌──────────────┐           │
│                                     │  Graphics    │           │
│                                     │  (interface) │           │
│                                     └──────┬───────┘           │
│                                            │                   │
│                              ┌─────────────┼──────────┐       │
│                              ▼             ▼          ▼       │
│                        ┌──────────┐ ┌──────────┐ ┌────────┐  │
│                        │ TTY      │ │ SHM/File │ │ Future:│  │
│                        │ (t=d)    │ │ (t=s/t=t)│ │ RC sock│  │
│                        │ APC seqs │ │ local    │ │        │  │
│                        └──────────┘ └──────────┘ └────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Graphics Transport

The kitty graphics protocol supports four transmission modes (`t=` parameter):

| Mode | Mechanism | Base64 overhead | Works over SSH |
|------|-----------|-----------------|----------------|
| `t=d` (direct) | Data inline in APC escape sequences | Yes (~33%) | Yes |
| `t=f` (file) | Terminal reads from local file path | No | No |
| `t=t` (temp file) | Same as file, terminal deletes after | No | No |
| `t=s` (shared memory) | Terminal reads from `shm_open()` object | No | No |

Only `t=d` works over SSH — the other three require the client and terminal to share
filesystem or memory. kgd selects the optimal mode at startup:

- **Local** (no `$SSH_TTY`): `t=s` (shared memory) preferred, `t=t` (temp file) fallback
- **Remote** (`$SSH_TTY` set): `t=d` (direct, chunked base64)

All placement and delete commands are small and always go through TTY escape sequences
regardless of mode.

### Graphics Interface

The placement engine communicates with the terminal through a `Graphics` interface,
decoupling the engine from any specific transport:

```go
type Graphics interface {
    Transmit(id uint32, data []byte, format string, width, height int) error
    Place(cmd PlaceCommand) error
    Delete(cmd DeleteCommand) error
}
```

Implementations:

- `TTYGraphics` — encodes kitty APC escape sequences, selects `t=d`/`t=t`/`t=s` based
  on environment detection at init
- Future: `RCGraphics` — if kitty extends the remote control protocol to support graphics
  commands, this backend would encode JSON and send over the `KITTY_LISTEN_ON` socket

### Kitty Remote Control Socket

When running under `kitten ssh` with `forward_remote_control yes`, the environment variable
`KITTY_LISTEN_ON` points to a reverse-forwarded Unix socket that speaks kitty's remote
control protocol (DCS-framed JSON). This socket supports `kitten @` commands for controlling
the local kitty instance (windows, tabs, colors, etc.) but **does not currently support
graphics protocol operations**.

kgd detects `KITTY_LISTEN_ON` and may use it for:
- Querying terminal state (`kitten @ ls`)
- Future graphics transport if kitty extends the protocol

The architecture is designed so that adding a remote control graphics backend requires only
a new `Graphics` implementation — no engine changes.

## Concurrency Model

Go's concurrency primitives map cleanly onto the daemon's structure:

```
main goroutine
  └── Graphics backend    # sole goroutine that writes to terminal
        ↑ chan             # all other goroutines send batched commands here

  ├── rpc.Server          # accepts Unix socket connections
  │     └── per-client goroutine (one per connected client)
  │           └── dispatches to PlacementEngine via channels

  ├── topology.TmuxWatcher   # tmux control mode connection (persistent)
  │     └── sends TopologyEvent to PlacementEngine

  └── PlacementEngine     # single goroutine, owns all placement state
        ├── receives: PlaceRequest, UnplaceRequest, ScrollUpdate,
        │             TopologyEvent, WinResized, ClientDisconnect
        └── sends: batched commands to Graphics backend
```

The `PlacementEngine` is the single owner of all mutable placement state — no locks needed,
all mutation happens in one goroutine, everything else communicates via channels.

## Operational Model

### Daemon Identity

One kgd instance per terminal (not per tmux session — two kitty windows attached to the same
tmux session are two different terminals with different pixel layouts). The daemon computes a
`session_key` at startup from the first available environment signal:

| Priority | Signal | Terminal | Scope |
|----------|--------|----------|-------|
| 1 | `$KITTY_WINDOW_ID` | kitty | One kitty OS window |
| 2 | `$WEZTERM_PANE` | wezterm | One wezterm pane |
| 3 | TTY device path (`tty` output) | universal | One PTY |

The socket path is derived from this key:

```
$XDG_RUNTIME_DIR/kgd-<session_key>.sock
```

TTY device path is the universal fallback — every terminal session has a unique PTY. Even
inside tmux, each attached client has its own PTY, so two terminals attached to the same tmux
session correctly get separate kgd instances.

### Lifecycle

Hybrid model: explicit shell integration is the recommended path, with auto-launch fallback
for programmatic clients.

#### Shell integration (recommended)

```bash
# .bashrc / .zshrc
eval "$(kgd init)"
```

`kgd init` starts the daemon if not already running for this terminal, sets `KGD_SOCKET`,
and prints the `export` statement. The daemon stays alive until the terminal closes (SIGHUP)
or idle timeout.

#### Auto-launch fallback

The Go client library (and CLI tool) can auto-launch kgd if `$KGD_SOCKET` is unset:

1. Compute the socket path from the identity key
2. Check if daemon is already running (connect attempt)
3. If not, fork+exec `kgd serve` as a background process
4. Connect to the new socket

This gives zero-config for programmatic clients while shell integration provides explicit
lifecycle control.

#### Shutdown

- kgd exits after a configurable idle timeout (default: 30s) when no clients are connected
- SIGHUP from the terminal triggers immediate cleanup and exit
- `kgd stop` sends a graceful shutdown signal via the socket

Graceful shutdown sequence:

1. Stop accepting new client connections
2. Send `kitty delete` for all active placements (leave terminal clean)
3. Notify connected clients of shutdown
4. Close all client connections
5. Remove the socket file
6. Exit

#### Crash Recovery

If kgd crashes, the socket file persists on disk. On startup, kgd checks for an existing
socket file at the computed path. If the socket exists but a connect attempt fails (no
process listening), kgd unlinks the stale socket and re-creates it. If a connect succeeds,
another instance is already running and kgd exits with an error.

### Environment Scenarios

kgd supports all combinations of nvim, tmux, SSH, and kitty. The axes are independent:

| Axis | Effect on kgd |
|------|---------------|
| **tmux: yes/no** | Determines whether kgd uses tmux control mode for topology |
| **nvim: yes/no** | Determines whether clients send window geometry updates |
| **SSH: yes/no** | Determines transmission mode (`t=d` vs `t=s`/`t=t`); transparent to engine |
| **kitty/wezterm/ghostty** | Determines environment detection for daemon identity and `t=` support |

SSH is transparent to the daemon — kgd runs on the remote side, writes escape sequences to
the PTY, and they flow back over SSH to the local terminal. The only SSH-specific behavior
is selecting `t=d` for image uploads.

### Topology Discovery

#### tmux — Control Mode

When `$TMUX` is set, kgd connects to tmux via **control mode** (`tmux -C`). This provides
a persistent event stream with zero user configuration:

```
%layout-change @0 ...
%window-add @1
%session-changed $0 ...
%exit
```

These notifications map directly to topology events. kgd does not require any tmux hooks —
it subscribes automatically via control mode on startup and cleans up on exit.

Events tracked:
- **Pane layout changed** — splits, resizes, pane moved
- **Window switched** — different window now visible
- **Window closed** — placements need cleanup
- **Terminal resize** — cascades to all pane geometries

#### neovim

nvim clients send geometry updates directly:
- `register_win` on connect and on `WinResized`/`WinScrolled`/`BufWinEnter`
- `update_scroll` on scroll
- `unregister_win` on window close

kgd does not poll nvim directly.

#### Terminal cell size

`TIOCGWINSZ` syscall on the TTY fd, refreshed on `SIGWINCH`.

### Terminal Color Detection

kgd queries the terminal's foreground and background colors at startup via **OSC 10/11**
escape sequences and exposes them to clients. This centralizes a difficult problem — every
app that displays images with transparency needs the terminal background color, and the
detection has numerous edge cases (tmux wrapping, SSH latency, stale caches).

#### Detection mechanism

1. **At startup**, kgd sends OSC 10 (foreground) and OSC 11 (background) queries to `/dev/tty`
2. When inside tmux, queries are wrapped in DCS passthrough (`\x1bPtmux;\x1b\x1b]11;?\x07\x1b\\`)
3. Response format: `rgb:RRRR/GGGG/BBBB` (16-bit per channel, take high byte)
4. Timeout: 200ms (accommodates SSH latency without hanging)

#### Live theme change detection

- **CSI 2031 (Mode 2031)**: kgd subscribes to dark/light mode change notifications via
  `CSI ? 2031 h`. Supported by kitty, ghostty, and contour. When the terminal theme changes,
  the terminal pushes a DSR notification — kgd re-queries OSC 10/11 and sends `theme_changed`
  to all connected clients.
- **SIGWINCH fallback**: tmux re-queries the outer terminal's colors on SIGWINCH. kgd
  re-queries OSC 10/11 on SIGWINCH as well, which catches theme changes during resize events.
- **Periodic re-query**: optional, low-frequency (every 30s) for environments where neither
  Mode 2031 nor SIGWINCH-triggered updates work.

#### What kgd exposes to clients

- Detected colors are included in the `hello` response (see `HelloResult`)
- `theme_changed` notifications are pushed when colors change
- Clients use the provided background color to pre-composite transparent images — kgd does
  not do compositing itself

#### The nudge problem

Kitty treats cells whose background color exactly matches the terminal's configured default
as transparent when `background_opacity < 1.0` ([kitty #7563](https://github.com/kovidgoyal/kitty/issues/7563)).
This causes images to bleed through text overlays. Clients that draw colored backgrounds
(e.g. overlay panels) should "nudge" colors that exactly match the terminal background by
±1 in a channel (e.g. blue). kgd provides the detected background color so clients can
perform this check.

### Z-Index Layering

Kitty's z-index system has three tiers:

| Z-Index Range | Behavior |
|---|---|
| `z >= 0` | Image above text (default `z=0`) |
| `z < 0` | Image below text, above cell backgrounds |
| `z < -1,073,741,824` (INT32_MIN/2) | Image below text AND cell backgrounds |

The default `ZIndex` for kgd placements is `-1,073,741,825` (one below the threshold),
which renders images beneath both text and cell background colors. This is correct for
most use cases (document viewers, inline images).

Known limitations:
- **Unicode placeholders cannot stack** — one image per cell, no layering via placeholders
- **Same z-index tie-breaking** — lower image ID renders behind higher; same ID is undefined
- **tmux is unaware of z-index** — it passes through escape sequences but cannot manage
  image layering during layout changes
- kgd manages z-ordering centrally and can enforce sane defaults while allowing per-placement
  overrides from clients

### Coordinate Resolution

For a placement anchored to `{pane_id, row, col}`:

```
term_row = pane_top  + row
term_col = pane_left + col
```

For a placement anchored to `{nvim_win, buf_line}` (requires prior `register_win`):

```
screen_row = win_top + (buf_line - scroll_top)
term_row   = pane_top + screen_row
term_col   = pane_left + win_left + col
```

Placements where `screen_row < 0` or `screen_row >= win_height` are invisible — kgd issues
a kitty delete if previously placed, and re-places when scrolled back into view.

## Protocol

### Transport

Unix domain socket using the standard **msgpack-RPC** wire format (same as neovim). msgpack
is chosen over JSON because it handles binary payloads (`[]byte` for image data) natively
without base64 encoding overhead.

#### msgpack-RPC Wire Format

Three message types, each a msgpack array:

```
Request:       [type=0, msgid, method, params]
Response:      [type=1, msgid, error, result]
Notification:  [type=2, method, params]
```

- `type` — 0=request, 1=response, 2=notification
- `msgid` — uint32, monotonically incrementing per-connection, correlates response to request
- `method` — string (e.g. "hello", "upload", "place")
- `params` — array of arguments (typically a single struct)
- `error` — nil on success, error string on failure
- `result` — response payload, nil on error

Requests (type=0) expect a Response (type=1) with matching msgid. Notifications (type=2) are
fire-and-forget in both directions. Clients can pipeline multiple requests without waiting for
responses — msgid handles correlation.

| Message | Type | Direction |
|---------|------|-----------|
| hello | Request(0) | client→daemon |
| upload | Request(0) | client→daemon |
| place | Request(0) | client→daemon |
| unplace | Notification(2) | client→daemon |
| unplace_all | Notification(2) | client→daemon |
| free | Notification(2) | client→daemon |
| register_win | Notification(2) | client→daemon |
| update_scroll | Notification(2) | client→daemon |
| unregister_win | Notification(2) | client→daemon |
| evicted | Notification(2) | daemon→client |
| topology_changed | Notification(2) | daemon→client |
| visibility_changed | Notification(2) | daemon→client |
| theme_changed | Notification(2) | daemon→client |

Use `github.com/vmihailenco/msgpack/v5` for encoding.

### Connection Modes

#### Stateful (persistent connection)

The primary mode. The client opens a socket connection and keeps it open for the lifetime
of its session. Benefits:

- **Bidirectional notifications** — daemon can push events to the client
- **Automatic cleanup** — on disconnect, all placements are removed and unreferenced images freed
- **Connection-scoped state** — handles and placement IDs are scoped to the connection

Used by: mupager, image.nvim, Molten, any long-running application.

#### Stateless (transient connection)

For CLI tools and scripts. The client connects, performs an operation, and disconnects.
State persists across connections via a client-provided `session_id`.

```go
type HelloParams struct {
    ClientType string // "nvim" | "raw" | "mupager" | "cli"
    PID        int
    Label      string
    SessionID  string // non-empty → stateless mode; state keyed by this ID
}
```

Session state (handles, placements) is preserved after disconnect and garbage collected via:
- Explicit `free` / `unplace` commands
- LRU cache eviction (natural)
- Configurable session idle timeout (default: 5 minutes)

Used by: `kgd` CLI tool, shell scripts, one-shot programs.

```bash
# CLI usage example
export KGD_SESSION="my-script-$$"
handle=$(kgd upload image.png)
kgd place "$handle" --row 0 --col 0
# ... later
kgd free "$handle"
```

### Message Types

#### Client → Daemon

##### `hello` — client handshake (request, sent on connect)

```go
type HelloParams struct {
    ClientType string // "nvim" | "raw" | "mupager" | "cli"
    PID        int
    Label      string
    SessionID  string // optional; non-empty enables stateless mode
}
type HelloResult struct {
    ClientID   string // assigned UUID (stateful) or echoed SessionID (stateless)
    Background Color  // detected terminal background color (from OSC 11)
    Foreground Color  // detected terminal foreground color (from OSC 10)
    CellWidth  int    // terminal cell width in pixels
    CellHeight int    // terminal cell height in pixels
    Cols       int    // terminal width in columns
    Rows       int    // terminal height in rows
    InTmux     bool   // whether the daemon is running inside tmux
}
type Color struct {
    R uint8
    G uint8
    B uint8
}
```

The `HelloResult` gives clients everything they need to render correctly from the first
frame: terminal background for pre-compositing transparent images, cell dimensions for
sizing, and topology context.

##### `upload` — transmit image data

```go
type UploadParams struct {
    Data   []byte // raw pixel data or PNG
    Format string // "png" | "rgb" | "rgba"
    Width  int
    Height int
}
type UploadResult struct {
    Handle uint32 // stable client-local handle
}
```

Image data is content-addressed (xxh3-128). If two clients upload identical data, kgd reuses
the same kitty image ID. The handle is client-local; kgd maps it to the global kitty image ID.

##### `place` — make an image visible at a logical position

```go
type PlaceParams struct {
    Handle  uint32
    Anchor  Anchor
    Width   int    // terminal cells
    Height  int    // terminal cells
    SrcX    int    // pixel crop (optional)
    SrcY    int
    SrcW    int
    SrcH    int
    ZIndex  int32  // default: -1073741825 (below text)
}
type PlaceResult struct {
    PlacementID uint32
}

type Anchor struct {
    Type    string // "pane" | "nvim_win" | "absolute"
    PaneID  string // tmux pane ID e.g. "%0"  (type: pane)
    WinID   int    //                          (type: nvim_win)
    BufLine int    // 0-based buffer line      (type: nvim_win)
    Row     int    // 0-based                  (type: pane | absolute)
    Col     int    // 0-based
}
```

##### `unplace` — remove a placement

```go
type UnplaceParams struct {
    PlacementID uint32
}
```

##### `unplace_all` — remove all placements for this client (notification)

##### `free` — release uploaded image data (notification)

```go
type FreeParams struct {
    Handle uint32
}
```

LRU eviction handles this automatically; explicit free is optional.

##### `register_win` — register a neovim window geometry (notification, nvim clients)

```go
type RegisterWinParams struct {
    WinID     int
    PaneID    string // tmux pane ID, or "" if not in tmux
    Top       int    // window top row within pane, 0-based
    Left      int    // window left col within pane, 0-based
    Width     int
    Height    int
    ScrollTop int    // first visible buffer line, 0-based
}
```

##### `update_scroll` — update scroll position (notification, nvim clients)

```go
type UpdateScrollParams struct {
    WinID     int
    ScrollTop int
}
```

kgd recomputes visibility and re-places/deletes images on receiving this.

##### `unregister_win` — (notification, nvim clients)

```go
type UnregisterWinParams struct {
    WinID int
}
```

#### Daemon → Client (notifications)

##### `evicted` — image was purged from the upload cache

```go
type EvictedParams struct {
    Handle uint32 // the client-local handle that was evicted
}
```

The client should re-upload if it still needs this image. If the image has active placements,
kgd will trigger a transparent re-upload on the next render cycle — but the client may want
to re-upload proactively to avoid a visible flicker.

##### `topology_changed` — pane/window geometry changed

```go
type TopologyChangedParams struct {
    PaneID string // affected pane, or "" for terminal-wide resize
    Width  int    // new width in cells
    Height int    // new height in cells
}
```

Clients may want to re-render images at a different resolution when geometry changes.

##### `visibility_changed` — placement visibility changed

```go
type VisibilityChangedParams struct {
    PlacementID uint32
    Visible     bool
}
```

Clients can use this for lazy loading — only upload/render images that are actually visible.

##### `theme_changed` — terminal foreground/background colors changed

```go
type ThemeChangedParams struct {
    Background Color // new terminal background color
    Foreground Color // new terminal foreground color
}
```

Sent when kgd detects a terminal theme change (via CSI 2031 subscription, SIGWINCH-triggered
re-query, or periodic OSC 10/11 polling). Clients with transparent images should re-composite
against the new background color and re-upload. Clients using auto dark/light detection should
re-evaluate their theme choice using the background luminance
(`0.2126*R + 0.7152*G + 0.0722*B < 128` → dark).

### Client Identification

**Stateful mode:** Each connection gets a UUID assigned at accept. All placements and handles
are scoped to that connection. On disconnect, all placements are cleaned up and all uploaded
images with no remaining references are freed.

**Stateless mode:** The client provides a `SessionID` in the `hello` message. State is keyed
by this ID and persists across connections. Garbage collection happens via LRU eviction or
a configurable idle timeout.

## Placement Engine

### Update Triggers

The `PlacementEngine` goroutine processes:

- `PlaceRequest` / `UnplaceRequest` from client goroutines
- `ScrollUpdate` from client goroutines (nvim mode)
- `TopologyEvent` from `TmuxWatcher` or `SIGWINCH` handler
- `ClientDisconnect` from client goroutines

On each event, the engine:

1. Updates its internal state (placements, window registry, pane topology)
2. Recomputes screen coordinates for all affected placements
3. Determines visibility for each placement
4. Diffs against the last-rendered state
5. Builds a single batched output buffer: deletions first, then placements in z-order
6. Sends the buffer to the `Graphics` backend

### Batching

All terminal output for one update cycle is collected into a single batch and sent as one
call to the `Graphics` backend. In tmux mode, cursor positioning and kitty APC sequences
are wrapped together in a single DCS passthrough block.

### Upload Flow

```
Client goroutine                    PlacementEngine goroutine         Graphics backend
      │                                      │                              │
      │  UploadRequest{data, format, w, h}   │                              │
      │─────────────────────────────────────>│                              │
      │                                      │                              │
      │                              hash = xxh3_128(data)                  │
      │                              cache.Lookup(hash)                     │
      │                              ┌── hit: reuse kitty_id               │
      │                              │   (skip transmit, no TTY write)     │
      │                              └── miss:                             │
      │                                   kitty_id = allocator.Next()      │
      │                                   cache.Store(hash, kitty_id)      │
      │                                   │  Transmit(kitty_id, data, ...) │
      │                                   │──────────────────────────────>│
      │                                   │                  write APC to │
      │                                   │                  /dev/tty     │
      │                              handle = register(client, kitty_id)   │
      │  UploadReply{handle}               │                              │
      │<─────────────────────────────────────│                              │
```

Key design points:

- **Hash in engine goroutine** — xxh3-128 is fast enough (~0.3ms for 10MB) to run in the
  engine without meaningful contention. Keeps the architecture simple: one goroutine owns
  all cache state including hashing. No need to pre-compute hashes in client goroutines.
- **Hash + data sent together** — no two-phase "check first, send on miss" protocol. Unix
  socket copy of redundant data is cheap (~μs for 10MB). Simplicity wins.
- **Cache hit skips transmit** — on hash match, engine returns existing handle immediately
  with no TTY write
- **Handle is client-scoped** — multiple clients can have different handles for the same
  underlying kitty image ID

### Upload Cache

```go
type UploadCache struct {
    byHash  map[[16]byte]uint32  // xxh3-128 → kitty image ID
    byID    map[uint32]*entry
    lru     list.List            // LRU eviction order
    maxSize int                  // max number of uploaded images
}
```

Content-addressed using xxh3-128 (`github.com/zeebo/xxh3`). xxHash is chosen over SHA256
because cryptographic collision resistance is unnecessary for content deduplication, and
xxh3 is ~10x faster (~30 GB/s vs ~3 GB/s).

Each cache entry tracks a reference count — the number of client handles pointing to it.
When multiple clients upload identical data, they each get a client-local handle but share
the same kitty image ID and cache entry. `kitty delete` is only issued when the reference
count drops to zero (all clients have freed or disconnected). LRU eviction only considers
entries with zero active placements.

On eviction, kgd issues `kitty delete (free=true, image_id=N)` and sends `evicted`
notifications to all clients holding handles to that image. If the evicted image has
active placements, those placements trigger a transparent re-upload on next render.

### Kitty Image ID Allocator

```go
type IDAllocator struct {
    next atomic.Uint32
}
```

Monotonically incrementing, wraps at `math.MaxUint32`. kgd is the sole allocator — no client
ever sees or picks a kitty image ID.

## Client Libraries

Client libraries provide idiomatic wrappers around the msgpack-RPC protocol, handling socket
connection, message framing, and bidirectional notification dispatch.

### Priority Order

| Language | Primary consumer | Approach |
|----------|-----------------|----------|
| **Go** | kgd CLI, mupager (future) | Native, ships in-repo as `pkg/kgdclient` |
| **Lua** | nvim plugins (image.nvim, Molten) | Native Lua, uses nvim's built-in msgpack |
| **C** | mupager, universal FFI base | Stable ABI, wrappable by any language |
| **Python** | Molten, Jupyter tooling | Native or ctypes wrapper around C lib |
| **Rust** | Third-party adopters | Native or C FFI wrapper |
| Others | Node.js, JVM, .NET, OCaml | C FFI wrappers |

The Go library ships first (it's needed for the kgd CLI). The C library provides the universal
escape hatch — every other language can bind to it via FFI.

### kgd CLI

The `kgd` binary doubles as the CLI client using the stateless connection mode:

```
kgd init                            # print shell eval snippet, start daemon if needed
kgd serve                           # start daemon (foreground)
kgd stop                            # graceful shutdown of running daemon
kgd upload <file>                   # upload image, print handle
kgd place <handle> [--row R --col C --anchor pane --pane %0]
kgd unplace <placement_id>
kgd list                            # list active placements
kgd status                          # daemon status, client count, cache stats
kgd diagnose                        # terminal info, tmux detection, socket path
```

The CLI uses `$KGD_SESSION` (or auto-generates a session ID) for stateless mode.

## Kitty Protocol Encoding

Port of mupager's `graphics/kitty.cpp` to Go. Approximately 200 lines covering:

```go
package kitty

type TransmitCommand struct { ... }
func (c TransmitCommand) Serialize(b64 string) string  // chunked APC, 4096-byte chunks

type PlaceCommand struct { ... }
func (c PlaceCommand) Serialize() string

type DeleteCommand struct { ... }
func (c DeleteCommand) Serialize() string

func WrapTmux(escape string) string       // DCS passthrough with doubled ESC bytes
func Placeholders(...) string             // unicode placeholder rows
func DeleteAllPlacements() string
```

The encoding is pure string formatting — no external dependencies beyond `encoding/base64`.

## Repository Structure

```
kgd/
├── cmd/
│   └── kgd/
│       └── main.go              # flag parsing, daemon start, CLI subcommands
├── pkg/
│   └── kgdclient/
│       └── client.go            # Go client library (public API)
├── internal/
│   ├── daemon/
│   │   └── daemon.go            # top-level wiring, goroutine launch
│   ├── rpc/
│   │   ├── server.go            # Unix socket accept loop
│   │   ├── client.go            # per-client state, handle→kitty ID map
│   │   └── dispatch.go          # method routing, param decode
│   ├── protocol/
│   │   └── types.go             # shared message types (used by rpc + engine)
│   ├── engine/
│   │   ├── engine.go            # PlacementEngine goroutine, event loop
│   │   ├── placement.go         # Placement type, coordinate resolution
│   │   └── events.go            # event types (PlaceRequest, ScrollUpdate, etc.)
│   ├── graphics/
│   │   ├── graphics.go          # Graphics interface definition
│   │   ├── tty.go               # TTYGraphics — APC escape sequences via TTY
│   │   └── tty_test.go
│   ├── topology/
│   │   ├── tmux.go              # tmux control mode connection, event parsing
│   │   └── win_registry.go      # registered nvim window state
│   ├── tty/
│   │   └── tty.go               # TTY open, TIOCGWINSZ, SIGWINCH
│   ├── upload/
│   │   └── cache.go             # content-addressed LRU upload cache
│   ├── kitty/
│   │   ├── kitty.go             # protocol encoding (ported from mupager)
│   │   └── kitty_test.go
│   └── allocator/
│       └── id.go                # kitty image ID allocator
├── nvim/                        # kgd.nvim submodule (thin Lua plugin)
├── go.mod
├── go.sum
├── flake.nix
├── justfile
└── CLAUDE.md
```

## Implementation Plan

### Phase 1 — Core daemon, raw mode

- [ ] Go module setup, flake.nix dev shell
- [ ] `internal/kitty` — port TransmitCommand, PlaceCommand, DeleteCommand, WrapTmux from mupager
- [ ] `internal/tty` — open `/dev/tty`, TIOCGWINSZ via `golang.org/x/sys/unix`, SIGWINCH handler
- [ ] OSC 10/11 color detection at startup (with tmux DCS wrapping, 200ms timeout)
- [ ] CSI 2031 subscription for push-based theme change notifications
- [ ] SIGWINCH-triggered color re-query fallback
- [ ] `internal/graphics` — Graphics interface, TTYGraphics with `t=d`/`t=t`/`t=s` selection
- [ ] `internal/rpc` — Unix socket server, per-client goroutine, msgpack framing
- [ ] Stateful and stateless connection modes
- [ ] Daemon→client notifications (evicted, topology_changed, visibility_changed)
- [ ] `internal/allocator` — kitty image ID allocator
- [ ] `internal/upload` — upload cache (no deduplication yet, just handle→ID map)
- [ ] `internal/engine` — PlacementEngine, absolute anchor only
- [ ] `place` / `unplace` / `unplace_all` / `free` commands
- [ ] Client disconnect cleanup (stateful) / session timeout reaper (stateless)
- [ ] Go client library (`pkg/kgdclient`)
- [ ] CLI subcommands: `upload`, `place`, `unplace`, `list`, `status`

### Phase 2 — Tmux mode

- [ ] `internal/topology/tmux.go` — tmux control mode connection (`tmux -C`)
- [ ] Parse control mode notifications (%layout-change, %window-add, etc.)
- [ ] Pane anchor coordinate resolution in engine
- [ ] `SIGWINCH` → TopologyEvent → full re-place
- [ ] Visibility suppression for hidden tmux windows
- [ ] Batched DCS passthrough writes (WrapTmux + atomic cursor+placement)

### Phase 3 — Nvim mode

- [ ] `register_win` / `update_scroll` / `unregister_win` handlers
- [ ] `internal/topology/win_registry.go`
- [ ] Buffer-line anchor coordinate resolution
- [ ] Scroll-driven visibility (place/delete as lines cross window bounds)
- [ ] kgd.nvim — thin Lua plugin (autocmds → socket notifications)

### Phase 4 — Polish

- [ ] Content-addressed deduplication (xxh3-128 in upload cache)
- [ ] Full LRU eviction with transparent re-upload + evicted notifications
- [ ] `KGD_SOCKET` propagation on daemon launch
- [ ] `kgd diagnose` — terminal info, tmux detection, socket status
- [ ] C client library (stable ABI, FFI-friendly)
- [ ] Python client library

### Phase 5 — kgd.nvim (full neovim integration library)

- [ ] High-level Lua library wrapping the kgd msgpack-RPC protocol
- [ ] Automatic buffer/window/scroll tracking via autocmds
- [ ] Declarative image API: "show this image at this buffer line" (library handles
      register_win, update_scroll, place/unplace lifecycle)
- [ ] Lazy loading: only upload images when they become visible
- [ ] Integration surface for image.nvim and Molten backends
- [ ] Documentation and example plugins

### Phase 6 — Ecosystem integration

- [ ] mupager integration (check `KGD_SOCKET`, fall back to direct TTY)
- [ ] image.nvim backend shim
- [ ] Molten backend shim
- [ ] Rust, Node.js, JVM client libraries (C FFI wrappers)

## Key Dependencies

```
golang.org/x/sys/unix                  # TIOCGWINSZ, Unix socket syscalls
github.com/vmihailenco/msgpack/v5      # msgpack encoding (same as neovim convention)
github.com/zeebo/xxh3                  # xxh3-128 for upload content addressing
```

No other external dependencies anticipated. The kitty encoding, tmux queries, and LRU cache
are all self-contained.

## Conventions

- Go 1.24+, `gofmt`, `go vet`
- Package layout: `cmd/` for binaries, `internal/` for all packages (nothing exported initially)
- Error handling: explicit `error` returns, no `panic` except truly unrecoverable init failures
- Concurrency: all mutable state owned by one goroutine, channels for communication — no `sync.Mutex`
- Tests: standard `testing` package, `*_test.go` files
- `just` for build/test/lint tasks (same pattern as mupager/clauded)

## Design Decisions

### Resolved

1. **Tmux topology discovery** — tmux control mode (`tmux -C`) instead of hooks. Zero user
   configuration, persistent event stream, richer event data. No `kgd notify` subprocess needed.

2. **Graphics transport abstraction** — `Graphics` interface decouples the placement engine
   from the terminal transport. Implementations select the optimal kitty transmission mode
   (`t=s` locally, `t=d` over SSH). If kitty extends the remote control protocol to support
   graphics commands in the future, a new `RCGraphics` implementation can be added without
   engine changes.

3. **No sidecar for image transfer** — kitty's `KITTY_LISTEN_ON` remote control socket
   supports `kitten @` commands but not graphics protocol operations. All image data flows
   through the TTY as APC escape sequences (or via shared memory/temp files locally).

4. **SSH is transparent** — kgd runs on the remote side, writes to the PTY, escape sequences
   flow back over SSH. The only SSH-aware behavior is selecting `t=d` for uploads.

5. **msgpack-RPC transport** — msgpack over JSON because image uploads contain binary payloads
   (`[]byte`) that would require base64 encoding in JSON. msgpack handles binary natively and
   is the same convention neovim uses, so the Lua/nvim ecosystem already has libraries.

6. **Bidirectional notifications** — the daemon pushes `evicted`, `topology_changed`, and
   `visibility_changed` notifications to clients. Fits naturally into msgpack-RPC which
   supports notifications in both directions over the same connection.

7. **Two connection modes** — stateful (persistent, auto-cleanup on disconnect) for long-running
   apps; stateless (transient, session-ID-keyed) for CLI tools and scripts. Stateless sessions
   are garbage collected via LRU eviction or configurable idle timeout.

8. **Client libraries** — Go native (ships in-repo), C with stable ABI (universal FFI base),
   then language-specific wrappers. Priority: Go → Lua → C → Python → others.

9. **Terminal color detection centralized in kgd** — kgd queries OSC 10/11 at startup and
   subscribes to CSI 2031 (Mode 2031) for push-based theme change notifications. Colors are
   exposed via `HelloResult` and `theme_changed` notifications. This avoids every client
   independently solving the tmux DCS wrapping, timeout handling, and stale cache problems.

10. **Z-index default below text and backgrounds** — kgd defaults placements to
    `z = -1,073,741,825` (one below kitty's `INT32_MIN/2` threshold), rendering images below
    both text and cell backgrounds. This is correct for document viewers and inline images.
    Clients can override per-placement via `PlaceParams.ZIndex`.

11. **Daemon identity key** — per-terminal, not per-tmux-session. Priority: `$KITTY_WINDOW_ID`
    → `$WEZTERM_PANE` → TTY device path (universal fallback). Two terminals attached to the
    same tmux session correctly get separate kgd instances because they have different PTYs.

12. **Hybrid daemon lifecycle** — shell integration (`eval "$(kgd init)"`) is recommended for
    explicit lifecycle control and `$KGD_SOCKET` propagation. Client libraries auto-launch kgd
    as fallback when `$KGD_SOCKET` is unset (compute socket path, check, fork+exec if needed).

13. **xxh3-128 content addressing** — xxHash for upload deduplication instead of SHA256.
    ~10x faster (~30 GB/s vs ~3 GB/s), cryptographic collision resistance is unnecessary.
    Hash computed in the engine goroutine — fast enough at ~0.3ms/10MB to keep things simple.

14. **Standard msgpack-RPC framing** — full msgpack-RPC wire format (`[type, msgid, method, params]`)
    rather than a bespoke envelope. Matches neovim's convention, enables async pipelining via
    msgid correlation, well-specified with no ambiguity.

### Open

1. **mupager migration** — mupager checks `KGD_SOCKET` at startup, connects as a kgd client if
   available, falls back to direct TTY ownership if not. Keeps mupager usable standalone.

2. **image.nvim / Molten integration** — both are third-party plugins. A compatibility shim that
   maps kgd's protocol onto image.nvim's existing backend API would minimize the integration
   surface and avoid requiring upstream changes initially.

## Stretch Goals

### Animation / Video Support

The kitty graphics protocol supports animation natively:

- **`a=f`** (frame) — transmit individual frames to an existing image
- **`a=a`** (animate) — start/stop/loop playback, set per-frame timing
- **`a=c`** (compose) — blend rectangular regions between frames (efficient delta updates)

kgd would expose this via new protocol messages:

```go
type UploadFrameParams struct {
    Handle  uint32 // target image
    Frame   int    // frame number
    Data    []byte // pixel data for this frame (or sub-region)
    Format  string
    X       int    // offset within image (for partial frame updates)
    Y       int
    Width   int
    Height  int
}

type AnimateParams struct {
    Handle  uint32
    State   string // "play" | "stop" | "load"
    Loops   int    // 0=current, 1=infinite, N=loop N times
}
```

The client is responsible for decoding video frames and computing deltas. kgd's role is
transport and coordination — it passes frame data and animation commands through the
`Graphics` interface, handles visibility (stop/start animation when scrolled off/on screen),
and batches frame updates with other placement commands.

### Viewporting

Already supported via the existing `PlaceParams.SrcX/SrcY/SrcW/SrcH` fields. The client
uploads a large image once, then creates placements with different source rectangles and
display sizes. Kitty handles the scaling. Example: upload a 1000x1000 bitmap, display the
region {0, 0, 100, 100} scaled up to 50x50 terminal cells. Multiple viewports of the same
image share the same upload — no duplicate data.

## Non-Goals

1. **Frame delta computation in kgd** — kgd does not diff frames or compute pixel-level
   deltas. The client has domain knowledge (video decoder knows which macroblocks changed,
   PDF renderer knows which region was dirtied) and is responsible for sending only the
   changed pixels. kgd is a coordination and transport layer, not a rendering engine.

2. **Image format conversion** — kgd passes image data through as-is. Clients must provide
   data in a format kitty understands (PNG, RGB, RGBA). No transcoding, resizing, or
   format detection in the daemon.
