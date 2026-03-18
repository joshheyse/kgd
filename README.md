# kgd

User-space daemon for kitty graphics protocol — unified image placement across tmux panes, neovim windows, and raw terminals.

## What it does

kgd sits between your applications and the terminal, managing all [kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) output for a session. Clients describe *where* they want images ("row 5, col 10 of tmux pane %3"), and kgd continuously resolves those positions to absolute terminal coordinates — even as panes resize, windows scroll, or splits change.

- **Topology-aware**: Automatically re-renders when tmux splits resize, neovim windows scroll, or the terminal gets a SIGWINCH
- **Content-addressed uploads**: SHA256 deduplication across clients — upload once, place many times
- **ID namespace isolation**: Clients get local handles; kgd maps to global kitty image IDs
- **Batch writes**: All output for one update cycle is sent as a single TTY write to avoid tearing
- **Multi-client**: Any number of applications can place images simultaneously through the same daemon

## Installation

### From source

Requires Go 1.25+:

```bash
go install github.com/joshheyse/kgd/cmd/kgd@latest
```

### With Nix

```bash
nix run github:joshheyse/kgd
```

## Quick start

```bash
# Start the daemon (or use kgd init for shell integration)
eval "$(kgd init)"

# Upload an image
handle=$(kgd upload photo.png)

# Place it at row 5, col 10
placement=$(kgd place "$handle" --row 5 --col 10 --width 20 --height 15)

# Remove it
kgd unplace "$placement"
```

## CLI

| Command | Description |
|---------|-------------|
| `kgd serve` | Start the daemon |
| `kgd init` | Start daemon if needed, print `export KGD_SOCKET=...` |
| `kgd upload <file>` | Upload an image, print the handle |
| `kgd place <handle>` | Place an image (`--row`, `--col`, `--width`, `--height`) |
| `kgd unplace <id>` | Remove a placement |
| `kgd list` | List active placements |
| `kgd status` | Show daemon status |
| `kgd stop` | Stop the daemon |
| `kgd clear` | Delete all kitty graphics from the terminal |
| `kgd diagnose` | Print terminal detection info |

## Client libraries

kgd provides native client libraries for 11 languages, all communicating over the same Unix socket with msgpack-RPC:

| Language | Location | Notes |
|----------|----------|-------|
| Go | `pkg/kgdclient/` | In-repo, shares protocol types |
| Python | `clients/python/` | Reference implementation |
| C | `clients/c/` | FFI-friendly, mpack-based |
| Rust | `clients/rust/` | Tokio async + sync wrapper |
| TypeScript | `clients/nodejs/` | Node.js, EventEmitter-based |
| Lua | `clients/lua/` | Standalone, luasocket + MessagePack |
| Zig | `clients/zig/` | Hand-rolled msgpack, zero-alloc decode |
| Swift | `clients/swift/` | Structured concurrency with actors |
| Kotlin | `clients/jvm/` | Coroutines + blocking wrapper |
| C# | `clients/dotnet/` | async/await |
| OCaml | `clients/ocaml/` | Threads + hand-rolled msgpack |

### Example (Python)

```python
from kgdclient import Client

client = Client(client_type="myapp")
handle = client.upload(image_data, format="png", width=100, height=80)
pid = client.place(handle, anchor={"type": "absolute", "row": 5, "col": 10}, width=20, height=15)
client.unplace(pid)
client.free(handle)
client.close()
```

## Neovim plugin

The `nvim/` directory contains **kgd.nvim**, a Lua plugin that tracks window geometry and scroll positions, enabling image placements anchored to buffer lines.

## Architecture

```
main goroutine
  ├── tty.Writer            sole goroutine that writes to /dev/tty
  ├── rpc.Server            accepts Unix socket connections
  │     └── per-client goroutine → dispatches via channels
  ├── topology.TmuxWatcher  polls tmux layout changes
  └── PlacementEngine       single goroutine, owns all placement state
        └── sends batched TTY writes to tty.Writer
```

**Key invariants:**
- Only `tty.Writer` writes to the TTY — no races, no tearing
- `PlacementEngine` owns all mutable placement state — no locks needed
- All goroutines communicate via channels (exception: upload cache uses `sync.RWMutex`)

## Protocol

- **Transport**: Unix domain socket at `$XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock`
- **Encoding**: [msgpack-RPC](https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md)
- **Discovery**: Clients read `$KGD_SOCKET` environment variable

## Development

Requires [Nix](https://nixos.org/) (recommended) or Go 1.25+, and [just](https://github.com/casey/just):

```bash
just build          # Build the binary
just test           # Run all Go tests
just vet            # go vet
just check          # build + vet + test
just fmt            # Format Go code
just clients-check  # Run all client library tests
```

## License

[MIT](LICENSE)
