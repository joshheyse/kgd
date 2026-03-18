using System.Buffers;
using MessagePack;

namespace Kgd;

/// <summary>
/// msgpack-RPC message type constants.
/// </summary>
internal static class MsgType
{
    public const int Request = 0;
    public const int Response = 1;
    public const int Notification = 2;
}

/// <summary>
/// Handles encoding and decoding of msgpack-RPC messages.
/// </summary>
internal static class Protocol
{
    private static readonly MessagePackSerializerOptions SerializerOptions =
        MessagePackSerializerOptions.Standard.WithSecurity(MessagePackSecurity.UntrustedData);

    /// <summary>
    /// Encode a request: [0, msgid, method, [params]]
    /// </summary>
    public static byte[] EncodeRequest(int msgId, string method, Dictionary<string, object>? parameters)
    {
        var writer = new ArrayBufferWriter();
        var msgpackWriter = new MessagePackWriter(writer);

        msgpackWriter.WriteArrayHeader(4);
        msgpackWriter.Write(MsgType.Request);
        msgpackWriter.Write(msgId);
        msgpackWriter.Write(method);

        if (parameters != null)
        {
            // params array with single dict element
            msgpackWriter.WriteArrayHeader(1);
            WriteDict(ref msgpackWriter, parameters);
        }
        else
        {
            msgpackWriter.WriteArrayHeader(0);
        }

        msgpackWriter.Flush();
        return writer.WrittenSpan.ToArray();
    }

    /// <summary>
    /// Encode a notification: [2, method, [params]]
    /// </summary>
    public static byte[] EncodeNotification(string method, Dictionary<string, object>? parameters)
    {
        var writer = new ArrayBufferWriter();
        var msgpackWriter = new MessagePackWriter(writer);

        msgpackWriter.WriteArrayHeader(3);
        msgpackWriter.Write(MsgType.Notification);
        msgpackWriter.Write(method);

        if (parameters != null)
        {
            msgpackWriter.WriteArrayHeader(1);
            WriteDict(ref msgpackWriter, parameters);
        }
        else
        {
            msgpackWriter.WriteArrayHeader(0);
        }

        msgpackWriter.Flush();
        return writer.WrittenSpan.ToArray();
    }

    /// <summary>
    /// Decode a single message from a ReadOnlyMemory buffer. Returns the number of bytes consumed,
    /// or 0 if there isn't enough data for a complete message.
    /// </summary>
    public static int TryDecode(ReadOnlyMemory<byte> buffer, out object? message)
    {
        message = null;
        if (buffer.Length == 0)
            return 0;

        try
        {
            var reader = new MessagePackReader(buffer);

            // Peek to see if we have a complete message
            var startPosition = reader.Position;
            reader.Skip(); // try to skip one complete msgpack object
            var bytesConsumed = (int)reader.Consumed;

            // Now actually decode it
            message = MessagePackSerializer.Deserialize<object>(buffer[..bytesConsumed], SerializerOptions);
            return bytesConsumed;
        }
        catch (EndOfStreamException)
        {
            return 0;
        }
        catch (MessagePackSerializationException ex) when (ex.InnerException is EndOfStreamException)
        {
            return 0;
        }
    }

    /// <summary>
    /// Parse a decoded msgpack object into a structured response (msg_type=1).
    /// Returns (msgId, error, result) or null if not a valid response.
    /// </summary>
    public static (int MsgId, object? Error, object? Result)? ParseResponse(object? message)
    {
        if (message is not object?[] arr || arr.Length < 4)
            return null;

        var msgType = ConvertToInt(arr[0]);
        if (msgType != MsgType.Response)
            return null;

        var msgId = ConvertToInt(arr[1]);
        return (msgId, arr[2], arr[3]);
    }

    /// <summary>
    /// Parse a decoded msgpack object into a notification (msg_type=2).
    /// Returns (method, params_dict) or null if not a valid notification.
    /// </summary>
    public static (string Method, Dictionary<string, object?>? Params)? ParseNotification(object? message)
    {
        if (message is not object?[] arr || arr.Length < 3)
            return null;

        var msgType = ConvertToInt(arr[0]);
        if (msgType != MsgType.Notification)
            return null;

        var method = arr[1]?.ToString() ?? "";
        Dictionary<string, object?>? parameters = null;

        if (arr[2] is object?[] paramsArr && paramsArr.Length > 0)
        {
            parameters = ToDictionary(paramsArr[0]);
        }

        return (method, parameters);
    }

    /// <summary>
    /// Convert a deserialized msgpack result to a string-keyed dictionary.
    /// </summary>
    public static Dictionary<string, object?>? ToDictionary(object? obj)
    {
        if (obj is Dictionary<object, object> rawDict)
        {
            var result = new Dictionary<string, object?>();
            foreach (var kvp in rawDict)
                result[kvp.Key?.ToString() ?? ""] = kvp.Value;
            return result;
        }
        return null;
    }

    /// <summary>
    /// Convert a deserialized value to int, handling various numeric types from msgpack.
    /// </summary>
    public static int ConvertToInt(object? value)
    {
        return value switch
        {
            byte b => b,
            sbyte sb => sb,
            short s => s,
            ushort us => us,
            int i => i,
            uint u => (int)u,
            long l => (int)l,
            ulong ul => (int)ul,
            _ => 0,
        };
    }

    /// <summary>
    /// Convert a deserialized value to bool.
    /// </summary>
    public static bool ConvertToBool(object? value)
    {
        return value switch
        {
            bool b => b,
            _ => false,
        };
    }

    /// <summary>
    /// Extract a Color from a dictionary value.
    /// </summary>
    public static Color ParseColor(object? value)
    {
        var dict = ToDictionary(value);
        if (dict == null)
            return new Color();
        return new Color(
            R: ConvertToInt(dict.GetValueOrDefault("r")),
            G: ConvertToInt(dict.GetValueOrDefault("g")),
            B: ConvertToInt(dict.GetValueOrDefault("b"))
        );
    }

    private static void WriteDict(ref MessagePackWriter writer, Dictionary<string, object> dict)
    {
        writer.WriteMapHeader(dict.Count);
        foreach (var kvp in dict)
        {
            writer.Write(kvp.Key);
            WriteValue(ref writer, kvp.Value);
        }
    }

    private static void WriteValue(ref MessagePackWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNil();
                break;
            case bool b:
                writer.Write(b);
                break;
            case int i:
                writer.Write(i);
                break;
            case long l:
                writer.Write(l);
                break;
            case uint u:
                writer.Write(u);
                break;
            case string s:
                writer.Write(s);
                break;
            case byte[] bytes:
                writer.Write(bytes);
                break;
            case Dictionary<string, object> nested:
                WriteDict(ref writer, nested);
                break;
            case object[] arr:
                writer.WriteArrayHeader(arr.Length);
                foreach (var item in arr)
                    WriteValue(ref writer, item);
                break;
            default:
                // Fall back to string representation
                writer.Write(value.ToString());
                break;
        }
    }
}

/// <summary>
/// Simple growable buffer for MessagePackWriter.
/// </summary>
internal sealed class ArrayBufferWriter : IBufferWriter<byte>
{
    private byte[] _buffer = new byte[256];
    private int _written;

    public ReadOnlySpan<byte> WrittenSpan => _buffer.AsSpan(0, _written);

    public void Advance(int count) => _written += count;

    public Memory<byte> GetMemory(int sizeHint = 0)
    {
        EnsureCapacity(sizeHint);
        return _buffer.AsMemory(_written);
    }

    public Span<byte> GetSpan(int sizeHint = 0)
    {
        EnsureCapacity(sizeHint);
        return _buffer.AsSpan(_written);
    }

    private void EnsureCapacity(int sizeHint)
    {
        if (sizeHint <= 0) sizeHint = 1;
        if (_written + sizeHint <= _buffer.Length) return;
        var newSize = Math.Max(_buffer.Length * 2, _written + sizeHint);
        Array.Resize(ref _buffer, newSize);
    }
}
