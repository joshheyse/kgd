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
│  │             │  │ - tmux panes │  │  - Upload cache (LRU)  │ │
│  │  clients:   │  │ - nvim wins  │  │  - Coordinate resolver │ │
│  │  - mupager  │  │ - visibility │  │  - Batch TTY writer    │ │
│  │  - molten   │  └──────────────┘  └────────────────────────┘ │
│  │  - image.nvim                                               │
│  │  - raw procs│                                               │
│  └─────────────┘                                               │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────┐                                               │
│  │  TTY owner  │ ← sole writer to /dev/tty                     │
│  └─────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
```

## Concurrency Model

Go's concurrency primitives map cleanly onto the daemon's structure:

```
main goroutine
  └── tty.Writer          # sole goroutine that writes to /dev/tty
        ↑ chan []byte      # all other goroutines send batched writes here

  ├── rpc.Server          # accepts Unix socket connections
  │     └── per-client goroutine (one per connected client)
  │           └── dispatches to PlacementEngine via channels

  ├── topology.TmuxWatcher   # polls/subscribes to tmux layout changes
  │     └── sends TopologyEvent to PlacementEngine

  └── PlacementEngine     # single goroutine, owns all placement state
        ├── receives: PlaceRequest, UnplaceRequest, ScrollUpdate,
        │             TopologyEvent, WinResized, ClientDisconnect
        └── sends: batched TTY writes to tty.Writer
```

The `PlacementEngine` is the single owner of all mutable placement state — no locks needed,
all mutation happens in one goroutine, everything else communicates via channels.

## Operational Model

### Lifecycle

- One `kgd` instance per terminal session (kitty window or wezterm window)
- Launched on demand by the first client, or as a session service
- Socket path: `$XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock` (or tmux-session-keyed if inside tmux)
- Clients discover the socket via the `KGD_SOCKET` environment variable, set by kgd on launch
  and inherited by child processes
- kgd exits when the last client disconnects (or after a configurable idle timeout)

### Topology Discovery

kgd polls or subscribes to topology changes:

- **tmux** — `tmux display-message -p '#{pane_id} #{pane_top} #{pane_left} #{pane_width} #{pane_height}'`
  for all panes; subscribes to layout changes via `tmux set-hook` pointing back to kgd's
  notification endpoint (a lightweight sub-command: `kgd notify --event layout-changed`)
- **neovim** — clients send `win_info` on connect and on `WinResized`/`WinScrolled`/`BufWinEnter`;
  kgd does not poll nvim directly
- **Terminal cell size** — `TIOCGWINSZ` syscall on the TTY fd, refreshed on `SIGWINCH`

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

Unix domain socket, msgpack-encoded messages. Request/response for commands that return values,
fire-and-forget notifications for events (msgpack-RPC convention, same as nvim/clauded).

Use `github.com/vmihailenco/msgpack/v5` for encoding.

### Message Types

#### `hello` — client handshake (notification, sent on connect)

```go
type HelloParams struct {
    ClientType string // "nvim" | "raw" | "mupager"
    PID        int
    Label      string
}
```

#### `upload` — transmit image data

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

Image data is content-addressed (SHA256). If two clients upload identical data, kgd reuses
the same kitty image ID. The handle is client-local; kgd maps it to the global kitty image ID.

#### `place` — make an image visible at a logical position

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

#### `unplace` — remove a placement

```go
type UnplaceParams struct {
    PlacementID uint32
}
```

#### `unplace_all` — remove all placements for this client (notification)

#### `free` — release uploaded image data (notification)

```go
type FreeParams struct {
    Handle uint32
}
```

LRU eviction handles this automatically; explicit free is optional.

#### `register_win` — register a neovim window geometry (notification, nvim clients)

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

#### `update_scroll` — update scroll position (notification, nvim clients)

```go
type UpdateScrollParams struct {
    WinID     int
    ScrollTop int
}
```

kgd recomputes visibility and re-places/deletes images on receiving this.

#### `unregister_win` — (notification, nvim clients)

```go
type UnregisterWinParams struct {
    WinID int
}
```

### Client Identification

Each connection gets a UUID assigned at accept. All placements and handles are scoped to that
connection. On disconnect, all placements are cleaned up and all uploaded images with no
remaining references are freed.

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
6. Sends the buffer to `tty.Writer` via channel

### Batching

All TTY output for one update cycle is collected into a single `[]byte` and sent as one
message to the TTY writer goroutine, which calls `tty.Write` once. In tmux mode, cursor
positioning and kitty APC sequences are wrapped together in a single DCS passthrough block.

### Upload Cache

```go
type UploadCache struct {
    byHash  map[[32]byte]uint32  // SHA256 → kitty image ID
    byID    map[uint32]*entry
    lru     list.List            // LRU eviction order
    maxSize int                  // max number of uploaded images
}
```

On eviction, kgd issues `kitty delete (free=true, image_id=N)`. If the evicted image has
active placements, those placements trigger a transparent re-upload on next render.

### Kitty Image ID Allocator

```go
type IDAllocator struct {
    next atomic.Uint32
}
```

Monotonically incrementing, wraps at `math.MaxUint32`. kgd is the sole allocator — no client
ever sees or picks a kitty image ID.

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
│       └── main.go              # flag parsing, daemon start, notify subcommand
├── internal/
│   ├── daemon/
│   │   └── daemon.go            # top-level wiring, goroutine launch
│   ├── rpc/
│   │   ├── server.go            # Unix socket accept loop
│   │   ├── client.go            # per-client state, handle→kitty ID map
│   │   └── dispatch.go          # method routing, param decode
│   ├── engine/
│   │   ├── engine.go            # PlacementEngine goroutine, event loop
│   │   ├── placement.go         # Placement type, coordinate resolution
│   │   └── events.go            # event types (PlaceRequest, ScrollUpdate, etc.)
│   ├── topology/
│   │   ├── tmux.go              # pane position queries, hook subscription
│   │   └── win_registry.go      # registered nvim window state
│   ├── tty/
│   │   └── tty.go               # TTY open, TIOCGWINSZ, sole Write goroutine
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
- [ ] `internal/tty` — open `/dev/tty`, TIOCGWINSZ via `golang.org/x/sys/unix`, writer goroutine
- [ ] `internal/rpc` — Unix socket server, per-client goroutine, msgpack framing
- [ ] `internal/allocator` — kitty image ID allocator
- [ ] `internal/upload` — upload cache (no deduplication yet, just handle→ID map)
- [ ] `internal/engine` — PlacementEngine, absolute anchor only
- [ ] `place` / `unplace` / `unplace_all` / `free` commands
- [ ] Client disconnect cleanup

### Phase 2 — Tmux mode

- [ ] `internal/topology/tmux.go` — pane position via `exec.Command("tmux", ...)`
- [ ] Pane anchor coordinate resolution in engine
- [ ] tmux hook subscription (`kgd notify` subcommand as hook target)
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

- [ ] Content-addressed deduplication (SHA256 in upload cache)
- [ ] Full LRU eviction with transparent re-upload
- [ ] `KGD_SOCKET` propagation on daemon launch
- [ ] `kgd diagnose` — terminal info, tmux detection, socket status
- [ ] mupager integration (check `KGD_SOCKET`, fall back to direct TTY)
- [ ] image.nvim backend shim
- [ ] Molten backend shim

## Key Dependencies

```
golang.org/x/sys/unix                  # TIOCGWINSZ, Unix socket syscalls
github.com/vmihailenco/msgpack/v5      # msgpack encoding (same as clauded)
```

No other external dependencies anticipated. The kitty encoding, tmux queries, and LRU cache
are all self-contained.

## Conventions

- Go 1.22+, `gofmt`, `golangci-lint`
- Package layout: `cmd/` for binaries, `internal/` for all packages (nothing exported initially)
- Error handling: explicit `error` returns, no `panic` except truly unrecoverable init failures
- Concurrency: all mutable state owned by one goroutine, channels for communication — no `sync.Mutex`
  except in the upload cache (accessed from multiple client goroutines before hitting the engine)
- Tests: standard `testing` package, `*_test.go` files
- `just` for build/test/lint tasks (same pattern as mupager/clauded)

## Open Questions

1. **tmux hook → daemon notification** — tmux hooks fire shell commands. The cleanest path is
   a `kgd notify --event layout-changed` subcommand that connects to the daemon socket and sends
   a notification. Needs to be fast (< 5ms) since it fires on every pane operation.

2. **Multi-terminal support** — one daemon per `$KITTY_WINDOW_ID`. If `KITTY_WINDOW_ID` is unset
   (wezterm, ghostty), fall back to `$TERM_SESSION_ID` or a hash of the TTY device.

3. **mupager migration** — mupager checks `KGD_SOCKET` at startup, connects as a kgd client if
   available, falls back to direct TTY ownership if not. Keeps mupager usable standalone.

4. **image.nvim / Molten integration** — both are third-party plugins. A compatibility shim that
   maps kgd's protocol onto image.nvim's existing backend API would minimize the integration
   surface and avoid requiring upstream changes initially.
