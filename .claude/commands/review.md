Review the current changes for code quality and safety issues. Launch parallel sub-agents to analyze the codebase:

1. **Concurrency Safety** — Verify the single-owner goroutine model: PlacementEngine state is never accessed from multiple goroutines, channels are properly buffered/unbuffered, no goroutine leaks on shutdown. Check that `tty.Writer` is the sole TTY writer. Flag any `sync.Mutex` usage outside the upload cache.

2. **Protocol Correctness** — Verify msgpack encoding/decoding round-trips, message framing correctness, proper error responses for malformed requests. Check client disconnect cleanup removes all placements and frees unreferenced images.

3. **Kitty Protocol Encoding** — Verify APC escape sequence formatting, base64 chunking at 4096 bytes, DCS passthrough wrapping for tmux, proper cursor positioning sequences. Compare against the kitty graphics protocol specification.

4. **Resource Management** — Check for file descriptor leaks (TTY fd, Unix socket listeners, client connections), proper cleanup on SIGTERM/SIGINT, upload cache eviction correctness, and graceful shutdown ordering (drain engine before closing TTY).

5. **Coordinate Resolution** — Verify pane-relative, nvim-window-relative, and absolute coordinate math. Check visibility calculations (off-screen detection, scroll-driven show/hide). Look for off-by-one errors in row/col arithmetic.

For each issue found, report:
- **File and line number**
- **Severity**: critical / warning / suggestion
- **Description** of the issue
- **Fix** recommendation

Summarize findings grouped by category with critical issues first.
