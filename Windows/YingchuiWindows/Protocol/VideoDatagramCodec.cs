using System.Buffers.Binary;

namespace YingchuiWindows.Protocol;

public readonly record struct VideoFragment(
    Guid StreamID,
    uint FrameID,
    ushort FragmentIndex,
    ushort FragmentCount,
    ulong PresentationTimeMicroseconds,
    bool IsKeyFrame,
    byte[] Payload);

public readonly record struct CompletedVideoFrame(
    Guid StreamID,
    uint FrameID,
    ulong PresentationTimeMicroseconds,
    bool IsKeyFrame,
    byte[] AccessUnit);

public static class VideoDatagramCodec
{
    public const int MaximumDatagramSize = 1200;
    public const int HeaderSize = 42;
    private const uint Magic = 0x59435631;

    public static VideoFragment Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length < HeaderSize) throw new InvalidDataException("Video datagram is too short.");
        if (BinaryPrimitives.ReadUInt32BigEndian(data) != Magic) throw new InvalidDataException("Invalid video magic.");
        if (data[4] != 1 || BinaryPrimitives.ReadUInt16BigEndian(data[6..]) != HeaderSize)
            throw new InvalidDataException("Unsupported video datagram version.");

        var uuidBytes = data.Slice(8, 16).ToArray();
        if (BitConverter.IsLittleEndian)
        {
            Array.Reverse(uuidBytes, 0, 4);
            Array.Reverse(uuidBytes, 4, 2);
            Array.Reverse(uuidBytes, 6, 2);
        }
        var fragmentIndex = BinaryPrimitives.ReadUInt16BigEndian(data[28..]);
        var fragmentCount = BinaryPrimitives.ReadUInt16BigEndian(data[30..]);
        var payloadLength = BinaryPrimitives.ReadUInt16BigEndian(data[40..]);
        if (fragmentCount == 0 || fragmentIndex >= fragmentCount || payloadLength != data.Length - HeaderSize)
            throw new InvalidDataException("Invalid video fragment header.");

        return new VideoFragment(
            new Guid(uuidBytes),
            BinaryPrimitives.ReadUInt32BigEndian(data[24..]),
            fragmentIndex,
            fragmentCount,
            BinaryPrimitives.ReadUInt64BigEndian(data[32..]),
            (data[5] & 1) == 1,
            data[HeaderSize..].ToArray());
    }
}

public sealed class VideoFrameReassembler
{
    private sealed class Assembly(VideoFragment first)
    {
        public VideoFragment First { get; } = first;
        public byte[]?[] Fragments { get; } = new byte[first.FragmentCount][];
        public int Received { get; set; }
    }

    private readonly Dictionary<uint, Assembly> _assemblies = [];

    public CompletedVideoFrame? Append(VideoFragment fragment)
    {
        if (!_assemblies.TryGetValue(fragment.FrameID, out var assembly))
        {
            if (_assemblies.Count >= 8) _assemblies.Remove(_assemblies.Keys.Min());
            assembly = new Assembly(fragment);
            _assemblies[fragment.FrameID] = assembly;
        }
        if (assembly.First.StreamID != fragment.StreamID || assembly.Fragments.Length != fragment.FragmentCount)
        {
            _assemblies.Remove(fragment.FrameID);
            return null;
        }
        if (assembly.Fragments[fragment.FragmentIndex] is null)
        {
            assembly.Fragments[fragment.FragmentIndex] = fragment.Payload;
            assembly.Received++;
        }
        if (assembly.Received != assembly.Fragments.Length) return null;

        var total = assembly.Fragments.Sum(part => part!.Length);
        var accessUnit = new byte[total];
        var offset = 0;
        foreach (var part in assembly.Fragments)
        {
            part!.CopyTo(accessUnit, offset);
            offset += part.Length;
        }
        _assemblies.Remove(fragment.FrameID);
        return new CompletedVideoFrame(
            fragment.StreamID,
            fragment.FrameID,
            fragment.PresentationTimeMicroseconds,
            fragment.IsKeyFrame,
            accessUnit);
    }

    public void Reset() => _assemblies.Clear();
}
