# kgd — Kitty Graphics Daemon

User-space daemon that owns all kitty graphics protocol output for a terminal session, providing a unified, topology-aware placement service to any client (mupager, molten, image.nvim, raw processes).

**Repo**: `~/code/kgd`
**Language**: Go 1.24+
**Binary**: Single `kgd` binary via cobra CLI

## Quick Reference

### Build & Test
```bash
just build               # go build ./cmd/kgd
just test                # go test ./...
just vet                 # go vet ./...
just check               # build + vet + test
just fmt                 # gofmt -w .
just fmt-check           # verify formatting
just clients-check       # run all client library tests
```

## Project Structure
```
cmd/kgd/main.go              # Entry point → cli.Execute()
internal/
  cli/                        # Cobra subcommands (serve, notify)
  daemon/                     # Top-level wiring, goroutine launch
  rpc/                        # Unix socket server, per-client state, dispatch
  engine/                     # PlacementEngine goroutine, event loop, coord resolution
  topology/                   # Tmux pane tracking, nvim window registry
  tty/                        # TTY open, TIOCGWINSZ, sole writer goroutine
  upload/                     # Content-addressed LRU upload cache
  kitty/                      # Kitty graphics protocol encoding
  allocator/                  # Kitty image ID allocator
  logging/                    # slog setup (file + stderr)
pkg/kgdclient/               # Go client library
clients/
  c/                          # C client (FFI-friendly, mpack-based)
  python/                     # Python client (reference implementation)
  rust/                       # Rust client (tokio async + sync wrapper)
  nodejs/                     # Node.js/TypeScript client
  lua/                        # Lua standalone client (luasocket + lua-MessagePack)
  zig/                        # Zig client (hand-rolled msgpack)
  swift/                      # Swift client (structured concurrency)
  jvm/                        # Kotlin/JVM client (coroutines)
  dotnet/                     # C#/.NET client (async/await)
  ocaml/                      # OCaml client (threads + hand-rolled msgpack)
nvim/                         # kgd.nvim Neovim plugin (Lua)
```

## Architecture

- **Single writer**: Only `tty.Writer` goroutine writes to `/dev/tty`
- **Single owner**: `PlacementEngine` goroutine owns all mutable placement state — no locks
- **Channels everywhere**: All goroutines communicate via channels, not mutexes
- **Exception**: Upload cache uses `sync.RWMutex` (accessed from multiple client goroutines)

### Concurrency Model
```
main goroutine
  └── tty.Writer            # sole goroutine that writes to /dev/tty
        ↑ chan []byte

  ├── rpc.Server            # accepts Unix socket connections
  │     └── per-client goroutine → dispatches via channels

  ├── topology.TmuxWatcher  # polls/subscribes to tmux layout changes
  │     └── sends TopologyEvent to PlacementEngine

  └── PlacementEngine       # single goroutine, owns all placement state
        └── sends batched TTY writes to tty.Writer
```

### Protocol
- Transport: Unix domain socket, msgpack-encoded messages
- Library: `github.com/vmihailenco/msgpack/v5`
- Socket: `$XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock`
- Client discovery: `KGD_SOCKET` environment variable

## Key Design Decisions

1. **Coordinate resolution**: Clients describe intent ("show image at pane row/col"), kgd resolves to absolute terminal coordinates continuously
2. **ID namespace isolation**: Clients get local handles; kgd maps to global kitty image IDs
3. **Content-addressed uploads**: SHA256 deduplication across clients
4. **Topology-driven re-rendering**: tmux splits, nvim scrolls, and SIGWINCH all trigger automatic re-placement
5. **Batch TTY writes**: All output for one update cycle sent as single write to avoid tearing

## Go Dependencies

- `github.com/spf13/cobra` — CLI framework
- `github.com/vmihailenco/msgpack/v5` — msgpack encoding (same convention as nvim/clauded)
- `golang.org/x/sys/unix` — TIOCGWINSZ, Unix socket syscalls

## Style & Conventions

- Standard Go project layout (`cmd/`, `internal/`)
- `log/slog` for all logging — CLI commands are silent, daemon logs to file + stderr
- Errors wrapped with context: `fmt.Errorf("doing X: %w", err)`
- No `panic` except truly unrecoverable init failures
- Concurrency: channel-based, single-owner goroutines — no `sync.Mutex` except upload cache
- Tests in `_test.go` files alongside source, table-driven style
- `just` for task running, not `make`
- Nix flake for dev shell and packaging
