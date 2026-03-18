using System.Diagnostics;
using System.Net.Sockets;

namespace Kgd;

/// <summary>
/// Connection to the kgd (Kitty Graphics Daemon).
/// </summary>
/// <example>
/// <code>
/// await using var client = await KgdClient.ConnectAsync(new Options(ClientType: "myapp"));
/// var handle = await client.UploadAsync(imageData, "png", width, height);
/// var pid = await client.PlaceAsync(handle, new Anchor(Row: 5, Col: 10), 20, 15);
/// await client.UnplaceAsync(pid);
/// await client.FreeAsync(handle);
/// </code>
/// </example>
public sealed class KgdClient : IDisposable, IAsyncDisposable
{
    private readonly Socket _socket;
    private readonly NetworkStream _stream;
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _readerTask;

    private readonly object _pendingLock = new();
    private int _nextId;
    private readonly Dictionary<int, TaskCompletionSource<(object? Error, object? Result)>> _pending = new();

    // --- Hello result ---

    /// <summary>Client ID assigned by the daemon.</summary>
    public string ClientId { get; private set; } = "";

    /// <summary>Terminal columns.</summary>
    public int Cols { get; private set; }

    /// <summary>Terminal rows.</summary>
    public int Rows { get; private set; }

    /// <summary>Cell width in pixels.</summary>
    public int CellWidth { get; private set; }

    /// <summary>Cell height in pixels.</summary>
    public int CellHeight { get; private set; }

    /// <summary>Whether the terminal is inside tmux.</summary>
    public bool InTmux { get; private set; }

    /// <summary>Terminal foreground color.</summary>
    public Color Fg { get; private set; } = new();

    /// <summary>Terminal background color.</summary>
    public Color Bg { get; private set; } = new();

    // --- Notification events ---

    /// <summary>Raised when an uploaded image is evicted from the cache. Parameter is the handle.</summary>
    public event Action<int>? Evicted;

    /// <summary>Raised when terminal topology changes. Parameters: cols, rows, cell_width, cell_height.</summary>
    public event Action<int, int, int, int>? TopologyChanged;

    /// <summary>Raised when placement visibility changes. Parameters: placement_id, visible.</summary>
    public event Action<int, bool>? VisibilityChanged;

    /// <summary>Raised when terminal theme changes. Parameters: fg, bg.</summary>
    public event Action<Color, Color>? ThemeChanged;

    private KgdClient(Socket socket)
    {
        _socket = socket;
        _stream = new NetworkStream(socket, ownsSocket: false);
        _readerTask = Task.Run(ReadLoopAsync);
    }

    /// <summary>
    /// Connect to the kgd daemon, perform the hello handshake, and return a ready client.
    /// </summary>
    public static async Task<KgdClient> ConnectAsync(Options? options = null, CancellationToken cancellationToken = default)
    {
        options ??= new Options();

        var socketPath = ResolveSocketPath(options.SocketPath);

        if (options.AutoLaunch)
            await EnsureDaemonAsync(socketPath, cancellationToken);

        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        try
        {
            var endpoint = new UnixDomainSocketEndPoint(socketPath);
            await socket.ConnectAsync(endpoint, cancellationToken);
        }
        catch
        {
            socket.Dispose();
            throw;
        }

        var client = new KgdClient(socket);
        try
        {
            await client.HelloAsync(options, cancellationToken);
        }
        catch
        {
            client.Dispose();
            throw;
        }

        return client;
    }

    // --- Public RPC methods ---

    /// <summary>
    /// Upload image data and return a handle.
    /// </summary>
    public async Task<int> UploadAsync(byte[] data, string format, int width, int height, CancellationToken cancellationToken = default)
    {
        var result = await CallAsync("upload", new Dictionary<string, object>
        {
            ["data"] = data,
            ["format"] = format,
            ["width"] = width,
            ["height"] = height,
        }, cancellationToken: cancellationToken);

        var dict = Protocol.ToDictionary(result);
        if (dict != null)
            return Protocol.ConvertToInt(dict.GetValueOrDefault("handle"));
        throw new InvalidOperationException($"Unexpected upload result: {result}");
    }

    /// <summary>
    /// Place an image and return a placement ID.
    /// </summary>
    public async Task<int> PlaceAsync(int handle, Anchor anchor, int width, int height, PlaceOpts? opts = null, CancellationToken cancellationToken = default)
    {
        var parameters = new Dictionary<string, object>
        {
            ["handle"] = handle,
            ["anchor"] = anchor.ToDict(),
            ["width"] = width,
            ["height"] = height,
        };

        if (opts != null)
        {
            if (opts.SrcX != 0) parameters["src_x"] = opts.SrcX;
            if (opts.SrcY != 0) parameters["src_y"] = opts.SrcY;
            if (opts.SrcW != 0) parameters["src_w"] = opts.SrcW;
            if (opts.SrcH != 0) parameters["src_h"] = opts.SrcH;
            if (opts.ZIndex != 0) parameters["z_index"] = opts.ZIndex;
        }

        var result = await CallAsync("place", parameters, cancellationToken: cancellationToken);
        var dict = Protocol.ToDictionary(result);
        if (dict != null)
            return Protocol.ConvertToInt(dict.GetValueOrDefault("placement_id"));
        throw new InvalidOperationException($"Unexpected place result: {result}");
    }

    /// <summary>
    /// Remove a placement by ID.
    /// </summary>
    public async Task UnplaceAsync(int placementId, CancellationToken cancellationToken = default)
    {
        await CallAsync("unplace", new Dictionary<string, object>
        {
            ["placement_id"] = placementId,
        }, cancellationToken: cancellationToken);
    }

    /// <summary>
    /// Remove all placements for this client (fire-and-forget notification).
    /// </summary>
    public async Task UnplaceAllAsync(CancellationToken cancellationToken = default)
    {
        await NotifyAsync("unplace_all", null, cancellationToken);
    }

    /// <summary>
    /// Release an uploaded image handle.
    /// </summary>
    public async Task FreeAsync(int handle, CancellationToken cancellationToken = default)
    {
        await CallAsync("free", new Dictionary<string, object>
        {
            ["handle"] = handle,
        }, cancellationToken: cancellationToken);
    }

    /// <summary>
    /// Register a neovim window geometry (fire-and-forget notification).
    /// </summary>
    public async Task RegisterWinAsync(int winId, string paneId = "", int top = 0, int left = 0,
        int width = 0, int height = 0, int scrollTop = 0, CancellationToken cancellationToken = default)
    {
        await NotifyAsync("register_win", new Dictionary<string, object>
        {
            ["win_id"] = winId,
            ["pane_id"] = paneId,
            ["top"] = top,
            ["left"] = left,
            ["width"] = width,
            ["height"] = height,
            ["scroll_top"] = scrollTop,
        }, cancellationToken);
    }

    /// <summary>
    /// Update scroll position for a registered window (fire-and-forget notification).
    /// </summary>
    public async Task UpdateScrollAsync(int winId, int scrollTop, CancellationToken cancellationToken = default)
    {
        await NotifyAsync("update_scroll", new Dictionary<string, object>
        {
            ["win_id"] = winId,
            ["scroll_top"] = scrollTop,
        }, cancellationToken);
    }

    /// <summary>
    /// Unregister a neovim window (fire-and-forget notification).
    /// </summary>
    public async Task UnregisterWinAsync(int winId, CancellationToken cancellationToken = default)
    {
        await NotifyAsync("unregister_win", new Dictionary<string, object>
        {
            ["win_id"] = winId,
        }, cancellationToken);
    }

    /// <summary>
    /// Return all active placements.
    /// </summary>
    public async Task<List<PlacementInfo>> ListAsync(CancellationToken cancellationToken = default)
    {
        var result = await CallAsync("list", null, cancellationToken: cancellationToken);
        var dict = Protocol.ToDictionary(result);
        if (dict == null)
            return [];

        var placements = new List<PlacementInfo>();
        if (dict.GetValueOrDefault("placements") is object?[] arr)
        {
            foreach (var item in arr)
            {
                var p = Protocol.ToDictionary(item);
                if (p != null)
                {
                    placements.Add(new PlacementInfo(
                        PlacementId: Protocol.ConvertToInt(p.GetValueOrDefault("placement_id")),
                        ClientId: p.GetValueOrDefault("client_id")?.ToString() ?? "",
                        Handle: Protocol.ConvertToInt(p.GetValueOrDefault("handle")),
                        Visible: Protocol.ConvertToBool(p.GetValueOrDefault("visible")),
                        Row: Protocol.ConvertToInt(p.GetValueOrDefault("row")),
                        Col: Protocol.ConvertToInt(p.GetValueOrDefault("col"))
                    ));
                }
            }
        }

        return placements;
    }

    /// <summary>
    /// Return daemon status information.
    /// </summary>
    public async Task<StatusResult> StatusAsync(CancellationToken cancellationToken = default)
    {
        var result = await CallAsync("status", null, cancellationToken: cancellationToken);
        var dict = Protocol.ToDictionary(result);
        if (dict == null)
            return new StatusResult();

        return new StatusResult(
            Clients: Protocol.ConvertToInt(dict.GetValueOrDefault("clients")),
            Placements: Protocol.ConvertToInt(dict.GetValueOrDefault("placements")),
            Images: Protocol.ConvertToInt(dict.GetValueOrDefault("images")),
            Cols: Protocol.ConvertToInt(dict.GetValueOrDefault("cols")),
            Rows: Protocol.ConvertToInt(dict.GetValueOrDefault("rows"))
        );
    }

    /// <summary>
    /// Request the daemon to shut down (fire-and-forget notification).
    /// </summary>
    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await NotifyAsync("stop", null, cancellationToken);
    }

    // --- Dispose ---

    public void Dispose()
    {
        _cts.Cancel();
        _stream.Dispose();
        _socket.Dispose();
        _writeLock.Dispose();
        _cts.Dispose();
        WakeAllPending();
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        try
        {
            await _readerTask.ConfigureAwait(false);
        }
        catch
        {
            // reader may throw on cancellation
        }
        await _stream.DisposeAsync();
        _socket.Dispose();
        _writeLock.Dispose();
        _cts.Dispose();
        WakeAllPending();
    }

    // --- Internal ---

    private async Task HelloAsync(Options options, CancellationToken cancellationToken)
    {
        var parameters = new Dictionary<string, object>
        {
            ["client_type"] = options.ClientType,
            ["pid"] = Environment.ProcessId,
            ["label"] = options.Label,
        };
        if (!string.IsNullOrEmpty(options.SessionId))
            parameters["session_id"] = options.SessionId;

        var result = await CallAsync("hello", parameters, cancellationToken: cancellationToken);
        var dict = Protocol.ToDictionary(result);
        if (dict == null)
            return;

        ClientId = dict.GetValueOrDefault("client_id")?.ToString() ?? "";
        Cols = Protocol.ConvertToInt(dict.GetValueOrDefault("cols"));
        Rows = Protocol.ConvertToInt(dict.GetValueOrDefault("rows"));
        CellWidth = Protocol.ConvertToInt(dict.GetValueOrDefault("cell_width"));
        CellHeight = Protocol.ConvertToInt(dict.GetValueOrDefault("cell_height"));
        InTmux = Protocol.ConvertToBool(dict.GetValueOrDefault("in_tmux"));

        if (dict.ContainsKey("fg"))
            Fg = Protocol.ParseColor(dict["fg"]);
        if (dict.ContainsKey("bg"))
            Bg = Protocol.ParseColor(dict["bg"]);
    }

    private async Task<object?> CallAsync(string method, Dictionary<string, object>? parameters,
        TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        timeout ??= TimeSpan.FromSeconds(10);

        int msgId;
        var tcs = new TaskCompletionSource<(object? Error, object? Result)>(TaskCreationOptions.RunContinuationsAsynchronously);

        lock (_pendingLock)
        {
            msgId = _nextId++;
            _pending[msgId] = tcs;
        }

        try
        {
            var data = Protocol.EncodeRequest(msgId, method, parameters);
            await SendAsync(data, cancellationToken);

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _cts.Token);
            timeoutCts.CancelAfter(timeout.Value);

            try
            {
                var (error, result) = await tcs.Task.WaitAsync(timeoutCts.Token);

                if (error is not null)
                {
                    var errDict = Protocol.ToDictionary(error);
                    if (errDict != null && errDict.TryGetValue("message", out var msg))
                        throw new InvalidOperationException(msg?.ToString() ?? "RPC error");
                    throw new InvalidOperationException($"RPC error: {error}");
                }

                return result;
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && !_cts.IsCancellationRequested)
            {
                throw new TimeoutException($"RPC call {method} timed out");
            }
        }
        finally
        {
            lock (_pendingLock)
            {
                _pending.Remove(msgId);
            }
        }
    }

    private async Task NotifyAsync(string method, Dictionary<string, object>? parameters, CancellationToken cancellationToken = default)
    {
        var data = Protocol.EncodeNotification(method, parameters);
        await SendAsync(data, cancellationToken);
    }

    private async Task SendAsync(byte[] data, CancellationToken cancellationToken)
    {
        await _writeLock.WaitAsync(cancellationToken);
        try
        {
            await _stream.WriteAsync(data, cancellationToken);
            await _stream.FlushAsync(cancellationToken);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    private async Task ReadLoopAsync()
    {
        var buffer = new byte[65536];
        var accumulated = new MemoryStream();

        try
        {
            while (!_cts.IsCancellationRequested)
            {
                int bytesRead;
                try
                {
                    bytesRead = await _stream.ReadAsync(buffer, _cts.Token);
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                if (bytesRead == 0)
                    break;

                accumulated.Write(buffer, 0, bytesRead);

                // Try to decode messages from the accumulated buffer
                var accBytes = accumulated.ToArray();
                var offset = 0;

                while (offset < accBytes.Length)
                {
                    var consumed = Protocol.TryDecode(accBytes.AsMemory(offset), out var message);
                    if (consumed == 0)
                        break;

                    offset += consumed;
                    ProcessMessage(message);
                }

                // Keep any unconsumed bytes
                if (offset > 0)
                {
                    var remaining = accBytes.Length - offset;
                    accumulated.SetLength(0);
                    if (remaining > 0)
                        accumulated.Write(accBytes, offset, remaining);
                }
            }
        }
        catch (IOException)
        {
            // Socket closed
        }
        catch (ObjectDisposedException)
        {
            // Socket disposed
        }
        finally
        {
            WakeAllPending();
        }
    }

    private void ProcessMessage(object? message)
    {
        var response = Protocol.ParseResponse(message);
        if (response != null)
        {
            HandleResponse(response.Value.MsgId, response.Value.Error, response.Value.Result);
            return;
        }

        var notification = Protocol.ParseNotification(message);
        if (notification != null)
        {
            HandleNotification(notification.Value.Method, notification.Value.Params);
        }
    }

    private void HandleResponse(int msgId, object? error, object? result)
    {
        TaskCompletionSource<(object? Error, object? Result)>? tcs;
        lock (_pendingLock)
        {
            _pending.TryGetValue(msgId, out tcs);
        }

        tcs?.TrySetResult((error, result));
    }

    private void HandleNotification(string method, Dictionary<string, object?>? parameters)
    {
        if (parameters == null)
            return;

        switch (method)
        {
            case "evicted":
                Evicted?.Invoke(Protocol.ConvertToInt(parameters.GetValueOrDefault("handle")));
                break;

            case "topology_changed":
                TopologyChanged?.Invoke(
                    Protocol.ConvertToInt(parameters.GetValueOrDefault("cols")),
                    Protocol.ConvertToInt(parameters.GetValueOrDefault("rows")),
                    Protocol.ConvertToInt(parameters.GetValueOrDefault("cell_width")),
                    Protocol.ConvertToInt(parameters.GetValueOrDefault("cell_height"))
                );
                break;

            case "visibility_changed":
                VisibilityChanged?.Invoke(
                    Protocol.ConvertToInt(parameters.GetValueOrDefault("placement_id")),
                    Protocol.ConvertToBool(parameters.GetValueOrDefault("visible"))
                );
                break;

            case "theme_changed":
                var fg = parameters.ContainsKey("fg") ? Protocol.ParseColor(parameters["fg"]) : new Color();
                var bg = parameters.ContainsKey("bg") ? Protocol.ParseColor(parameters["bg"]) : new Color();
                ThemeChanged?.Invoke(fg, bg);
                break;
        }
    }

    private void WakeAllPending()
    {
        List<TaskCompletionSource<(object? Error, object? Result)>> pending;
        lock (_pendingLock)
        {
            pending = [.. _pending.Values];
            _pending.Clear();
        }

        foreach (var tcs in pending)
            tcs.TrySetCanceled();
    }

    // --- Static helpers ---

    internal static string ResolveSocketPath(string configuredPath = "")
    {
        if (!string.IsNullOrEmpty(configuredPath))
            return configuredPath;

        var envSocket = Environment.GetEnvironmentVariable("KGD_SOCKET");
        if (!string.IsNullOrEmpty(envSocket))
            return envSocket;

        var runtimeDir = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        if (string.IsNullOrEmpty(runtimeDir))
            runtimeDir = Path.GetTempPath();

        var kittyId = Environment.GetEnvironmentVariable("KITTY_WINDOW_ID") ?? "default";
        return Path.Combine(runtimeDir, $"kgd-{kittyId}.sock");
    }

    private static async Task EnsureDaemonAsync(string socketPath, CancellationToken cancellationToken)
    {
        // Try connecting first
        try
        {
            using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            await probe.ConnectAsync(new UnixDomainSocketEndPoint(socketPath), cancellationToken);
            return; // Daemon is already running
        }
        catch (SocketException)
        {
            // Not running, proceed to launch
        }

        // Find kgd binary
        var kgdPath = FindInPath("kgd");
        if (kgdPath == null)
            throw new FileNotFoundException("kgd not found in PATH");

        // Launch daemon
        var psi = new ProcessStartInfo
        {
            FileName = kgdPath,
            ArgumentList = { "serve", "--socket", socketPath },
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        var process = Process.Start(psi);
        if (process == null)
            throw new InvalidOperationException("Failed to start kgd daemon");

        // Wait for daemon to be ready (up to 5 seconds)
        for (var i = 0; i < 50; i++)
        {
            await Task.Delay(100, cancellationToken);
            try
            {
                using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                await probe.ConnectAsync(new UnixDomainSocketEndPoint(socketPath), cancellationToken);
                return;
            }
            catch (SocketException)
            {
                // Not ready yet
            }
        }

        throw new TimeoutException("Timed out waiting for kgd daemon to start");
    }

    private static string? FindInPath(string executable)
    {
        var pathVar = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathVar))
            return null;

        var separator = OperatingSystem.IsWindows() ? ';' : ':';
        foreach (var dir in pathVar.Split(separator))
        {
            var candidate = Path.Combine(dir, executable);
            if (File.Exists(candidate))
                return candidate;
        }

        return null;
    }
}
