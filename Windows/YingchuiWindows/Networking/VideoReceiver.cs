using System.Net;
using System.Net.Sockets;
using YingchuiWindows.Protocol;

namespace YingchuiWindows.Networking;

public sealed class VideoReceiver : IAsyncDisposable
{
    public event Action<CompletedVideoFrame>? FrameCompleted;
    public event Action<ulong, ulong, ulong>? StatisticsChanged;

    private readonly VideoFrameReassembler _reassembler = new();
    private UdpClient? _udp;
    private CancellationTokenSource? _lifetime;
    private Task? _receiveTask;
    private uint? _lastFrameID;

    public int Port { get; private set; }
    public Guid? StreamID { get; set; }
    public ulong PacketsReceived { get; private set; }
    public ulong FramesCompleted { get; private set; }
    public ulong FramesDropped { get; private set; }

    public void Start()
    {
        Stop();
        _udp = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        Port = ((IPEndPoint)_udp.Client.LocalEndPoint!).Port;
        _lifetime = new CancellationTokenSource();
        _receiveTask = ReceiveLoopAsync(_lifetime.Token);
    }

    public void Stop()
    {
        _lifetime?.Cancel();
        _lifetime?.Dispose();
        _lifetime = null;
        _udp?.Dispose();
        _udp = null;
        _reassembler.Reset();
        StreamID = null;
        _lastFrameID = null;
        PacketsReceived = FramesCompleted = FramesDropped = 0;
        Port = 0;
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var packet = await _udp!.ReceiveAsync(cancellationToken);
                var fragment = VideoDatagramCodec.Decode(packet.Buffer);
                if (StreamID is not null && fragment.StreamID != StreamID) continue;
                PacketsReceived++;
                var frame = _reassembler.Append(fragment);
                if (frame is not null)
                {
                    if (_lastFrameID is uint previous && frame.Value.FrameID > previous + 1)
                        FramesDropped += frame.Value.FrameID - previous - 1;
                    _lastFrameID = frame.Value.FrameID;
                    FramesCompleted++;
                    FrameCompleted?.Invoke(frame.Value);
                }
                if (PacketsReceived % 240 == 0)
                    StatisticsChanged?.Invoke(PacketsReceived, FramesCompleted, FramesDropped);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception)
        {
            FramesDropped++;
            StatisticsChanged?.Invoke(PacketsReceived, FramesCompleted, FramesDropped);
        }
    }

    public ValueTask DisposeAsync()
    {
        Stop();
        return ValueTask.CompletedTask;
    }
}
