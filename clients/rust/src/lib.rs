//! # kgd-client
//!
//! Rust client library for **kgd** (Kitty Graphics Daemon), a user-space daemon
//! that owns all kitty graphics protocol output for a terminal session.
//!
//! ## Quick start
//!
//! ```no_run
//! use kgd_client::{Client, Options, Anchor, AnchorType};
//!
//! #[tokio::main]
//! async fn main() -> kgd_client::Result<()> {
//!     let client = Client::connect(Options {
//!         client_type: "myapp".into(),
//!         ..Default::default()
//!     }).await?;
//!
//!     let handle = client.upload(b"PNG data here", "png", 100, 80).await?;
//!     let placement_id = client.place(handle, Anchor {
//!         anchor_type: AnchorType::Absolute,
//!         row: 5,
//!         col: 10,
//!         ..Default::default()
//!     }, 20, 15, None).await?;
//!
//!     client.unplace(placement_id).await?;
//!     client.free(handle).await?;
//!     client.close().await;
//!     Ok(())
//! }
//! ```
//!
//! ## Synchronous API
//!
//! A blocking wrapper is available via [`SyncClient`] for use outside of async
//! contexts:
//!
//! ```no_run
//! use kgd_client::{SyncClient, Options, Anchor, AnchorType};
//!
//! let client = SyncClient::connect(Options {
//!     client_type: "myapp".into(),
//!     ..Default::default()
//! }).unwrap();
//!
//! let handle = client.upload(b"PNG data here", "png", 100, 80).unwrap();
//! let pid = client.place(handle, Anchor {
//!     anchor_type: AnchorType::Absolute,
//!     row: 5,
//!     col: 10,
//!     ..Default::default()
//! }, 20, 15, None).unwrap();
//!
//! client.unplace(pid).unwrap();
//! client.free(handle).unwrap();
//! client.close();
//! ```
//!
//! ## Protocol
//!
//! Transport is a Unix domain socket with msgpack-RPC encoding. The socket path
//! is resolved from `$KGD_SOCKET`, falling back to
//! `$XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock`, then `/tmp/kgd-default.sock`.

pub mod error;
pub mod protocol;

pub use error::{KgdError, Result};

use protocol::{
    decode_message, encode_notification, encode_request, map_from_pairs, map_get, map_get_bool,
    map_get_i64, map_get_str, map_get_u64, ServerMessage, NOTIFY_EVICTED, NOTIFY_THEME_CHANGED,
    NOTIFY_TOPOLOGY_CHANGED, NOTIFY_VISIBILITY_CHANGED,
};
use rmpv::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::{oneshot, Mutex, RwLock};
use tokio::time::{timeout, Duration};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// RGB color with 16-bit per channel precision, matching the daemon's representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Color {
    pub r: u16,
    pub g: u16,
    pub b: u16,
}

impl Color {
    /// Construct a new color.
    pub fn new(r: u16, g: u16, b: u16) -> Self {
        Self { r, g, b }
    }

    /// Decode a `Color` from a msgpack map value.
    fn from_value(v: &Value) -> Self {
        Self {
            r: map_get_u64(v, "r") as u16,
            g: map_get_u64(v, "g") as u16,
            b: map_get_u64(v, "b") as u16,
        }
    }
}

/// The coordinate space an anchor refers to.
#[derive(Debug, Clone, PartialEq, Eq)]
#[derive(Default)]
pub enum AnchorType {
    /// Absolute terminal coordinates.
    #[default]
    Absolute,
    /// Relative to a tmux pane.
    Pane,
    /// Relative to a neovim window.
    NvimWin,
}

impl AnchorType {
    /// Return the wire name for this anchor type.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Absolute => "absolute",
            Self::Pane => "pane",
            Self::NvimWin => "nvim_win",
        }
    }
}

/// Describes a logical position for a placement.
///
/// Only the fields relevant to the chosen [`AnchorType`] need to be set;
/// zero-valued optional fields are omitted on the wire.
#[derive(Debug, Clone, Default)]
pub struct Anchor {
    /// The coordinate space.
    pub anchor_type: AnchorType,
    /// Tmux pane identifier (for [`AnchorType::Pane`]).
    pub pane_id: String,
    /// Neovim window ID (for [`AnchorType::NvimWin`]).
    pub win_id: i64,
    /// Buffer line number (for [`AnchorType::NvimWin`]).
    pub buf_line: i64,
    /// Row offset within the coordinate space.
    pub row: i64,
    /// Column offset within the coordinate space.
    pub col: i64,
}

impl Anchor {
    /// Encode the anchor as a msgpack map, omitting zero-valued optional fields.
    pub fn to_value(&self) -> Value {
        let mut pairs: Vec<(&str, Value)> =
            vec![("type", Value::String(self.anchor_type.as_str().into()))];

        if !self.pane_id.is_empty() {
            pairs.push(("pane_id", Value::String(self.pane_id.clone().into())));
        }
        if self.win_id != 0 {
            pairs.push(("win_id", Value::Integer(self.win_id.into())));
        }
        if self.buf_line != 0 {
            pairs.push(("buf_line", Value::Integer(self.buf_line.into())));
        }
        if self.row != 0 {
            pairs.push(("row", Value::Integer(self.row.into())));
        }
        if self.col != 0 {
            pairs.push(("col", Value::Integer(self.col.into())));
        }

        map_from_pairs(pairs)
    }
}

/// Optional parameters for [`Client::place`].
#[derive(Debug, Clone, Default)]
pub struct PlaceOpts {
    /// Source crop X offset in pixels.
    pub src_x: i64,
    /// Source crop Y offset in pixels.
    pub src_y: i64,
    /// Source crop width in pixels.
    pub src_w: i64,
    /// Source crop height in pixels.
    pub src_h: i64,
    /// Z-index for stacking order.
    pub z_index: i64,
}

/// Describes a single active placement, as returned by [`Client::list`].
#[derive(Debug, Clone, Default)]
pub struct PlacementInfo {
    /// Unique placement identifier.
    pub placement_id: u32,
    /// The client that owns this placement.
    pub client_id: String,
    /// The image handle.
    pub handle: u32,
    /// Whether the placement is currently visible.
    pub visible: bool,
    /// Resolved terminal row.
    pub row: i64,
    /// Resolved terminal column.
    pub col: i64,
}

/// Daemon status information, as returned by [`Client::status`].
#[derive(Debug, Clone, Default)]
pub struct StatusResult {
    /// Number of connected clients.
    pub clients: i64,
    /// Number of active placements.
    pub placements: i64,
    /// Number of cached images.
    pub images: i64,
    /// Terminal columns.
    pub cols: i64,
    /// Terminal rows.
    pub rows: i64,
}

/// Information returned by the initial hello handshake.
#[derive(Debug, Clone, Default)]
pub struct HelloResult {
    /// Unique identifier assigned to this client by the daemon.
    pub client_id: String,
    /// Terminal columns.
    pub cols: i64,
    /// Terminal rows.
    pub rows: i64,
    /// Cell width in pixels.
    pub cell_width: i64,
    /// Cell height in pixels.
    pub cell_height: i64,
    /// Whether the terminal is inside a tmux session.
    pub in_tmux: bool,
    /// Foreground color.
    pub fg: Color,
    /// Background color.
    pub bg: Color,
}

/// Options for connecting to the kgd daemon.
#[derive(Debug, Clone)]
pub struct Options {
    /// Explicit Unix socket path. If empty, the path is resolved from
    /// environment variables.
    pub socket_path: String,
    /// Session ID for stateless reconnection.
    pub session_id: String,
    /// Application type identifier sent in the hello handshake.
    pub client_type: String,
    /// Human-readable label for this client.
    pub label: String,
    /// Whether to auto-launch the daemon if it is not running.
    pub auto_launch: bool,
    /// Timeout for RPC calls. Defaults to 10 seconds.
    pub call_timeout: Duration,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            socket_path: String::new(),
            session_id: String::new(),
            client_type: String::new(),
            label: String::new(),
            auto_launch: true,
            call_timeout: Duration::from_secs(10),
        }
    }
}

// ---------------------------------------------------------------------------
// Notification callbacks
// ---------------------------------------------------------------------------

/// Callback invoked when an image is evicted from the daemon's cache.
///
/// Parameter: the evicted image handle.
pub type EvictedCallback = Box<dyn Fn(u32) + Send + Sync + 'static>;

/// Callback invoked when the terminal topology changes (resize, tmux split, etc.).
///
/// Parameters: `(cols, rows, cell_width, cell_height)`.
pub type TopologyChangedCallback = Box<dyn Fn(i64, i64, i64, i64) + Send + Sync + 'static>;

/// Callback invoked when a placement's visibility changes.
///
/// Parameters: `(placement_id, visible)`.
pub type VisibilityChangedCallback = Box<dyn Fn(u32, bool) + Send + Sync + 'static>;

/// Callback invoked when the terminal theme colors change.
///
/// Parameters: `(fg, bg)`.
pub type ThemeChangedCallback = Box<dyn Fn(Color, Color) + Send + Sync + 'static>;

/// Container for all notification callbacks.
struct Callbacks {
    on_evicted: Option<EvictedCallback>,
    on_topology_changed: Option<TopologyChangedCallback>,
    on_visibility_changed: Option<VisibilityChangedCallback>,
    on_theme_changed: Option<ThemeChangedCallback>,
}

// ---------------------------------------------------------------------------
// Internal pending-response bookkeeping
// ---------------------------------------------------------------------------

type PendingMap = HashMap<u32, oneshot::Sender<(Value, Value)>>;

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Asynchronous connection to the kgd daemon.
///
/// All RPC methods are `async` and require a tokio runtime. For a synchronous
/// wrapper, see [`SyncClient`].
///
/// The client spawns a background reader task that dispatches responses and
/// notifications. Dropping the client or calling [`Client::close`] shuts down
/// the reader.
pub struct Client {
    /// Socket write half, protected by a mutex so multiple tasks can issue
    /// concurrent calls.
    writer: Arc<Mutex<tokio::net::unix::OwnedWriteHalf>>,
    /// Monotonically increasing message ID.
    next_id: Arc<AtomicU32>,
    /// Map of pending request IDs to their oneshot response senders.
    pending: Arc<RwLock<PendingMap>>,
    /// Handle to the background reader task.
    reader_handle: Option<tokio::task::JoinHandle<()>>,
    /// RPC call timeout.
    call_timeout: Duration,
    /// Notification callbacks shared with the reader task.
    callbacks: Arc<RwLock<Callbacks>>,

    /// Information from the initial hello handshake.
    pub hello: HelloResult,
}

impl Client {
    /// Connect to the kgd daemon, perform the hello handshake, and start the
    /// background reader task.
    ///
    /// The daemon is auto-launched if `opts.auto_launch` is true and no daemon
    /// is listening at the resolved socket path.
    pub async fn connect(opts: Options) -> Result<Self> {
        let socket_path = resolve_socket_path(&opts.socket_path);

        if opts.auto_launch {
            ensure_daemon(&socket_path).await?;
        }

        let stream = UnixStream::connect(&socket_path)
            .await
            .map_err(KgdError::Connect)?;

        let (reader_half, writer_half) = stream.into_split();

        let writer = Arc::new(Mutex::new(writer_half));
        let next_id = Arc::new(AtomicU32::new(0));
        let pending: Arc<RwLock<PendingMap>> = Arc::new(RwLock::new(HashMap::new()));
        let callbacks = Arc::new(RwLock::new(Callbacks {
            on_evicted: None,
            on_topology_changed: None,
            on_visibility_changed: None,
            on_theme_changed: None,
        }));

        // Spawn reader task.
        let reader_pending = Arc::clone(&pending);
        let reader_callbacks = Arc::clone(&callbacks);
        let reader_handle = tokio::spawn(read_loop(reader_half, reader_pending, reader_callbacks));

        let mut client = Self {
            writer,
            next_id,
            pending,
            reader_handle: Some(reader_handle),
            call_timeout: opts.call_timeout,
            callbacks,
            hello: HelloResult::default(),
        };

        // Perform hello handshake.
        let mut hello_params: Vec<(&str, Value)> = vec![
            ("client_type", Value::String(opts.client_type.into())),
            (
                "pid",
                Value::Integer((std::process::id() as i64).into()),
            ),
            ("label", Value::String(opts.label.into())),
        ];
        if !opts.session_id.is_empty() {
            hello_params.push(("session_id", Value::String(opts.session_id.into())));
        }

        let result = client
            .call(
                protocol::METHOD_HELLO,
                Some(map_from_pairs(hello_params)),
            )
            .await
            .map_err(|e| KgdError::Hello(e.to_string()))?;

        client.hello = HelloResult {
            client_id: map_get_str(&result, "client_id"),
            cols: map_get_i64(&result, "cols"),
            rows: map_get_i64(&result, "rows"),
            cell_width: map_get_i64(&result, "cell_width"),
            cell_height: map_get_i64(&result, "cell_height"),
            in_tmux: map_get_bool(&result, "in_tmux"),
            fg: map_get(&result, "fg").map(Color::from_value).unwrap_or_default(),
            bg: map_get(&result, "bg").map(Color::from_value).unwrap_or_default(),
        };

        Ok(client)
    }

    /// Upload image data to the daemon.
    ///
    /// Returns a handle that can be used with [`Client::place`] and
    /// [`Client::free`].
    pub async fn upload(&self, data: &[u8], format: &str, width: i64, height: i64) -> Result<u32> {
        let params = map_from_pairs(vec![
            ("data", Value::Binary(data.to_vec())),
            ("format", Value::String(format.into())),
            ("width", Value::Integer(width.into())),
            ("height", Value::Integer(height.into())),
        ]);
        let result = self.call(protocol::METHOD_UPLOAD, Some(params)).await?;
        Ok(map_get_u64(&result, "handle") as u32)
    }

    /// Place an uploaded image at the given anchor position.
    ///
    /// Returns a placement ID that can be used with [`Client::unplace`].
    pub async fn place(
        &self,
        handle: u32,
        anchor: Anchor,
        width: i64,
        height: i64,
        opts: Option<PlaceOpts>,
    ) -> Result<u32> {
        let mut pairs: Vec<(&str, Value)> = vec![
            ("handle", Value::Integer((handle as i64).into())),
            ("anchor", anchor.to_value()),
            ("width", Value::Integer(width.into())),
            ("height", Value::Integer(height.into())),
        ];

        if let Some(o) = opts {
            if o.src_x != 0 {
                pairs.push(("src_x", Value::Integer(o.src_x.into())));
            }
            if o.src_y != 0 {
                pairs.push(("src_y", Value::Integer(o.src_y.into())));
            }
            if o.src_w != 0 {
                pairs.push(("src_w", Value::Integer(o.src_w.into())));
            }
            if o.src_h != 0 {
                pairs.push(("src_h", Value::Integer(o.src_h.into())));
            }
            if o.z_index != 0 {
                pairs.push(("z_index", Value::Integer(o.z_index.into())));
            }
        }

        let result = self
            .call(protocol::METHOD_PLACE, Some(map_from_pairs(pairs)))
            .await?;
        Ok(map_get_u64(&result, "placement_id") as u32)
    }

    /// Remove a single placement by ID.
    pub async fn unplace(&self, placement_id: u32) -> Result<()> {
        let params = map_from_pairs(vec![(
            "placement_id",
            Value::Integer((placement_id as i64).into()),
        )]);
        self.call(protocol::METHOD_UNPLACE, Some(params)).await?;
        Ok(())
    }

    /// Remove all placements belonging to this client (fire-and-forget).
    pub async fn unplace_all(&self) -> Result<()> {
        self.notify(protocol::METHOD_UNPLACE_ALL, None).await
    }

    /// Release an uploaded image handle.
    pub async fn free(&self, handle: u32) -> Result<()> {
        let params = map_from_pairs(vec![("handle", Value::Integer((handle as i64).into()))]);
        self.call(protocol::METHOD_FREE, Some(params)).await?;
        Ok(())
    }

    /// Register a neovim window geometry (fire-and-forget).
    #[allow(clippy::too_many_arguments)]
    pub async fn register_win(
        &self,
        win_id: i64,
        pane_id: &str,
        top: i64,
        left: i64,
        width: i64,
        height: i64,
        scroll_top: i64,
    ) -> Result<()> {
        let params = map_from_pairs(vec![
            ("win_id", Value::Integer(win_id.into())),
            ("pane_id", Value::String(pane_id.into())),
            ("top", Value::Integer(top.into())),
            ("left", Value::Integer(left.into())),
            ("width", Value::Integer(width.into())),
            ("height", Value::Integer(height.into())),
            ("scroll_top", Value::Integer(scroll_top.into())),
        ]);
        self.notify(protocol::METHOD_REGISTER_WIN, Some(params))
            .await
    }

    /// Update the scroll position for a registered neovim window (fire-and-forget).
    pub async fn update_scroll(&self, win_id: i64, scroll_top: i64) -> Result<()> {
        let params = map_from_pairs(vec![
            ("win_id", Value::Integer(win_id.into())),
            ("scroll_top", Value::Integer(scroll_top.into())),
        ]);
        self.notify(protocol::METHOD_UPDATE_SCROLL, Some(params))
            .await
    }

    /// Unregister a neovim window (fire-and-forget).
    pub async fn unregister_win(&self, win_id: i64) -> Result<()> {
        let params = map_from_pairs(vec![("win_id", Value::Integer(win_id.into()))]);
        self.notify(protocol::METHOD_UNREGISTER_WIN, Some(params))
            .await
    }

    /// Return all active placements.
    pub async fn list(&self) -> Result<Vec<PlacementInfo>> {
        let result = self.call(protocol::METHOD_LIST, None).await?;
        let mut placements = Vec::new();

        if let Some(arr) = map_get(&result, "placements").and_then(|v| v.as_array()) {
            for p in arr {
                placements.push(PlacementInfo {
                    placement_id: map_get_u64(p, "placement_id") as u32,
                    client_id: map_get_str(p, "client_id"),
                    handle: map_get_u64(p, "handle") as u32,
                    visible: map_get_bool(p, "visible"),
                    row: map_get_i64(p, "row"),
                    col: map_get_i64(p, "col"),
                });
            }
        }

        Ok(placements)
    }

    /// Return daemon status information.
    pub async fn status(&self) -> Result<StatusResult> {
        let result = self.call(protocol::METHOD_STATUS, None).await?;
        Ok(StatusResult {
            clients: map_get_i64(&result, "clients"),
            placements: map_get_i64(&result, "placements"),
            images: map_get_i64(&result, "images"),
            cols: map_get_i64(&result, "cols"),
            rows: map_get_i64(&result, "rows"),
        })
    }

    /// Request the daemon to shut down (fire-and-forget).
    pub async fn stop(&self) -> Result<()> {
        self.notify(protocol::METHOD_STOP, None).await
    }

    /// Close the connection and shut down the reader task.
    pub async fn close(mut self) {
        // Closing the writer will cause the reader to see EOF.
        drop(self.writer);
        if let Some(handle) = self.reader_handle.take() {
            let _ = handle.await;
        }
    }

    // -- Notification callback setters --------------------------------------

    /// Set the callback for image eviction notifications.
    pub async fn set_on_evicted<F>(&self, f: F)
    where
        F: Fn(u32) + Send + Sync + 'static,
    {
        self.callbacks.write().await.on_evicted = Some(Box::new(f));
    }

    /// Set the callback for topology change notifications.
    pub async fn set_on_topology_changed<F>(&self, f: F)
    where
        F: Fn(i64, i64, i64, i64) + Send + Sync + 'static,
    {
        self.callbacks.write().await.on_topology_changed = Some(Box::new(f));
    }

    /// Set the callback for placement visibility change notifications.
    pub async fn set_on_visibility_changed<F>(&self, f: F)
    where
        F: Fn(u32, bool) + Send + Sync + 'static,
    {
        self.callbacks.write().await.on_visibility_changed = Some(Box::new(f));
    }

    /// Set the callback for theme change notifications.
    pub async fn set_on_theme_changed<F>(&self, f: F)
    where
        F: Fn(Color, Color) + Send + Sync + 'static,
    {
        self.callbacks.write().await.on_theme_changed = Some(Box::new(f));
    }

    // -- Internal RPC helpers -----------------------------------------------

    /// Send a request and wait for the response.
    async fn call(&self, method: &str, params: Option<Value>) -> Result<Value> {
        let msgid = self.next_id.fetch_add(1, Ordering::Relaxed);

        let (tx, rx) = oneshot::channel::<(Value, Value)>();

        // Register the pending request.
        self.pending.write().await.insert(msgid, tx);

        // Encode and send.
        let bytes = encode_request(msgid, method, params);
        {
            let mut w = self.writer.lock().await;
            w.write_all(&bytes).await.map_err(KgdError::Send)?;
        }

        // Wait for the response with a timeout.
        let result = timeout(self.call_timeout, rx)
            .await
            .map_err(|_| KgdError::Timeout(method.to_string()))?
            .map_err(|_| KgdError::ConnectionClosed)?;

        let (err, value) = result;
        if !err.is_nil() {
            // Extract the error message from the RPC error.
            let msg = if let Some(m) = map_get(&err, "message").and_then(|v| v.as_str()) {
                m.to_string()
            } else {
                format!("{err}")
            };
            return Err(KgdError::Rpc(msg));
        }

        Ok(value)
    }

    /// Send a fire-and-forget notification.
    async fn notify(&self, method: &str, params: Option<Value>) -> Result<()> {
        let bytes = encode_notification(method, params);
        let mut w = self.writer.lock().await;
        w.write_all(&bytes).await.map_err(KgdError::Send)?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Background reader task
// ---------------------------------------------------------------------------

/// Continuously read from the socket, decode msgpack values, and dispatch
/// responses and notifications.
async fn read_loop(
    mut reader: tokio::net::unix::OwnedReadHalf,
    pending: Arc<RwLock<PendingMap>>,
    callbacks: Arc<RwLock<Callbacks>>,
) {
    let mut buf = vec![0u8; 65536];
    let mut remainder = Vec::new();

    loop {
        let n = match reader.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };

        remainder.extend_from_slice(&buf[..n]);

        // Try to decode as many messages as possible from the buffer.
        loop {
            let mut cursor = std::io::Cursor::new(&remainder[..]);
            match rmpv::decode::read_value(&mut cursor) {
                Ok(value) => {
                    let consumed = cursor.position() as usize;
                    remainder.drain(..consumed);

                    if let Some(msg) = decode_message(value) {
                        match msg {
                            ServerMessage::Response {
                                msgid,
                                error,
                                result,
                            } => {
                                let sender = pending.write().await.remove(&msgid);
                                if let Some(tx) = sender {
                                    let _ = tx.send((error, result));
                                }
                            }
                            ServerMessage::Notification { method, params } => {
                                dispatch_notification(&callbacks, &method, &params).await;
                            }
                        }
                    }
                }
                Err(_) => {
                    // Not enough data yet, wait for more.
                    break;
                }
            }
        }
    }

    // Connection closed: wake up all pending requests so they don't hang.
    let mut map = pending.write().await;
    for (_, tx) in map.drain() {
        let _ = tx.send((Value::String("connection closed".into()), Value::Nil));
    }
}

/// Dispatch a notification to the appropriate callback.
async fn dispatch_notification(
    callbacks: &Arc<RwLock<Callbacks>>,
    method: &str,
    params: &Value,
) {
    // Params is the full params array, e.g. [{ ... }]. Extract the first element.
    let param = match params.as_array().and_then(|a| a.first()) {
        Some(v) => v,
        None => return,
    };

    let cbs = callbacks.read().await;

    match method {
        NOTIFY_EVICTED => {
            if let Some(ref cb) = cbs.on_evicted {
                cb(map_get_u64(param, "handle") as u32);
            }
        }
        NOTIFY_TOPOLOGY_CHANGED => {
            if let Some(ref cb) = cbs.on_topology_changed {
                cb(
                    map_get_i64(param, "cols"),
                    map_get_i64(param, "rows"),
                    map_get_i64(param, "cell_width"),
                    map_get_i64(param, "cell_height"),
                );
            }
        }
        NOTIFY_VISIBILITY_CHANGED => {
            if let Some(ref cb) = cbs.on_visibility_changed {
                cb(
                    map_get_u64(param, "placement_id") as u32,
                    map_get_bool(param, "visible"),
                );
            }
        }
        NOTIFY_THEME_CHANGED => {
            if let Some(ref cb) = cbs.on_theme_changed {
                let fg = map_get(param, "fg").map(Color::from_value).unwrap_or_default();
                let bg = map_get(param, "bg").map(Color::from_value).unwrap_or_default();
                cb(fg, bg);
            }
        }
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// Socket path resolution
// ---------------------------------------------------------------------------

/// Resolve the socket path from the given override or environment variables.
///
/// Resolution order:
/// 1. `override_path` if non-empty
/// 2. `$KGD_SOCKET`
/// 3. `$XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock`
/// 4. `/tmp/kgd-default.sock`
fn resolve_socket_path(override_path: &str) -> String {
    if !override_path.is_empty() {
        return override_path.to_string();
    }

    if let Ok(val) = std::env::var("KGD_SOCKET") {
        if !val.is_empty() {
            return val;
        }
    }

    let runtime_dir = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| std::env::temp_dir().to_string_lossy().into_owned());

    let kitty_id = std::env::var("KITTY_WINDOW_ID")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "default".to_string());

    let mut path = PathBuf::from(runtime_dir);
    path.push(format!("kgd-{kitty_id}.sock"));
    path.to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// Daemon auto-launch
// ---------------------------------------------------------------------------

/// Ensure the daemon is running. If it is not reachable, attempt to spawn it
/// and wait for it to start accepting connections.
async fn ensure_daemon(socket_path: &str) -> Result<()> {
    // Try connecting to see if it is already running.
    if UnixStream::connect(socket_path).await.is_ok() {
        return Ok(());
    }

    // Find the kgd binary.
    let kgd_path = which_kgd().ok_or(KgdError::DaemonNotFound)?;

    // Spawn the daemon.
    let _ = tokio::process::Command::new(&kgd_path)
        .args(["serve", "--socket", socket_path])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(KgdError::Connect)?;

    // Poll until the socket is reachable (up to 5 seconds).
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if UnixStream::connect(socket_path).await.is_ok() {
            return Ok(());
        }
    }

    Err(KgdError::DaemonLaunchTimeout)
}

/// Search `$PATH` for the `kgd` binary.
fn which_kgd() -> Option<String> {
    let path_env = std::env::var("PATH").ok()?;
    for dir in path_env.split(':') {
        let candidate = PathBuf::from(dir).join("kgd");
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

// ---------------------------------------------------------------------------
// SyncClient — blocking wrapper
// ---------------------------------------------------------------------------

/// Synchronous (blocking) client for use outside of async contexts.
///
/// Internally creates a tokio runtime and delegates to [`Client`].
/// Each call blocks the current thread until the response is received.
pub struct SyncClient {
    runtime: tokio::runtime::Runtime,
    client: Option<Client>,
}

impl SyncClient {
    /// Connect to the kgd daemon (blocking).
    pub fn connect(opts: Options) -> Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(KgdError::Connect)?;

        let client = runtime.block_on(Client::connect(opts))?;
        Ok(Self {
            runtime,
            client: Some(client),
        })
    }

    /// The hello result from the initial handshake.
    pub fn hello(&self) -> &HelloResult {
        &self.client.as_ref().expect("client consumed").hello
    }

    /// Upload image data (blocking). Returns an image handle.
    pub fn upload(&self, data: &[u8], format: &str, width: i64, height: i64) -> Result<u32> {
        self.runtime
            .block_on(self.client.as_ref().expect("client consumed").upload(data, format, width, height))
    }

    /// Place an image (blocking). Returns a placement ID.
    pub fn place(
        &self,
        handle: u32,
        anchor: Anchor,
        width: i64,
        height: i64,
        opts: Option<PlaceOpts>,
    ) -> Result<u32> {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .place(handle, anchor, width, height, opts),
        )
    }

    /// Remove a placement (blocking).
    pub fn unplace(&self, placement_id: u32) -> Result<()> {
        self.runtime
            .block_on(self.client.as_ref().expect("client consumed").unplace(placement_id))
    }

    /// Remove all placements for this client (blocking).
    pub fn unplace_all(&self) -> Result<()> {
        self.runtime
            .block_on(self.client.as_ref().expect("client consumed").unplace_all())
    }

    /// Release an uploaded image handle (blocking).
    pub fn free(&self, handle: u32) -> Result<()> {
        self.runtime
            .block_on(self.client.as_ref().expect("client consumed").free(handle))
    }

    /// Register a neovim window geometry (blocking).
    #[allow(clippy::too_many_arguments)]
    pub fn register_win(
        &self,
        win_id: i64,
        pane_id: &str,
        top: i64,
        left: i64,
        width: i64,
        height: i64,
        scroll_top: i64,
    ) -> Result<()> {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .register_win(win_id, pane_id, top, left, width, height, scroll_top),
        )
    }

    /// Update scroll position (blocking).
    pub fn update_scroll(&self, win_id: i64, scroll_top: i64) -> Result<()> {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .update_scroll(win_id, scroll_top),
        )
    }

    /// Unregister a neovim window (blocking).
    pub fn unregister_win(&self, win_id: i64) -> Result<()> {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .unregister_win(win_id),
        )
    }

    /// List active placements (blocking).
    pub fn list(&self) -> Result<Vec<PlacementInfo>> {
        self.runtime
            .block_on(self.client.as_ref().expect("client consumed").list())
    }

    /// Get daemon status (blocking).
    pub fn status(&self) -> Result<StatusResult> {
        self.runtime
            .block_on(self.client.as_ref().expect("client consumed").status())
    }

    /// Request daemon shutdown (blocking).
    pub fn stop(&self) -> Result<()> {
        self.runtime
            .block_on(self.client.as_ref().expect("client consumed").stop())
    }

    /// Close the connection (blocking).
    pub fn close(mut self) {
        if let Some(client) = self.client.take() {
            self.runtime.block_on(client.close());
        }
    }

    /// Set the callback for image eviction notifications.
    pub fn set_on_evicted<F>(&self, f: F)
    where
        F: Fn(u32) + Send + Sync + 'static,
    {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .set_on_evicted(f),
        );
    }

    /// Set the callback for topology change notifications.
    pub fn set_on_topology_changed<F>(&self, f: F)
    where
        F: Fn(i64, i64, i64, i64) + Send + Sync + 'static,
    {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .set_on_topology_changed(f),
        );
    }

    /// Set the callback for visibility change notifications.
    pub fn set_on_visibility_changed<F>(&self, f: F)
    where
        F: Fn(u32, bool) + Send + Sync + 'static,
    {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .set_on_visibility_changed(f),
        );
    }

    /// Set the callback for theme change notifications.
    pub fn set_on_theme_changed<F>(&self, f: F)
    where
        F: Fn(Color, Color) + Send + Sync + 'static,
    {
        self.runtime.block_on(
            self.client
                .as_ref()
                .expect("client consumed")
                .set_on_theme_changed(f),
        );
    }
}
