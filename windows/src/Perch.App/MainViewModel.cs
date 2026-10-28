using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Threading;
using Perch.Core;
using Perch.Core.Protocol;
using Perch.Core.Secrets;
using Perch.Core.Ssh;
using Perch.Core.State;

namespace Perch.App;

/// The UI's state owner. Wraps the portable SessionController + ConnectionCoordinator,
/// marshals every controller callback onto the WPF dispatcher, and exposes only what the
/// XAML binds to. No protocol or SSH logic lives here — it is all in Perch.Core, which is
/// what lets the same rules be tested headless on Linux.
public sealed class MainViewModel : Observable, ISessionObserver
{
    private readonly Dispatcher _dispatcher;
    private readonly Func<IBridgeTokenProvider, ConnectionCoordinator> _coordinatorFactory;
    private readonly Func<int, Task<bool>> _probeForward;
    private readonly SemaphoreSlim _connectionGate = new(1, 1);
    private CancellationTokenSource? _connectCancellation;
    private readonly ITokenFilePermissionChecker _permissions;

    private ConnectionCoordinator? _coordinator;
    private SessionController? _controller;

    public MainViewModel()
        : this(Dispatcher.CurrentDispatcher,
               provider => new ConnectionCoordinator(new DiagnosticsSshLauncher(),
                   new EphemeralLoopbackPortAllocator(), provider,
                   SshLocator.Resolve(File.Exists, null, SshLocator.DefaultProgramFilesRoots())),
               new WindowsTokenFilePermissionChecker(), ProbeForwardAsync)
    {
    }

    /// Injects connection creation and readiness so lifecycle tests use the real
    /// coordinator with a controlled transport and SSH process.
    public MainViewModel(
        Dispatcher dispatcher,
        Func<IBridgeTokenProvider, ConnectionCoordinator> coordinatorFactory,
        ITokenFilePermissionChecker permissions,
        Func<int, Task<bool>> probeForward)
    {
        _dispatcher = dispatcher;
        _coordinatorFactory = coordinatorFactory;
        _permissions = permissions;
        _probeForward = probeForward;
    }

    // --- Connection inputs (bound to the connect panel) ---
    private string _destination = string.Empty;
    private string _remotePort = string.Empty;
    private string _tokenFilePath = string.Empty;
    private bool _useSecureInput;
    private string _statusText = "未连接";
    private string? _errorText;
    private bool _isConnecting;
    private bool _isOnline;
    private bool _hasTokenFile;

    public string Destination { get => _destination; set { Set(ref _destination, value); OnPropertyChanged(nameof(CanConnect)); } }
    public string RemotePort { get => _remotePort; set { Set(ref _remotePort, value); OnPropertyChanged(nameof(CanConnect)); } }
    public string TokenFilePath { get => _tokenFilePath; set { Set(ref _tokenFilePath, value); Set(ref _hasTokenFile, !string.IsNullOrWhiteSpace(value)); OnPropertyChanged(nameof(CanConnect)); } }
    public bool UseSecureInput { get => _useSecureInput; set { Set(ref _useSecureInput, value); OnPropertyChanged(nameof(CanConnect)); } }
    public string StatusText { get => _statusText; set => Set(ref _statusText, value); }
    public string? ErrorText { get => _errorText; set { Set(ref _errorText, value); OnPropertyChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrEmpty(_errorText);
    public bool IsConnecting { get => _isConnecting; set { Set(ref _isConnecting, value); OnPropertyChanged(nameof(CanConnect)); OnPropertyChanged(nameof(ConnectEnabled)); } }
    public bool IsOnline { get => _isOnline; set { Set(ref _isOnline, value); OnPropertyChanged(nameof(CanConnect)); OnPropertyChanged(nameof(ConnectEnabled)); OnPropertyChanged(nameof(OnlineVisibility)); OnPropertyChanged(nameof(OfflineVisibility)); } }
    public bool HasTokenFile { get => _hasTokenFile; private set => Set(ref _hasTokenFile, value); }
    public bool ConnectEnabled => !IsConnecting;
    public bool CanConnect => !IsConnecting && !string.IsNullOrWhiteSpace(Destination) && ParsePort() is not null && (UseSecureInput || HasTokenFile);
    public Visibility OnlineVisibility => IsOnline ? Visibility.Visible : Visibility.Collapsed;
    public Visibility OfflineVisibility => IsOnline ? Visibility.Collapsed : Visibility.Visible;

    /// Set by the window from the PasswordBox (which cannot be data-bound for security).
    /// Held only in memory for connection attempts; never persisted or logged.
    public System.Security.SecureString? SecureToken { get; set; }

    // --- Session state (bound to the main panel) ---
    public ObservableCollection<SessionRow> Sessions { get; } = new();
    public ObservableCollection<MessageRow> Messages { get; } = new();
    public ObservableCollection<InteractionRow> Interactions { get; } = new();

    private SessionRow? _selectedSession;
    private string _composer = string.Empty;
    private long _composerVersion;
    private bool _isBusy;
    private bool _isSending;
    private bool _isCancelling;

    public SessionRow? SelectedSession
    {
        get => _selectedSession;
        set
        {
            if (Set(ref _selectedSession, value) && value is not null)
                _controller?.Select(value.Id);
            foreach (var row in Sessions) row.IsSelected = ReferenceEquals(row, value);
        }
    }
    public string Composer
    {
        get => _composer;
        set
        {
            if (_composer == value) return;
            _composerVersion++;
            Set(ref _composer, value);
            OnPropertyChanged(nameof(CanSend));
        }
    }
    public bool IsBusy { get => _isBusy; set { Set(ref _isBusy, value); OnPropertyChanged(nameof(CanCancel)); } }
    public bool IsSending { get => _isSending; set { Set(ref _isSending, value); OnPropertyChanged(nameof(CanSend)); } }
    public bool IsCancelling { get => _isCancelling; set { Set(ref _isCancelling, value); OnPropertyChanged(nameof(CanCancel)); } }
    public bool CanSend => IsOnline && SelectedSession is not null && !IsSending && !string.IsNullOrWhiteSpace(Composer);
    public bool CanCancel => IsOnline && IsBusy && !IsCancelling;
    public bool HasInteractions => Interactions.Count > 0;

    public int? ParsePort() => int.TryParse(RemotePort.Trim(), out var port) && port is >= 1 and <= 65535 ? port : null;

    // --- Commands ---

    public async Task ConnectAsync()
    {
        if (IsConnecting) return;
        ErrorText = null;
        var port = ParsePort();
        var destination = Destination.Trim();
        if (string.IsNullOrWhiteSpace(destination) || port is null)
        {
            ErrorText = "请填写 SSH 别名和有效的远端桥接端口（1–65535）。";
            return;
        }

        IBridgeTokenProvider tokenProvider;
        try
        {
            tokenProvider = BuildTokenProvider();
        }
        catch (PerchException ex)
        {
            ErrorText = ex.Message;
            return;
        }

        IsConnecting = true;
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        _connectCancellation = cancellation;
        await _connectionGate.WaitAsync();
        try
        {
            // A faulted connection may still own a poll loop and local SSH process.
            // Finish releasing it before creating the replacement.
            await ReleaseConnectionAsync();
            cancellation.Token.ThrowIfCancellationRequested();
            StatusText = "正在连接…";
            var coordinator = _coordinatorFactory(tokenProvider);
            _coordinator = coordinator;
            _controller = await coordinator.ConnectAsync(
                new ConnectionConfig(destination, port.Value),
                this, _probeForward, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();

            // The first poll can finish before ConnectAsync returns.
            RebuildCatalog();
            IsOnline = true;
            StatusText = "已连接：" + destination;
        }
        catch (Exception ex) when (ex is PerchException or OperationCanceledException or HttpRequestException)
        {
            await ReleaseConnectionAsync();
            ErrorText = ex is OperationCanceledException ? "连接已取消或超时。" : ex.Message;
        }
        finally
        {
            _connectCancellation = null;
            _connectionGate.Release();
            IsConnecting = false;
        }
    }

    private IBridgeTokenProvider BuildTokenProvider()
    {
        if (UseSecureInput)
        {
            if (SecureToken is null || SecureToken.Length == 0)
                throw new PerchException("请在安全输入框中粘贴桥接访问令牌。");
            return new SuppliedTokenProvider(BridgeToken.FromSecureString(SecureToken));
        }
        if (string.IsNullOrWhiteSpace(TokenFilePath))
            throw new PerchException("请选择令牌文件，或改用安全输入。");
        return new TokenFileProvider(TokenFilePath.Trim(), _permissions);
    }

    /// Real TCP probe that the local forward accepts, matching the port ssh bound.
    private static async Task<bool> ProbeForwardAsync(int localPort)
    {
        try
        {
            using var client = new System.Net.Sockets.TcpClient();
            var connect = client.ConnectAsync(System.Net.IPAddress.Loopback, localPort);
            var completed = await Task.WhenAny(connect, Task.Delay(250));
            return completed == connect && client.Connected;
        }
        catch
        {
            return false;
        }
    }

    public async Task DisconnectAsync()
    {
        // Window close can arrive while SSH is still becoming ready.
        _connectCancellation?.Cancel();
        await _connectionGate.WaitAsync();
        try
        {
            await ReleaseConnectionAsync();
        }
        finally
        {
            _connectionGate.Release();
        }
    }

    private async Task ReleaseConnectionAsync()
    {
        var coordinator = _coordinator;
        // Detach before awaiting cleanup so catalog/transcript callbacks see no controller.
        _coordinator = null;
        _controller = null;
        IsOnline = false;
        Sessions.Clear();
        Messages.Clear();
        Interactions.Clear();
        SelectedSession = null;
        OnPropertyChanged(nameof(HasInteractions));
        OnPropertyChanged(nameof(CanSend));
        OnPropertyChanged(nameof(CanCancel));
        StatusText = "正在断开…";
        try
        {
            if (coordinator is not null) await coordinator.DisposeAsync();
        }
        finally
        {
            StatusText = "未连接";
        }
    }

    public async Task SendAsync()
    {
        var controller = _controller;
        var text = Composer;
        if (controller is null || string.IsNullOrWhiteSpace(text) || IsSending) return;
        var draftVersion = _composerVersion;
        var sessionId = controller.SelectedId;
        IsSending = true;
        try
        {
            await controller.SendAsync(text, CancellationToken.None);
            if (ReferenceEquals(controller, _controller) && controller.SelectedId == sessionId &&
                _composerVersion == draftVersion)
                Composer = string.Empty;
        }
        catch (PerchException ex)
        {
            ErrorText = ex.Message;
        }
        finally
        {
            IsSending = false;
        }
    }

    /// Cancels the current turn only — distinct from disconnect, which never touches the
    /// remote agent.
    public async Task CancelTurnAsync()
    {
        var controller = _controller;
        if (controller is null || IsCancelling) return;
        IsCancelling = true;
        try
        {
            await controller.CancelTurnAsync(CancellationToken.None);
            StatusText = "已请求取消当前回合";
        }
        catch (PerchException ex)
        {
            ErrorText = ex.Message;
        }
        finally
        {
            IsCancelling = false;
        }
    }

    // --- ISessionObserver: every callback is marshaled to the UI thread ---

    public void OnConnectionStateChanged() => OnUi(() =>
    {
        var controller = _controller;
        if (controller is null) return;
        IsOnline = controller.ConnectionState == ConnectionState.Online;
        StatusText = controller.ConnectionState switch
        {
            ConnectionState.Online => "已连接：" + Destination.Trim(),
            ConnectionState.Faulted => "连接异常",
            ConnectionState.Connecting => "正在连接…",
            _ => "未连接",
        };
        if (controller.ConnectionState == ConnectionState.Faulted && controller.ConnectionError is not null)
            ErrorText = controller.ConnectionError;
    });

    public void OnCatalogChanged() => OnUi(RebuildCatalog);

    public void OnSelectionChanged() => OnUi(() =>
    {
        var selectedId = _controller?.SelectedId;
        if (selectedId is null)
        {
            Messages.Clear();
            Interactions.Clear();
            IsBusy = false;
            return;
        }
        var row = Sessions.FirstOrDefault(s => s.Id == selectedId);
        if (row is not null && !ReferenceEquals(row, _selectedSession))
        {
            // Set the backing field to avoid re-entering controller.Select.
            Set(ref _selectedSession, row);
            OnPropertyChanged(nameof(SelectedSession));
            foreach (var each in Sessions) each.IsSelected = ReferenceEquals(each, row);
        }
        RebuildTranscript();
    });

    public void OnTranscriptChanged() => OnUi(RebuildTranscript);

    public void OnOutboxChanged() => OnUi(() => OnPropertyChanged(nameof(CanSend)));

    public void OnError(string message) => OnUi(() => ErrorText = message);

    private void RebuildCatalog()
    {
        var controller = _controller;
        if (controller is null) return;
        var byId = Sessions.ToDictionary(s => s.Id, StringComparer.Ordinal);
        var next = new List<SessionRow>();
        foreach (var summary in controller.Sessions)
        {
            if (byId.TryGetValue(summary.Id, out var existing))
            {
                existing.Update(summary);
                next.Add(existing);
            }
            else
            {
                next.Add(new SessionRow(summary));
            }
        }
        Sessions.Clear();
        foreach (var row in next) Sessions.Add(row);

        var selectedId = controller.SelectedId;
        var selectedRow = selectedId is null ? null : Sessions.FirstOrDefault(s => s.Id == selectedId);
        if (!ReferenceEquals(selectedRow, _selectedSession))
        {
            Set(ref _selectedSession, selectedRow);
            OnPropertyChanged(nameof(SelectedSession));
        }
        foreach (var row in Sessions) row.IsSelected = ReferenceEquals(row, selectedRow);
    }

    private void RebuildTranscript()
    {
        var controller = _controller;
        var transcript = controller?.Transcript;
        Messages.Clear();
        if (transcript is not null)
        {
            foreach (var block in MessageProjection.Project(transcript.Messages))
                Messages.Add(new MessageRow(block));
        }

        Interactions.Clear();
        foreach (var interaction in controller?.PendingInteractions ?? Array.Empty<BridgeInteraction>())
            Interactions.Add(new InteractionRow(interaction));
        OnPropertyChanged(nameof(HasInteractions));

        IsBusy = controller?.Snapshot?.Busy == true ||
                 (controller?.SelectedSession?.Busy ?? false);
    }

    private void OnUi(Action action)
    {
        if (_dispatcher.CheckAccess()) action();
        else _dispatcher.BeginInvoke(action, DispatcherPriority.Normal);
    }
}
