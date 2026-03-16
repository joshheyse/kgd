"""kgd client implementation using msgpack-RPC over Unix sockets."""

from __future__ import annotations

import os
import socket
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import msgpack


# msgpack-rpc message types
_MSG_REQUEST = 0
_MSG_RESPONSE = 1
_MSG_NOTIFICATION = 2

# RPC method names
METHOD_HELLO = "hello"
METHOD_UPLOAD = "upload"
METHOD_PLACE = "place"
METHOD_UNPLACE = "unplace"
METHOD_UNPLACE_ALL = "unplace_all"
METHOD_FREE = "free"
METHOD_REGISTER_WIN = "register_win"
METHOD_UPDATE_SCROLL = "update_scroll"
METHOD_UNREGISTER_WIN = "unregister_win"
METHOD_LIST = "list"
METHOD_STATUS = "status"
METHOD_STOP = "stop"

# Notification names
NOTIFY_EVICTED = "evicted"
NOTIFY_TOPOLOGY_CHANGED = "topology_changed"
NOTIFY_VISIBILITY_CHANGED = "visibility_changed"
NOTIFY_THEME_CHANGED = "theme_changed"


@dataclass
class Color:
    """RGB color with 16-bit per channel precision."""
    r: int = 0
    g: int = 0
    b: int = 0


@dataclass
class Anchor:
    """Describes a logical position for a placement."""
    type: str = "absolute"
    pane_id: str = ""
    win_id: int = 0
    buf_line: int = 0
    row: int = 0
    col: int = 0

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"type": self.type}
        if self.pane_id:
            d["pane_id"] = self.pane_id
        if self.win_id:
            d["win_id"] = self.win_id
        if self.buf_line:
            d["buf_line"] = self.buf_line
        if self.row:
            d["row"] = self.row
        if self.col:
            d["col"] = self.col
        return d


@dataclass
class PlacementInfo:
    """Describes a single active placement."""
    placement_id: int = 0
    client_id: str = ""
    handle: int = 0
    visible: bool = False
    row: int = 0
    col: int = 0


@dataclass
class StatusResult:
    """Daemon status information."""
    clients: int = 0
    placements: int = 0
    images: int = 0
    cols: int = 0
    rows: int = 0


@dataclass
class Options:
    """Options for connecting to the kgd daemon."""
    socket_path: str = ""
    session_id: str = ""
    client_type: str = ""
    label: str = ""
    auto_launch: bool = True


class Client:
    """Connection to the kgd daemon.

    Usage::

        client = Client.connect(Options(client_type="myapp"))
        handle = client.upload(image_data, "png", width, height)
        pid = client.place(handle, Anchor(type="absolute", row=5, col=10), 20, 15)
        client.unplace(pid)
        client.free(handle)
        client.close()
    """

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._packer = msgpack.Packer(use_bin_type=True)
        self._unpacker = msgpack.Unpacker(raw=False)
        self._lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._next_id = 0
        self._pending: dict[int, threading.Event] = {}
        self._results: dict[int, tuple[Any, Any]] = {}
        self._done = threading.Event()
        self._reader_thread: threading.Thread | None = None

        # Hello result
        self.client_id: str = ""
        self.cols: int = 0
        self.rows: int = 0
        self.cell_width: int = 0
        self.cell_height: int = 0
        self.in_tmux: bool = False
        self.fg: Color = Color()
        self.bg: Color = Color()

        # Notification callbacks
        self.on_evicted: Callable[[int], None] | None = None
        self.on_topology_changed: Callable[[int, int, int, int], None] | None = None
        self.on_visibility_changed: Callable[[int, bool], None] | None = None
        self.on_theme_changed: Callable[[Color, Color], None] | None = None

    @classmethod
    def connect(cls, opts: Options | None = None) -> Client:
        """Connect to the kgd daemon."""
        if opts is None:
            opts = Options()

        socket_path = opts.socket_path or os.environ.get("KGD_SOCKET", "") or _default_socket_path()

        if opts.auto_launch:
            _ensure_daemon(socket_path)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(socket_path)

        client = cls(sock)
        client._reader_thread = threading.Thread(target=client._read_loop, daemon=True)
        client._reader_thread.start()

        # Send hello
        hello_params = {
            "client_type": opts.client_type,
            "pid": os.getpid(),
            "label": opts.label,
        }
        if opts.session_id:
            hello_params["session_id"] = opts.session_id

        result = client._call(METHOD_HELLO, hello_params)
        if isinstance(result, dict):
            client.client_id = result.get("client_id", "")
            client.cols = result.get("cols", 0)
            client.rows = result.get("rows", 0)
            client.cell_width = result.get("cell_width", 0)
            client.cell_height = result.get("cell_height", 0)
            client.in_tmux = result.get("in_tmux", False)
            if "fg" in result and isinstance(result["fg"], dict):
                client.fg = Color(**{k: result["fg"].get(k, 0) for k in ("r", "g", "b")})
            if "bg" in result and isinstance(result["bg"], dict):
                client.bg = Color(**{k: result["bg"].get(k, 0) for k in ("r", "g", "b")})

        return client

    def upload(self, data: bytes, fmt: str, width: int, height: int) -> int:
        """Upload image data and return a handle."""
        result = self._call(METHOD_UPLOAD, {
            "data": data,
            "format": fmt,
            "width": width,
            "height": height,
        })
        if isinstance(result, dict):
            return result.get("handle", 0)
        raise RuntimeError(f"unexpected upload result: {result}")

    def place(self, handle: int, anchor: Anchor, width: int, height: int,
              src_x: int = 0, src_y: int = 0, src_w: int = 0, src_h: int = 0,
              z_index: int = 0) -> int:
        """Place an image and return a placement ID."""
        params: dict[str, Any] = {
            "handle": handle,
            "anchor": anchor.to_dict(),
            "width": width,
            "height": height,
        }
        if src_x:
            params["src_x"] = src_x
        if src_y:
            params["src_y"] = src_y
        if src_w:
            params["src_w"] = src_w
        if src_h:
            params["src_h"] = src_h
        if z_index:
            params["z_index"] = z_index

        result = self._call(METHOD_PLACE, params)
        if isinstance(result, dict):
            return result.get("placement_id", 0)
        raise RuntimeError(f"unexpected place result: {result}")

    def unplace(self, placement_id: int) -> None:
        """Remove a placement."""
        self._call(METHOD_UNPLACE, {"placement_id": placement_id})

    def unplace_all(self) -> None:
        """Remove all placements for this client."""
        self._notify(METHOD_UNPLACE_ALL, None)

    def free(self, handle: int) -> None:
        """Release an uploaded image handle."""
        self._call(METHOD_FREE, {"handle": handle})

    def register_win(self, win_id: int, pane_id: str = "", top: int = 0, left: int = 0,
                     width: int = 0, height: int = 0, scroll_top: int = 0) -> None:
        """Register a neovim window geometry."""
        self._notify(METHOD_REGISTER_WIN, {
            "win_id": win_id,
            "pane_id": pane_id,
            "top": top,
            "left": left,
            "width": width,
            "height": height,
            "scroll_top": scroll_top,
        })

    def update_scroll(self, win_id: int, scroll_top: int) -> None:
        """Update scroll position for a registered window."""
        self._notify(METHOD_UPDATE_SCROLL, {
            "win_id": win_id,
            "scroll_top": scroll_top,
        })

    def unregister_win(self, win_id: int) -> None:
        """Unregister a neovim window."""
        self._notify(METHOD_UNREGISTER_WIN, {"win_id": win_id})

    def list(self) -> list[PlacementInfo]:
        """Return all active placements."""
        result = self._call(METHOD_LIST, None)
        if isinstance(result, dict):
            placements = []
            for p in result.get("placements", []) or []:
                if isinstance(p, dict):
                    placements.append(PlacementInfo(
                        placement_id=p.get("placement_id", 0),
                        client_id=p.get("client_id", ""),
                        handle=p.get("handle", 0),
                        visible=p.get("visible", False),
                        row=p.get("row", 0),
                        col=p.get("col", 0),
                    ))
            return placements
        return []

    def status(self) -> StatusResult:
        """Return daemon status information."""
        result = self._call(METHOD_STATUS, None)
        if isinstance(result, dict):
            return StatusResult(
                clients=result.get("clients", 0),
                placements=result.get("placements", 0),
                images=result.get("images", 0),
                cols=result.get("cols", 0),
                rows=result.get("rows", 0),
            )
        return StatusResult()

    def stop(self) -> None:
        """Request the daemon to shut down."""
        self._notify(METHOD_STOP, None)

    def close(self) -> None:
        """Close the connection."""
        self._done.set()
        self._sock.close()

    def _call(self, method: str, params: Any, timeout: float = 10.0) -> Any:
        """Send a request and wait for the response."""
        with self._pending_lock:
            msg_id = self._next_id
            self._next_id += 1
            event = threading.Event()
            self._pending[msg_id] = event

        try:
            self._send_request(msg_id, method, params)
            if not event.wait(timeout):
                raise TimeoutError(f"RPC call {method} timed out")
            if self._done.is_set():
                raise ConnectionError("connection closed")
            with self._pending_lock:
                err, result = self._results.pop(msg_id)
            if err is not None:
                if isinstance(err, dict) and "message" in err:
                    raise RuntimeError(err["message"])
                raise RuntimeError(f"RPC error: {err}")
            return result
        finally:
            with self._pending_lock:
                self._pending.pop(msg_id, None)

    def _send_request(self, msg_id: int, method: str, params: Any) -> None:
        """Encode and send a request message."""
        if params is not None:
            msg = [_MSG_REQUEST, msg_id, method, [params]]
        else:
            msg = [_MSG_REQUEST, msg_id, method, []]
        with self._lock:
            self._sock.sendall(self._packer.pack(msg))

    def _notify(self, method: str, params: Any) -> None:
        """Send a one-way notification."""
        if params is not None:
            msg = [_MSG_NOTIFICATION, method, [params]]
        else:
            msg = [_MSG_NOTIFICATION, method, []]
        with self._lock:
            self._sock.sendall(self._packer.pack(msg))

    def _read_loop(self) -> None:
        """Read responses and notifications from the daemon."""
        try:
            while not self._done.is_set():
                data = self._sock.recv(65536)
                if not data:
                    break
                self._unpacker.feed(data)
                for msg in self._unpacker:
                    if not isinstance(msg, list) or len(msg) < 3:
                        continue
                    msg_type = msg[0]
                    if msg_type == _MSG_RESPONSE:
                        self._handle_response(msg)
                    elif msg_type == _MSG_NOTIFICATION:
                        self._handle_notification(msg)
        except OSError:
            pass
        finally:
            self._done.set()
            # Wake up any pending calls
            with self._pending_lock:
                events = list(self._pending.values())
            for event in events:
                event.set()

    def _handle_response(self, msg: list) -> None:
        """Process a response message."""
        if len(msg) < 4:
            return
        msg_id = msg[1]
        err = msg[2]
        result = msg[3]
        with self._pending_lock:
            self._results[msg_id] = (err, result)
            event = self._pending.get(msg_id)
        if event:
            event.set()

    def _handle_notification(self, msg: list) -> None:
        """Process a notification message."""
        if len(msg) < 3:
            return
        method = msg[1]
        params_arr = msg[2]
        if not isinstance(params_arr, list) or len(params_arr) == 0:
            return
        params = params_arr[0]
        if not isinstance(params, dict):
            return

        if method == NOTIFY_EVICTED and self.on_evicted:
            self.on_evicted(params.get("handle", 0))
        elif method == NOTIFY_TOPOLOGY_CHANGED and self.on_topology_changed:
            self.on_topology_changed(
                params.get("cols", 0), params.get("rows", 0),
                params.get("cell_width", 0), params.get("cell_height", 0),
            )
        elif method == NOTIFY_VISIBILITY_CHANGED and self.on_visibility_changed:
            self.on_visibility_changed(
                params.get("placement_id", 0), params.get("visible", False),
            )
        elif method == NOTIFY_THEME_CHANGED and self.on_theme_changed:
            fg = Color(**{k: params.get("fg", {}).get(k, 0) for k in ("r", "g", "b")}) if "fg" in params else Color()
            bg = Color(**{k: params.get("bg", {}).get(k, 0) for k in ("r", "g", "b")}) if "bg" in params else Color()
            self.on_theme_changed(fg, bg)


def _default_socket_path() -> str:
    """Compute the default socket path."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime_dir:
        import tempfile
        runtime_dir = tempfile.gettempdir()
    kitty_id = os.environ.get("KITTY_WINDOW_ID", "default")
    return str(Path(runtime_dir) / f"kgd-{kitty_id}.sock")


def _ensure_daemon(socket_path: str) -> None:
    """Start the kgd daemon if not running."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(socket_path)
        sock.close()
        return
    except OSError:
        pass

    import shutil
    kgd_path = shutil.which("kgd")
    if not kgd_path:
        raise FileNotFoundError("kgd not found in PATH")

    subprocess.Popen(
        [kgd_path, "serve", "--socket", socket_path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    for _ in range(50):
        time.sleep(0.1)
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(socket_path)
            sock.close()
            return
        except OSError:
            continue

    raise TimeoutError("timed out waiting for kgd to start")
