using System.Net.Security;
using System.Net.Sockets;
using System.Diagnostics;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using YingchuiWindows.Protocol;

namespace YingchuiWindows.Networking;

public sealed class MacConnection : IAsyncDisposable
{
    public event Action<WireMessage>? MessageReceived;
    public event Action<string>? StatusChanged;
    public event Action<bool>? PairingChanged;

    private readonly TrustStore _trustStore = new();
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private readonly string _deviceID = LoadOrCreateDeviceID();
    private TcpClient? _tcpClient;
    private SslStream? _stream;
    private CancellationTokenSource? _lifetime;
    private string? _hostKey;
    private string? _pendingFingerprint;
    private Task? _receiveTask;
    private Task? _heartbeatTask;
    private readonly Dictionary<Guid, long> _pendingPings = [];

    public bool IsConnected => _stream is not null;
    public bool IsPaired { get; private set; }
    public double? RoundTripMilliseconds { get; private set; }

    public async Task ConnectAsync(string host, int port, string serviceName, CancellationToken cancellationToken = default)
    {
        await DisconnectAsync();
        _hostKey = serviceName;
        var trusted = _trustStore.Get(serviceName);
        _tcpClient = new TcpClient { NoDelay = true };
        await _tcpClient.ConnectAsync(host, port, cancellationToken);
        _stream = new SslStream(
            _tcpClient.GetStream(),
            leaveInnerStreamOpen: false,
            (_, certificate, _, _) => ValidateCertificate(certificate, trusted));
        await _stream.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = serviceName,
            EnabledSslProtocols = SslProtocols.Tls13,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck
        }, cancellationToken);

        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _receiveTask = ReceiveLoopAsync(_lifetime.Token);
        _heartbeatTask = HeartbeatLoopAsync(_lifetime.Token);
        await SendAsync(new WireMessage
        {
            Kind = "hello",
            DeviceName = Environment.MachineName,
            DeviceID = _deviceID,
            SessionToken = trusted?.SessionToken
        }, cancellationToken);
        StatusChanged?.Invoke("TLS 控制通道已连接");
    }

    public Task PairAsync(string code, CancellationToken cancellationToken = default) => SendAsync(new WireMessage
    {
        Kind = "pairRequest",
        DeviceName = Environment.MachineName,
        DeviceID = _deviceID,
        PairingCode = new string(code.Where(char.IsDigit).Take(6).ToArray())
    }, cancellationToken);

    public Task MovePointerAsync(double x, double y) => SendAsync(new WireMessage { Kind = "pointerMove", DeltaX = x, DeltaY = y });
    public async Task ClickAsync(string button)
    {
        await SendAsync(new WireMessage { Kind = "mouseButton", Button = button, Pressed = true });
        await SendAsync(new WireMessage { Kind = "mouseButton", Button = button, Pressed = false });
    }
    public Task ScrollAsync(double y) => SendAsync(new WireMessage { Kind = "scroll", DeltaX = 0, DeltaY = y });
    public Task SendTextAsync(string text) => SendAsync(new WireMessage { Kind = "textInput", Text = text[..Math.Min(128, text.Length)] });
    public Task StartStreamAsync(int udpPort) => SendAsync(new WireMessage
    {
        Kind = "streamStart", VideoPort = udpPort, Width = 1920, Height = 1080, FrameRate = 60, BitRate = 8_000_000
    });
    public Task StopStreamAsync() => SendAsync(new WireMessage { Kind = "streamStop" });
    public Task RequestKeyFrameAsync(Guid? streamID) => SendAsync(new WireMessage { Kind = "keyframeRequest", StreamID = streamID });
    public Task SendStreamStatsAsync(Guid? streamID, ulong packets, ulong decoded, ulong dropped) => SendAsync(new WireMessage
    {
        Kind = "streamStats", StreamID = streamID, PacketsReceived = packets, FramesDecoded = decoded, FramesDropped = dropped
    });

    public async Task DisconnectAsync()
    {
        _lifetime?.Cancel();
        _lifetime?.Dispose();
        _lifetime = null;
        if (_stream is not null) await _stream.DisposeAsync();
        _stream = null;
        _tcpClient?.Dispose();
        _tcpClient = null;
        IsPaired = false;
        RoundTripMilliseconds = null;
        _pendingPings.Clear();
        PairingChanged?.Invoke(false);
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync();
        _sendLock.Dispose();
    }

    private bool ValidateCertificate(X509Certificate? certificate, TrustedMac? trusted)
    {
        if (certificate is null) return false;
        var data = certificate.Export(X509ContentType.Cert);
        _pendingFingerprint = Convert.ToHexString(SHA256.HashData(data));
        return trusted is null || CryptographicOperations.FixedTimeEquals(
            Convert.FromHexString(trusted.CertificateSha256),
            Convert.FromHexString(_pendingFingerprint));
    }

    private async Task SendAsync(WireMessage message, CancellationToken cancellationToken = default)
    {
        var stream = _stream ?? throw new InvalidOperationException("Not connected.");
        await _sendLock.WaitAsync(cancellationToken);
        try { await FrameCodec.WriteAsync(stream, message, cancellationToken); }
        finally { _sendLock.Release(); }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var message = await FrameCodec.ReadAsync(_stream!, cancellationToken);
                HandleMessage(message);
                MessageReceived?.Invoke(message);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            StatusChanged?.Invoke($"连接中断：{error.Message}");
            IsPaired = false;
            PairingChanged?.Invoke(false);
        }
    }

    private void HandleMessage(WireMessage message)
    {
        switch (message.Kind)
        {
            case "hello":
                IsPaired = message.Accepted == true;
                if (IsPaired) CommitTrustIfPossible(_trustStore.Get(_hostKey!)?.SessionToken);
                PairingChanged?.Invoke(IsPaired);
                break;
            case "pairResult":
                IsPaired = message.Accepted == true;
                if (IsPaired && message.SessionToken is not null) CommitTrustIfPossible(message.SessionToken);
                if (message.Detail == "trust_revoked" && _hostKey is not null) _trustStore.Remove(_hostKey);
                PairingChanged?.Invoke(IsPaired);
                break;
            case "pong":
                if (_pendingPings.Remove(message.Id, out var started))
                    RoundTripMilliseconds = (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
                break;
        }
    }

    private void CommitTrustIfPossible(string? token)
    {
        if (_hostKey is null || token is null || _pendingFingerprint is null) return;
        _trustStore.Save(_hostKey, new TrustedMac(token, _pendingFingerprint));
    }

    private async Task HeartbeatLoopAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            var ping = new WireMessage { Kind = "ping" };
            _pendingPings[ping.Id] = Stopwatch.GetTimestamp();
            await SendAsync(ping, cancellationToken);
            var cutoff = Stopwatch.GetTimestamp() - 5 * Stopwatch.Frequency;
            if (_pendingPings.Values.Any(value => value < cutoff))
                throw new TimeoutException("Heartbeat timeout.");
        }
    }

    private static string LoadOrCreateDeviceID()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YingchuiInterconnect");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "device-id.txt");
        if (File.Exists(path)) return File.ReadAllText(path).Trim();
        var id = Guid.NewGuid().ToString();
        File.WriteAllText(path, id);
        return id;
    }
}
