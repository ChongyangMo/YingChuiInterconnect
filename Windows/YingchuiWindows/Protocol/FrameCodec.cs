using System.Buffers.Binary;
using System.Text.Json;

namespace YingchuiWindows.Protocol;

public static class FrameCodec
{
    private const int MaximumPayload = 4 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static async Task WriteAsync(Stream stream, WireMessage message, CancellationToken cancellationToken)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
        if (payload.Length is <= 0 or > MaximumPayload) throw new InvalidDataException("Invalid control frame size.");
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)payload.Length);
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    public static async Task<WireMessage> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[4];
        await stream.ReadExactlyAsync(header, cancellationToken);
        var size = checked((int)BinaryPrimitives.ReadUInt32BigEndian(header));
        if (size is <= 0 or > MaximumPayload) throw new InvalidDataException("Invalid control frame size.");
        var payload = new byte[size];
        await stream.ReadExactlyAsync(payload, cancellationToken);
        return JsonSerializer.Deserialize<WireMessage>(payload, JsonOptions)
               ?? throw new InvalidDataException("Invalid control message.");
    }
}
