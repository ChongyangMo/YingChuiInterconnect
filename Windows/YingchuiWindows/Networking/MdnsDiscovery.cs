using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace YingchuiWindows.Networking;

public sealed record DiscoveredMac(string Name, string Host, int Port)
{
    public string DisplayName => $"{Name} — {Host}:{Port}";
}

public sealed class MdnsDiscovery : IAsyncDisposable
{
    public event Action<IReadOnlyList<DiscoveredMac>>? ResultsChanged;

    private const string Service = "_yingchui._tcp.local";
    private readonly Dictionary<string, (string Host, int Port)> _services = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IPAddress> _addresses = new(StringComparer.OrdinalIgnoreCase);
    private UdpClient? _udp;
    private CancellationTokenSource? _lifetime;
    private Task? _receiveTask;

    public async Task StartAsync()
    {
        await StopAsync();
        _udp = new UdpClient(AddressFamily.InterNetwork);
        _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udp.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
        _udp.JoinMulticastGroup(IPAddress.Parse("224.0.0.251"));
        _lifetime = new CancellationTokenSource();
        _receiveTask = ReceiveLoopAsync(_lifetime.Token);
        await QueryAsync(_lifetime.Token);
    }

    public async Task QueryAsync(CancellationToken cancellationToken = default)
    {
        if (_udp is null) return;
        var question = EncodeName(Service);
        var packet = new byte[12 + question.Length + 4];
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(4), 1);
        question.CopyTo(packet, 12);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(12 + question.Length), 12);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(14 + question.Length), 1);
        await _udp.SendAsync(packet, new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353), cancellationToken);
    }

    public async Task StopAsync()
    {
        _lifetime?.Cancel();
        _udp?.Dispose();
        if (_receiveTask is not null)
        {
            try { await _receiveTask; } catch (OperationCanceledException) { } catch (ObjectDisposedException) { }
        }
        _receiveTask = null;
        _lifetime?.Dispose();
        _lifetime = null;
        _udp = null;
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var response = await _udp!.ReceiveAsync(cancellationToken);
            Parse(response.Buffer);
        }
    }

    private void Parse(byte[] packet)
    {
        if (packet.Length < 12) return;
        var offset = 12;
        var questionCount = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(4));
        var recordCount = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(6))
                          + BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(8))
                          + BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(10));
        for (var index = 0; index < questionCount && offset < packet.Length; index++)
        {
            _ = ReadName(packet, ref offset);
            offset += 4;
        }
        for (var index = 0; index < recordCount && offset + 10 <= packet.Length; index++)
        {
            var name = ReadName(packet, ref offset);
            var type = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset));
            offset += 8;
            var length = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset));
            offset += 2;
            var end = offset + length;
            if (end > packet.Length) return;

            if (type == 33 && length >= 6)
            {
                var port = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset + 4));
                var targetOffset = offset + 6;
                var target = ReadName(packet, ref targetOffset);
                _services[name] = (target, port);
            }
            else if (type == 1 && length == 4)
            {
                _addresses[name] = new IPAddress(packet.AsSpan(offset, 4));
            }
            offset = end;
        }
        Publish();
    }

    private void Publish()
    {
        var results = _services
            .Where(item => item.Key.EndsWith('.' + Service, StringComparison.OrdinalIgnoreCase))
            .Select(item =>
            {
                var instanceName = item.Key[..^(Service.Length + 1)];
                var host = _addresses.TryGetValue(item.Value.Host, out var address)
                    ? address.ToString()
                    : item.Value.Host.TrimEnd('.');
                return new DiscoveredMac(instanceName, host, item.Value.Port);
            })
            .OrderBy(item => item.Name)
            .ToArray();
        if (results.Length > 0) ResultsChanged?.Invoke(results);
    }

    private static byte[] EncodeName(string name)
    {
        using var stream = new MemoryStream();
        foreach (var label in name.TrimEnd('.').Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            stream.WriteByte((byte)bytes.Length);
            stream.Write(bytes);
        }
        stream.WriteByte(0);
        return stream.ToArray();
    }

    private static string ReadName(byte[] packet, ref int offset)
    {
        var labels = new List<string>();
        var position = offset;
        var jumped = false;
        var guard = 0;
        while (position < packet.Length && guard++ < 64)
        {
            var length = packet[position++];
            if (length == 0) break;
            if ((length & 0xc0) == 0xc0)
            {
                if (position >= packet.Length) break;
                var pointer = ((length & 0x3f) << 8) | packet[position++];
                if (!jumped) offset = position;
                position = pointer;
                jumped = true;
                continue;
            }
            if (position + length > packet.Length) break;
            labels.Add(Encoding.UTF8.GetString(packet, position, length));
            position += length;
        }
        if (!jumped) offset = position;
        return string.Join('.', labels);
    }

    public async ValueTask DisposeAsync() => await StopAsync();
}
