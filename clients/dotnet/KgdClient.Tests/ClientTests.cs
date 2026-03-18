using Kgd;

namespace Kgd.Tests;

public class AnchorTests
{
    [Fact]
    public void Absolute_OnlyIncludesType()
    {
        var anchor = new Anchor(Type: "absolute");
        var dict = anchor.ToDict();

        Assert.Single(dict);
        Assert.Equal("absolute", dict["type"]);
    }

    [Fact]
    public void Absolute_WithRowCol()
    {
        var anchor = new Anchor(Type: "absolute", Row: 5, Col: 10);
        var dict = anchor.ToDict();

        Assert.Equal("absolute", dict["type"]);
        Assert.Equal(5, dict["row"]);
        Assert.Equal(10, dict["col"]);
        Assert.Equal(3, dict.Count);
    }

    [Fact]
    public void Pane_WithPaneIdRowCol()
    {
        var anchor = new Anchor(Type: "pane", PaneId: "%0", Row: 2, Col: 3);
        var dict = anchor.ToDict();

        Assert.Equal("pane", dict["type"]);
        Assert.Equal("%0", dict["pane_id"]);
        Assert.Equal(2, dict["row"]);
        Assert.Equal(3, dict["col"]);
        Assert.Equal(4, dict.Count);
    }

    [Fact]
    public void NvimWin_WithWinIdBufLine()
    {
        var anchor = new Anchor(Type: "nvim_win", WinId: 1000, BufLine: 5, Col: 0);
        var dict = anchor.ToDict();

        Assert.Equal("nvim_win", dict["type"]);
        Assert.Equal(1000, dict["win_id"]);
        Assert.Equal(5, dict["buf_line"]);
        // Col=0 should be omitted
        Assert.False(dict.ContainsKey("col"));
        Assert.Equal(3, dict.Count);
    }

    [Fact]
    public void OmitsAllZeroFields()
    {
        var anchor = new Anchor(Type: "absolute");
        var dict = anchor.ToDict();

        Assert.False(dict.ContainsKey("pane_id"));
        Assert.False(dict.ContainsKey("win_id"));
        Assert.False(dict.ContainsKey("buf_line"));
        Assert.False(dict.ContainsKey("row"));
        Assert.False(dict.ContainsKey("col"));
    }
}

public class ColorTests
{
    [Fact]
    public void Defaults_AreZero()
    {
        var color = new Color();
        Assert.Equal(0, color.R);
        Assert.Equal(0, color.G);
        Assert.Equal(0, color.B);
    }

    [Fact]
    public void Values_ArePreserved()
    {
        var color = new Color(R: 65535, G: 32768, B: 0);
        Assert.Equal(65535, color.R);
        Assert.Equal(32768, color.G);
        Assert.Equal(0, color.B);
    }
}

public class PlacementInfoTests
{
    [Fact]
    public void Defaults()
    {
        var info = new PlacementInfo();
        Assert.Equal(0, info.PlacementId);
        Assert.Equal("", info.ClientId);
        Assert.Equal(0, info.Handle);
        Assert.False(info.Visible);
        Assert.Equal(0, info.Row);
        Assert.Equal(0, info.Col);
    }

    [Fact]
    public void WithValues()
    {
        var info = new PlacementInfo(PlacementId: 42, ClientId: "abc", Handle: 7, Visible: true, Row: 3, Col: 5);
        Assert.Equal(42, info.PlacementId);
        Assert.Equal("abc", info.ClientId);
        Assert.Equal(7, info.Handle);
        Assert.True(info.Visible);
        Assert.Equal(3, info.Row);
        Assert.Equal(5, info.Col);
    }
}

public class StatusResultTests
{
    [Fact]
    public void Defaults()
    {
        var status = new StatusResult();
        Assert.Equal(0, status.Clients);
        Assert.Equal(0, status.Placements);
        Assert.Equal(0, status.Images);
        Assert.Equal(0, status.Cols);
        Assert.Equal(0, status.Rows);
    }
}

public class OptionsTests
{
    [Fact]
    public void Defaults()
    {
        var opts = new Options();
        Assert.Equal("", opts.SocketPath);
        Assert.Equal("", opts.SessionId);
        Assert.Equal("", opts.ClientType);
        Assert.Equal("", opts.Label);
        Assert.True(opts.AutoLaunch);
    }
}

public class PlaceOptsTests
{
    [Fact]
    public void Defaults()
    {
        var opts = new PlaceOpts();
        Assert.Equal(0, opts.SrcX);
        Assert.Equal(0, opts.SrcY);
        Assert.Equal(0, opts.SrcW);
        Assert.Equal(0, opts.SrcH);
        Assert.Equal(0, opts.ZIndex);
    }
}

public class ProtocolTests
{
    [Fact]
    public void EncodeRequest_WithParams_RoundTrips()
    {
        var data = Protocol.EncodeRequest(1, "hello", new Dictionary<string, object>
        {
            ["client_type"] = "test",
            ["pid"] = 1234,
        });

        var consumed = Protocol.TryDecode(data, out var message);
        Assert.True(consumed > 0);
        Assert.NotNull(message);

        var arr = Assert.IsType<object?[]>(message);
        Assert.Equal(4, arr.Length);
        Assert.Equal(0, Protocol.ConvertToInt(arr[0])); // Request
        Assert.Equal(1, Protocol.ConvertToInt(arr[1])); // msgId
        Assert.Equal("hello", arr[2]?.ToString());

        // params array
        var paramsArr = Assert.IsType<object?[]>(arr[3]);
        Assert.Single(paramsArr);
    }

    [Fact]
    public void EncodeRequest_NullParams_HasEmptyArray()
    {
        var data = Protocol.EncodeRequest(0, "status", null);

        var consumed = Protocol.TryDecode(data, out var message);
        Assert.True(consumed > 0);

        var arr = Assert.IsType<object?[]>(message);
        var paramsArr = Assert.IsType<object?[]>(arr[3]);
        Assert.Empty(paramsArr);
    }

    [Fact]
    public void EncodeNotification_WithParams()
    {
        var data = Protocol.EncodeNotification("stop", null);

        var consumed = Protocol.TryDecode(data, out var message);
        Assert.True(consumed > 0);

        var arr = Assert.IsType<object?[]>(message);
        Assert.Equal(3, arr.Length);
        Assert.Equal(2, Protocol.ConvertToInt(arr[0])); // Notification
        Assert.Equal("stop", arr[1]?.ToString());
    }

    [Fact]
    public void TryDecode_IncompleteData_ReturnsZero()
    {
        var data = new byte[] { 0x94 }; // start of a 4-element array but no content
        var consumed = Protocol.TryDecode(data, out var message);
        Assert.Equal(0, consumed);
        Assert.Null(message);
    }

    [Fact]
    public void TryDecode_EmptyBuffer_ReturnsZero()
    {
        var consumed = Protocol.TryDecode(ReadOnlyMemory<byte>.Empty, out var message);
        Assert.Equal(0, consumed);
        Assert.Null(message);
    }

    [Fact]
    public void ParseResponse_ValidResponse()
    {
        // Simulate a response: [1, 42, nil, {"handle": 7}]
        var data = Protocol.EncodeRequest(0, "test", null); // just to have something encodable

        // Build a mock response by hand using MessagePack
        var writer = new ArrayBufferWriter();
        var msgpackWriter = new MessagePack.MessagePackWriter(writer);
        msgpackWriter.WriteArrayHeader(4);
        msgpackWriter.Write(1); // response type
        msgpackWriter.Write(42); // msgId
        msgpackWriter.WriteNil(); // no error
        msgpackWriter.WriteMapHeader(1);
        msgpackWriter.Write("handle");
        msgpackWriter.Write(7);
        msgpackWriter.Flush();

        var consumed = Protocol.TryDecode(writer.WrittenSpan.ToArray(), out var message);
        Assert.True(consumed > 0);

        var response = Protocol.ParseResponse(message);
        Assert.NotNull(response);
        Assert.Equal(42, response.Value.MsgId);
        Assert.Null(response.Value.Error);

        var result = Protocol.ToDictionary(response.Value.Result);
        Assert.NotNull(result);
        Assert.Equal(7, Protocol.ConvertToInt(result["handle"]));
    }

    [Fact]
    public void ParseNotification_ValidNotification()
    {
        // Build a notification: [2, "evicted", [{handle: 5}]]
        var writer = new ArrayBufferWriter();
        var msgpackWriter = new MessagePack.MessagePackWriter(writer);
        msgpackWriter.WriteArrayHeader(3);
        msgpackWriter.Write(2); // notification type
        msgpackWriter.Write("evicted");
        msgpackWriter.WriteArrayHeader(1);
        msgpackWriter.WriteMapHeader(1);
        msgpackWriter.Write("handle");
        msgpackWriter.Write(5);
        msgpackWriter.Flush();

        var consumed = Protocol.TryDecode(writer.WrittenSpan.ToArray(), out var message);
        Assert.True(consumed > 0);

        var notification = Protocol.ParseNotification(message);
        Assert.NotNull(notification);
        Assert.Equal("evicted", notification.Value.Method);
        Assert.NotNull(notification.Value.Params);
        Assert.Equal(5, Protocol.ConvertToInt(notification.Value.Params["handle"]));
    }

    [Fact]
    public void ConvertToInt_HandlesVariousTypes()
    {
        Assert.Equal(42, Protocol.ConvertToInt((byte)42));
        Assert.Equal(42, Protocol.ConvertToInt((sbyte)42));
        Assert.Equal(42, Protocol.ConvertToInt((short)42));
        Assert.Equal(42, Protocol.ConvertToInt((ushort)42));
        Assert.Equal(42, Protocol.ConvertToInt(42));
        Assert.Equal(42, Protocol.ConvertToInt((uint)42));
        Assert.Equal(42, Protocol.ConvertToInt((long)42));
        Assert.Equal(42, Protocol.ConvertToInt((ulong)42));
        Assert.Equal(0, Protocol.ConvertToInt(null));
        Assert.Equal(0, Protocol.ConvertToInt("not a number"));
    }

    [Fact]
    public void ConvertToBool_HandlesTypes()
    {
        Assert.True(Protocol.ConvertToBool(true));
        Assert.False(Protocol.ConvertToBool(false));
        Assert.False(Protocol.ConvertToBool(null));
        Assert.False(Protocol.ConvertToBool(42));
    }

    [Fact]
    public void ParseColor_ValidDict()
    {
        var dict = new Dictionary<object, object>
        {
            { "r", 65535 },
            { "g", 32768 },
            { "b", 0 },
        };

        var color = Protocol.ParseColor(dict);
        Assert.Equal(65535, color.R);
        Assert.Equal(32768, color.G);
        Assert.Equal(0, color.B);
    }

    [Fact]
    public void ParseColor_Null_ReturnsDefault()
    {
        var color = Protocol.ParseColor(null);
        Assert.Equal(0, color.R);
        Assert.Equal(0, color.G);
        Assert.Equal(0, color.B);
    }
}

public class SocketPathTests
{
    [Fact]
    public void ConfiguredPath_TakesPrecedence()
    {
        var path = KgdClient.ResolveSocketPath("/custom/path.sock");
        Assert.Equal("/custom/path.sock", path);
    }

    [Fact]
    public void EmptyConfiguredPath_FallsToEnvOrDefault()
    {
        // Just verify it returns a non-empty string (actual path depends on env)
        var path = KgdClient.ResolveSocketPath("");
        Assert.False(string.IsNullOrEmpty(path));
    }
}

public class MultipleMessagesTests
{
    [Fact]
    public void TryDecode_MultipleMessages_InOneBuffer()
    {
        var msg1 = Protocol.EncodeNotification("evicted", new Dictionary<string, object> { ["handle"] = 1 });
        var msg2 = Protocol.EncodeNotification("evicted", new Dictionary<string, object> { ["handle"] = 2 });

        // Concatenate
        var combined = new byte[msg1.Length + msg2.Length];
        Buffer.BlockCopy(msg1, 0, combined, 0, msg1.Length);
        Buffer.BlockCopy(msg2, 0, combined, msg1.Length, msg2.Length);

        // Decode first message
        var consumed1 = Protocol.TryDecode(combined, out var message1);
        Assert.True(consumed1 > 0);
        Assert.NotNull(message1);

        // Decode second message from remaining bytes
        var consumed2 = Protocol.TryDecode(combined.AsMemory(consumed1), out var message2);
        Assert.True(consumed2 > 0);
        Assert.NotNull(message2);

        // Verify both are notifications
        var n1 = Protocol.ParseNotification(message1);
        var n2 = Protocol.ParseNotification(message2);
        Assert.NotNull(n1);
        Assert.NotNull(n2);
        Assert.Equal(1, Protocol.ConvertToInt(n1.Value.Params!["handle"]));
        Assert.Equal(2, Protocol.ConvertToInt(n2.Value.Params!["handle"]));
    }
}

public class RequestEncodingTests
{
    [Fact]
    public void EncodeRequest_WithBinaryData()
    {
        var imageData = new byte[] { 0x89, 0x50, 0x4E, 0x47 }; // PNG magic bytes
        var data = Protocol.EncodeRequest(5, "upload", new Dictionary<string, object>
        {
            ["data"] = imageData,
            ["format"] = "png",
            ["width"] = 100,
            ["height"] = 200,
        });

        var consumed = Protocol.TryDecode(data, out var message);
        Assert.True(consumed > 0);

        var arr = Assert.IsType<object?[]>(message);
        Assert.Equal(5, Protocol.ConvertToInt(arr[1])); // msgId
        Assert.Equal("upload", arr[2]?.ToString());
    }

    [Fact]
    public void EncodeNotification_WithParams_RoundTrips()
    {
        var data = Protocol.EncodeNotification("register_win", new Dictionary<string, object>
        {
            ["win_id"] = 42,
            ["pane_id"] = "%0",
            ["top"] = 1,
            ["left"] = 2,
            ["width"] = 80,
            ["height"] = 24,
            ["scroll_top"] = 0,
        });

        var consumed = Protocol.TryDecode(data, out var message);
        Assert.True(consumed > 0);

        var notification = Protocol.ParseNotification(message);
        Assert.NotNull(notification);
        Assert.Equal("register_win", notification.Value.Method);
        Assert.NotNull(notification.Value.Params);
        Assert.Equal(42, Protocol.ConvertToInt(notification.Value.Params["win_id"]));
        Assert.Equal("%0", notification.Value.Params["pane_id"]?.ToString());
    }
}
