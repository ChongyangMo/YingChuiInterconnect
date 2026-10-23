using System.Text.Json.Serialization;

namespace YingchuiWindows.Protocol;

public sealed record WireMessage
{
    [JsonPropertyName("version")] public int Version { get; init; } = 3;
    [JsonPropertyName("id")] public Guid Id { get; init; } = Guid.NewGuid();
    [JsonPropertyName("kind")] public required string Kind { get; init; }
    [JsonPropertyName("sentAtMilliseconds")] public ulong SentAtMilliseconds { get; init; } = (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    [JsonPropertyName("deviceName")] public string? DeviceName { get; init; }
    [JsonPropertyName("deviceID")] public string? DeviceID { get; init; }
    [JsonPropertyName("pairingCode")] public string? PairingCode { get; init; }
    [JsonPropertyName("accepted")] public bool? Accepted { get; init; }
    [JsonPropertyName("deltaX")] public double? DeltaX { get; init; }
    [JsonPropertyName("deltaY")] public double? DeltaY { get; init; }
    [JsonPropertyName("button")] public string? Button { get; init; }
    [JsonPropertyName("pressed")] public bool? Pressed { get; init; }
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("detail")] public string? Detail { get; init; }
    [JsonPropertyName("videoPort")] public int? VideoPort { get; init; }
    [JsonPropertyName("streamID")] public Guid? StreamID { get; init; }
    [JsonPropertyName("codec")] public string? Codec { get; init; }
    [JsonPropertyName("width")] public int? Width { get; init; }
    [JsonPropertyName("height")] public int? Height { get; init; }
    [JsonPropertyName("frameRate")] public int? FrameRate { get; init; }
    [JsonPropertyName("bitRate")] public int? BitRate { get; init; }
    [JsonPropertyName("parameterSets")] public string[]? ParameterSets { get; init; }
    [JsonPropertyName("packetsReceived")] public ulong? PacketsReceived { get; init; }
    [JsonPropertyName("framesDecoded")] public ulong? FramesDecoded { get; init; }
    [JsonPropertyName("framesDropped")] public ulong? FramesDropped { get; init; }
    [JsonPropertyName("sessionToken")] public string? SessionToken { get; init; }
}
