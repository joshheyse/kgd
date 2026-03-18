package com.kgd.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.net.StandardProtocolFamily
import java.net.UnixDomainSocketAddress
import java.nio.channels.Channels
import java.nio.channels.SocketChannel
import kotlin.io.path.Path

/**
 * Asynchronous client for the kgd (Kitty Graphics Daemon).
 *
 * Uses Kotlin coroutines for non-blocking I/O. The [connect] factory method
 * establishes a Unix socket connection, starts a reader coroutine, and
 * performs the initial `hello` handshake.
 *
 * Usage:
 * ```kotlin
 * val client = KgdClient.connect(Options(clientType = "myapp"))
 * val handle = client.upload(imageData, "png", width, height)
 * val pid = client.place(handle, Anchor.absolute(row = 5, col = 10), 20, 15)
 * client.unplace(pid)
 * client.free(handle)
 * client.close()
 * ```
 */
class KgdClient private constructor(
    private val channel: SocketChannel,
    private val scope: CoroutineScope,
) {

    private val writeMutex = Mutex()
    private val pendingMutex = Mutex()
    private var nextId = 0
    private val pending = mutableMapOf<Int, CompletableDeferred<RpcMessage.Response>>()
    private val decoder = Decoder(Channels.newInputStream(channel))
    private var readerJob: Job? = null

    // -- Hello result fields --------------------------------------------------

    /** Unique client identifier assigned by the daemon. */
    var clientId: String = ""
        private set

    /** Terminal column count. */
    var cols: Int = 0
        private set

    /** Terminal row count. */
    var rows: Int = 0
        private set

    /** Cell width in pixels. */
    var cellWidth: Int = 0
        private set

    /** Cell height in pixels. */
    var cellHeight: Int = 0
        private set

    /** Whether the session is inside tmux. */
    var inTmux: Boolean = false
        private set

    /** Foreground color. */
    var fg: Color = Color()
        private set

    /** Background color. */
    var bg: Color = Color()
        private set

    // -- Notification callbacks ------------------------------------------------

    /** Called when an uploaded image is evicted from the cache. */
    var onEvicted: ((handle: Long) -> Unit)? = null

    /** Called when terminal topology changes. Params: cols, rows, cellWidth, cellHeight. */
    var onTopologyChanged: ((cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) -> Unit)? = null

    /** Called when a placement's visibility changes. */
    var onVisibilityChanged: ((placementId: Long, visible: Boolean) -> Unit)? = null

    /** Called when the terminal theme changes. */
    var onThemeChanged: ((fg: Color, bg: Color) -> Unit)? = null

    // -- Public API -----------------------------------------------------------

    /**
     * Upload image data and return a handle for future placement.
     *
     * @param data Raw image bytes.
     * @param format Image format string (e.g. "png", "rgb", "rgba").
     * @param width Image width in pixels.
     * @param height Image height in pixels.
     * @return An opaque handle identifying the uploaded image.
     */
    suspend fun upload(data: ByteArray, format: String, width: Int, height: Int): Long {
        val result = call(Method.UPLOAD, mapOf(
            "data" to data,
            "format" to format,
            "width" to width,
            "height" to height,
        ))
        val m = ValueHelper.asMap(result)
        return ValueHelper.asLong(m["handle"])
    }

    /**
     * Place an image on the terminal.
     *
     * @param handle Image handle from [upload].
     * @param anchor Positioning anchor.
     * @param width Display width in terminal cells.
     * @param height Display height in terminal cells.
     * @param opts Optional source crop and z-index parameters.
     * @return A placement ID that can be used with [unplace].
     */
    suspend fun place(
        handle: Long,
        anchor: Anchor,
        width: Int,
        height: Int,
        opts: PlaceOpts = PlaceOpts(),
    ): Long {
        val params = buildMap<String, Any> {
            put("handle", handle)
            put("anchor", anchor.toMap())
            put("width", width)
            put("height", height)
            if (opts.srcX != 0) put("src_x", opts.srcX)
            if (opts.srcY != 0) put("src_y", opts.srcY)
            if (opts.srcW != 0) put("src_w", opts.srcW)
            if (opts.srcH != 0) put("src_h", opts.srcH)
            if (opts.zIndex != 0) put("z_index", opts.zIndex)
        }
        val result = call(Method.PLACE, params)
        val m = ValueHelper.asMap(result)
        return ValueHelper.asLong(m["placement_id"])
    }

    /**
     * Remove a single placement.
     */
    suspend fun unplace(placementId: Long) {
        call(Method.UNPLACE, mapOf("placement_id" to placementId))
    }

    /**
     * Remove all placements for this client. Fire-and-forget notification.
     */
    suspend fun unplaceAll() {
        notify(Method.UNPLACE_ALL, null)
    }

    /**
     * Release an uploaded image handle.
     */
    suspend fun free(handle: Long) {
        call(Method.FREE, mapOf("handle" to handle))
    }

    /**
     * Register a neovim window geometry. Fire-and-forget notification.
     */
    suspend fun registerWin(
        winId: Int,
        paneId: String = "",
        top: Int = 0,
        left: Int = 0,
        width: Int = 0,
        height: Int = 0,
        scrollTop: Int = 0,
    ) {
        notify(Method.REGISTER_WIN, mapOf(
            "win_id" to winId,
            "pane_id" to paneId,
            "top" to top,
            "left" to left,
            "width" to width,
            "height" to height,
            "scroll_top" to scrollTop,
        ))
    }

    /**
     * Update scroll position for a registered window. Fire-and-forget notification.
     */
    suspend fun updateScroll(winId: Int, scrollTop: Int) {
        notify(Method.UPDATE_SCROLL, mapOf(
            "win_id" to winId,
            "scroll_top" to scrollTop,
        ))
    }

    /**
     * Unregister a neovim window. Fire-and-forget notification.
     */
    suspend fun unregisterWin(winId: Int) {
        notify(Method.UNREGISTER_WIN, mapOf("win_id" to winId))
    }

    /**
     * Return all active placements.
     */
    suspend fun list(): List<PlacementInfo> {
        val result = call(Method.LIST, null)
        val m = ValueHelper.asMap(result)
        val arr = ValueHelper.asList(m["placements"])
        return arr.map { v ->
            val p = ValueHelper.asMap(v)
            PlacementInfo(
                placementId = ValueHelper.asLong(p["placement_id"]),
                clientId = ValueHelper.asString(p["client_id"]),
                handle = ValueHelper.asLong(p["handle"]),
                visible = ValueHelper.asBool(p["visible"]),
                row = ValueHelper.asInt(p["row"]),
                col = ValueHelper.asInt(p["col"]),
            )
        }
    }

    /**
     * Return daemon status information.
     */
    suspend fun status(): StatusResult {
        val result = call(Method.STATUS, null)
        val m = ValueHelper.asMap(result)
        return StatusResult(
            clients = ValueHelper.asInt(m["clients"]),
            placements = ValueHelper.asInt(m["placements"]),
            images = ValueHelper.asInt(m["images"]),
            cols = ValueHelper.asInt(m["cols"]),
            rows = ValueHelper.asInt(m["rows"]),
        )
    }

    /**
     * Request the daemon to shut down. Fire-and-forget notification.
     */
    suspend fun stop() {
        notify(Method.STOP, null)
    }

    /**
     * Close the connection and cancel the reader coroutine.
     */
    fun close() {
        readerJob?.cancel()
        try { decoder.close() } catch (_: IOException) {}
        try { channel.close() } catch (_: IOException) {}
        scope.cancel()
    }

    // -- Internal RPC ---------------------------------------------------------

    private suspend fun call(
        method: String,
        params: Map<String, Any>?,
        timeoutMs: Long = 10_000L,
    ): org.msgpack.value.Value? {
        val deferred = CompletableDeferred<RpcMessage.Response>()
        val msgId: Int

        pendingMutex.withLock {
            msgId = nextId++
            pending[msgId] = deferred
        }

        try {
            sendRequest(msgId, method, params)
            val response = withTimeout(timeoutMs) { deferred.await() }

            if (response.error != null) {
                val errMap = ValueHelper.asMap(response.error)
                val message = ValueHelper.asString(errMap["message"], response.error.toString())
                throw RuntimeException(message)
            }

            return response.result
        } finally {
            pendingMutex.withLock {
                pending.remove(msgId)
            }
        }
    }

    private suspend fun sendRequest(msgId: Int, method: String, params: Map<String, Any>?) {
        val data = Encoder.encodeRequest(msgId, method, params)
        writeMutex.withLock {
            val buf = java.nio.ByteBuffer.wrap(data)
            while (buf.hasRemaining()) {
                channel.write(buf)
            }
        }
    }

    private suspend fun notify(method: String, params: Map<String, Any>?) {
        val data = Encoder.encodeNotification(method, params)
        writeMutex.withLock {
            val buf = java.nio.ByteBuffer.wrap(data)
            while (buf.hasRemaining()) {
                channel.write(buf)
            }
        }
    }

    private fun startReader() {
        readerJob = scope.launch(Dispatchers.IO) {
            try {
                while (isActive) {
                    val msg = decoder.readMessage() ?: break
                    when (msg) {
                        is RpcMessage.Response -> handleResponse(msg)
                        is RpcMessage.Notification -> handleNotification(msg)
                    }
                }
            } catch (_: IOException) {
                // Connection closed
            } finally {
                // Wake up any pending calls
                pendingMutex.withLock {
                    for ((_, deferred) in pending) {
                        deferred.completeExceptionally(IOException("connection closed"))
                    }
                    pending.clear()
                }
            }
        }
    }

    private suspend fun handleResponse(msg: RpcMessage.Response) {
        val deferred = pendingMutex.withLock { pending[msg.msgId] }
        deferred?.complete(msg)
    }

    private fun handleNotification(msg: RpcMessage.Notification) {
        if (msg.params.isEmpty()) return
        val paramsValue = msg.params[0]
        if (!paramsValue.isMapValue) return
        val params = ValueHelper.asMap(paramsValue)

        when (msg.method) {
            Notify.EVICTED -> {
                onEvicted?.invoke(ValueHelper.asLong(params["handle"]))
            }
            Notify.TOPOLOGY_CHANGED -> {
                onTopologyChanged?.invoke(
                    ValueHelper.asInt(params["cols"]),
                    ValueHelper.asInt(params["rows"]),
                    ValueHelper.asInt(params["cell_width"]),
                    ValueHelper.asInt(params["cell_height"]),
                )
            }
            Notify.VISIBILITY_CHANGED -> {
                onVisibilityChanged?.invoke(
                    ValueHelper.asLong(params["placement_id"]),
                    ValueHelper.asBool(params["visible"]),
                )
            }
            Notify.THEME_CHANGED -> {
                val fgMap = if (params.containsKey("fg")) ValueHelper.asMap(params["fg"]) else emptyMap()
                val bgMap = if (params.containsKey("bg")) ValueHelper.asMap(params["bg"]) else emptyMap()
                val fgColor = if (fgMap.isNotEmpty()) ValueHelper.colorFromMap(fgMap) else Color()
                val bgColor = if (bgMap.isNotEmpty()) ValueHelper.colorFromMap(bgMap) else Color()
                onThemeChanged?.invoke(fgColor, bgColor)
            }
        }
    }

    private suspend fun hello(opts: Options) {
        val helloParams = buildMap<String, Any> {
            put("client_type", opts.clientType)
            put("pid", ProcessHandle.current().pid())
            put("label", opts.label)
            if (opts.sessionId.isNotEmpty()) {
                put("session_id", opts.sessionId)
            }
        }

        val result = call(Method.HELLO, helloParams)
        val m = ValueHelper.asMap(result)
        clientId = ValueHelper.asString(m["client_id"])
        cols = ValueHelper.asInt(m["cols"])
        rows = ValueHelper.asInt(m["rows"])
        cellWidth = ValueHelper.asInt(m["cell_width"])
        cellHeight = ValueHelper.asInt(m["cell_height"])
        inTmux = ValueHelper.asBool(m["in_tmux"])

        if (m.containsKey("fg")) {
            fg = ValueHelper.colorFromMap(ValueHelper.asMap(m["fg"]))
        }
        if (m.containsKey("bg")) {
            bg = ValueHelper.colorFromMap(ValueHelper.asMap(m["bg"]))
        }
    }

    companion object {
        /**
         * Connect to the kgd daemon and perform the hello handshake.
         *
         * @param opts Connection options.
         * @param scope Coroutine scope for the reader coroutine. Defaults to a new scope
         *              using [Dispatchers.IO].
         * @return A connected [KgdClient] instance.
         */
        suspend fun connect(
            opts: Options = Options(),
            scope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
        ): KgdClient {
            val socketPath = resolveSocketPath(opts.socketPath)

            if (opts.autoLaunch) {
                ensureDaemon(socketPath)
            }

            val address = UnixDomainSocketAddress.of(socketPath)
            val channel = SocketChannel.open(StandardProtocolFamily.UNIX)
            channel.connect(address)

            val client = KgdClient(channel, scope)
            client.startReader()
            client.hello(opts)
            return client
        }

        /**
         * Resolve the socket path from environment variables.
         *
         * Priority: explicit path > $KGD_SOCKET > $XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock
         */
        internal fun resolveSocketPath(explicit: String): String {
            if (explicit.isNotEmpty()) return explicit

            val envSocket = System.getenv("KGD_SOCKET")
            if (!envSocket.isNullOrEmpty()) return envSocket

            val runtimeDir = System.getenv("XDG_RUNTIME_DIR")
                ?: System.getProperty("java.io.tmpdir")
                ?: "/tmp"
            val kittyId = System.getenv("KITTY_WINDOW_ID") ?: "default"
            return Path(runtimeDir).resolve("kgd-$kittyId.sock").toString()
        }

        /**
         * Start the kgd daemon if not already running.
         */
        internal fun ensureDaemon(socketPath: String) {
            // Try connecting first
            try {
                val address = UnixDomainSocketAddress.of(socketPath)
                val ch = SocketChannel.open(StandardProtocolFamily.UNIX)
                ch.connect(address)
                ch.close()
                return
            } catch (_: IOException) {
                // Not running, need to start
            }

            // Find kgd binary
            val kgdPath = findExecutable("kgd")
                ?: throw IllegalStateException("kgd not found in PATH")

            // Launch daemon
            ProcessBuilder(kgdPath, "serve", "--socket", socketPath)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()

            // Wait for it to be ready
            repeat(50) {
                Thread.sleep(100)
                try {
                    val address = UnixDomainSocketAddress.of(socketPath)
                    val ch = SocketChannel.open(StandardProtocolFamily.UNIX)
                    ch.connect(address)
                    ch.close()
                    return
                } catch (_: IOException) {
                    // Not ready yet
                }
            }

            throw IllegalStateException("timed out waiting for kgd to start")
        }

        private fun findExecutable(name: String): String? {
            val pathEnv = System.getenv("PATH") ?: return null
            val separator = System.getProperty("path.separator") ?: ":"
            for (dir in pathEnv.split(separator)) {
                val candidate = Path(dir).resolve(name)
                val file = candidate.toFile()
                if (file.exists() && file.canExecute()) {
                    return candidate.toString()
                }
            }
            return null
        }
    }
}

/**
 * Blocking wrapper around [KgdClient] for use from non-coroutine code.
 *
 * Every method delegates to the underlying [KgdClient] via [runBlocking].
 *
 * Usage:
 * ```kotlin
 * val client = KgdClientBlocking.connect(Options(clientType = "myapp"))
 * val handle = client.upload(imageData, "png", width, height)
 * client.close()
 * ```
 */
class KgdClientBlocking private constructor(
    private val inner: KgdClient,
) {
    val clientId: String get() = inner.clientId
    val cols: Int get() = inner.cols
    val rows: Int get() = inner.rows
    val cellWidth: Int get() = inner.cellWidth
    val cellHeight: Int get() = inner.cellHeight
    val inTmux: Boolean get() = inner.inTmux
    val fg: Color get() = inner.fg
    val bg: Color get() = inner.bg

    var onEvicted: ((handle: Long) -> Unit)?
        get() = inner.onEvicted
        set(value) { inner.onEvicted = value }

    var onTopologyChanged: ((cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) -> Unit)?
        get() = inner.onTopologyChanged
        set(value) { inner.onTopologyChanged = value }

    var onVisibilityChanged: ((placementId: Long, visible: Boolean) -> Unit)?
        get() = inner.onVisibilityChanged
        set(value) { inner.onVisibilityChanged = value }

    var onThemeChanged: ((fg: Color, bg: Color) -> Unit)?
        get() = inner.onThemeChanged
        set(value) { inner.onThemeChanged = value }

    fun upload(data: ByteArray, format: String, width: Int, height: Int): Long =
        runBlocking { inner.upload(data, format, width, height) }

    fun place(handle: Long, anchor: Anchor, width: Int, height: Int, opts: PlaceOpts = PlaceOpts()): Long =
        runBlocking { inner.place(handle, anchor, width, height, opts) }

    fun unplace(placementId: Long): Unit =
        runBlocking { inner.unplace(placementId) }

    fun unplaceAll(): Unit =
        runBlocking { inner.unplaceAll() }

    fun free(handle: Long): Unit =
        runBlocking { inner.free(handle) }

    fun registerWin(winId: Int, paneId: String = "", top: Int = 0, left: Int = 0,
                    width: Int = 0, height: Int = 0, scrollTop: Int = 0): Unit =
        runBlocking { inner.registerWin(winId, paneId, top, left, width, height, scrollTop) }

    fun updateScroll(winId: Int, scrollTop: Int): Unit =
        runBlocking { inner.updateScroll(winId, scrollTop) }

    fun unregisterWin(winId: Int): Unit =
        runBlocking { inner.unregisterWin(winId) }

    fun list(): List<PlacementInfo> =
        runBlocking { inner.list() }

    fun status(): StatusResult =
        runBlocking { inner.status() }

    fun stop(): Unit =
        runBlocking { inner.stop() }

    fun close() = inner.close()

    companion object {
        /**
         * Connect to the kgd daemon (blocking).
         */
        fun connect(opts: Options = Options()): KgdClientBlocking =
            runBlocking {
                KgdClientBlocking(KgdClient.connect(opts))
            }
    }
}
