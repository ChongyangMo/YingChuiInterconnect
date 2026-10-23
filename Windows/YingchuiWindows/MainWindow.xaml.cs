using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using YingchuiWindows.Networking;
using YingchuiWindows.Protocol;

namespace YingchuiWindows;

public partial class MainWindow : Window
{
    private readonly MacConnection _connection = new();
    private readonly MdnsDiscovery _discovery = new();
    private readonly VideoReceiver _videoReceiver = new();
    private readonly ObservableCollection<DiscoveredMac> _hosts = [];
    private Point? _previousPointer;
    private Guid? _streamID;

    public MainWindow()
    {
        InitializeComponent();
        HostsList.ItemsSource = _hosts;
        Loaded += async (_, _) => await StartDiscoveryAsync();
        Closed += async (_, _) =>
        {
            await _videoReceiver.DisposeAsync();
            await _connection.DisposeAsync();
            await _discovery.DisposeAsync();
        };
        _discovery.ResultsChanged += results => Dispatcher.Invoke(() =>
        {
            _hosts.Clear();
            foreach (var host in results) _hosts.Add(host);
        });
        _connection.StatusChanged += status => Dispatcher.Invoke(() => ConnectionStatus.Text = status);
        _connection.PairingChanged += paired => Dispatcher.Invoke(() =>
            ConnectionStatus.Text = paired ? "TLS 已连接，可信设备认证通过" : "已连接，等待六位配对码");
        _connection.MessageReceived += HandleMessage;
        _videoReceiver.FrameCompleted += frame => Dispatcher.Invoke(() =>
            VideoStatus.Text = $"正在接收 H.264：帧 {frame.FrameID}，{frame.AccessUnit.Length / 1024.0:F1} KB");
        _videoReceiver.StatisticsChanged += (packets, completed, dropped) => Dispatcher.Invoke(async () =>
        {
            VideoStats.Text = $"数据包 {packets} · 完整帧 {completed} · 丢帧 {dropped}";
            if (_connection.IsConnected)
                await _connection.SendStreamStatsAsync(_streamID, packets, completed, dropped);
        });
    }

    private async Task StartDiscoveryAsync()
    {
        try { await _discovery.StartAsync(); }
        catch (Exception error) { ConnectionStatus.Text = $"mDNS 发现失败，可手动输入地址：{error.Message}"; }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        try { await _discovery.QueryAsync(); }
        catch (Exception error) { ConnectionStatus.Text = error.Message; }
    }

    private void HostsList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (HostsList.SelectedItem is not DiscoveredMac host) return;
        HostBox.Text = host.Host;
        PortBox.Text = host.Port.ToString();
        ServiceNameBox.Text = host.Name;
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(PortBox.Text, out var port))
        {
            ConnectionStatus.Text = "请输入有效端口";
            return;
        }
        try
        {
            ConnectionStatus.Text = "正在建立 TLS 1.3 连接…";
            await _connection.ConnectAsync(HostBox.Text.Trim(), port, ServiceNameBox.Text.Trim());
        }
        catch (Exception error) { ConnectionStatus.Text = $"连接失败：{error.Message}"; }
    }

    private async void Disconnect_Click(object sender, RoutedEventArgs e)
    {
        _videoReceiver.Stop();
        await _connection.DisconnectAsync();
        ConnectionStatus.Text = "已断开";
    }

    private async void Pair_Click(object sender, RoutedEventArgs e)
    {
        try { await _connection.PairAsync(PairCodeBox.Text); }
        catch (Exception error) { ConnectionStatus.Text = error.Message; }
    }

    private async void StartStream_Click(object sender, RoutedEventArgs e)
    {
        if (!_connection.IsPaired) { VideoStatus.Text = "请先完成配对"; return; }
        _videoReceiver.Start();
        await _connection.StartStreamAsync(_videoReceiver.Port);
        VideoStatus.Text = $"UDP 端口 {_videoReceiver.Port} 已就绪，等待视频配置";
    }

    private async void StopStream_Click(object sender, RoutedEventArgs e)
    {
        if (_connection.IsConnected) await _connection.StopStreamAsync();
        _videoReceiver.Stop();
        _streamID = null;
        VideoStatus.Text = "已停止";
    }

    private async void KeyFrame_Click(object sender, RoutedEventArgs e) => await _connection.RequestKeyFrameAsync(_streamID);
    private async void LeftClick_Click(object sender, RoutedEventArgs e) => await _connection.ClickAsync("left");
    private async void RightClick_Click(object sender, RoutedEventArgs e) => await _connection.ClickAsync("right");
    private async void ScrollUp_Click(object sender, RoutedEventArgs e) => await _connection.ScrollAsync(80);
    private async void ScrollDown_Click(object sender, RoutedEventArgs e) => await _connection.ScrollAsync(-80);
    private async void SendText_Click(object sender, RoutedEventArgs e)
    {
        if (TextInputBox.Text.Length > 0) await _connection.SendTextAsync(TextInputBox.Text);
        TextInputBox.Clear();
    }

    private void Trackpad_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _previousPointer = e.GetPosition(Trackpad);
        Trackpad.CaptureMouse();
    }

    private void Trackpad_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        _previousPointer = null;
        Trackpad.ReleaseMouseCapture();
    }

    private async void Trackpad_MouseMove(object sender, MouseEventArgs e)
    {
        if (_previousPointer is not Point previous || e.LeftButton != MouseButtonState.Pressed) return;
        var current = e.GetPosition(Trackpad);
        _previousPointer = current;
        await _connection.MovePointerAsync((current.X - previous.X) * 1.25, (current.Y - previous.Y) * 1.25);
    }

    private void HandleMessage(WireMessage message)
    {
        Dispatcher.Invoke(() =>
        {
            switch (message.Kind)
            {
                case "videoConfig" when message.StreamID is Guid streamID:
                    _streamID = streamID;
                    _videoReceiver.StreamID = streamID;
                    VideoStatus.Text = $"{message.Width}×{message.Height} @ {message.FrameRate} fps，等待视频帧";
                    break;
                case "error":
                    ConnectionStatus.Text = $"Mac 拒绝请求：{message.Detail}";
                    break;
            }
        });
    }
}
