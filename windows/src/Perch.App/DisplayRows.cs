using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using Perch.Core.Protocol;
using Perch.Core.State;

namespace Perch.App;

/// Minimal INotifyPropertyChanged base for the display rows.
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}

/// One session row in the sidebar. Status text mirrors the macOS client's derivation.
public sealed class SessionRow : Observable
{
    public string Id { get; }
    private string _title = string.Empty;
    private string _status = string.Empty;
    private string _subtitle = string.Empty;
    private bool _isBusy;
    private bool _isPending;
    private bool _isSelected;

    public SessionRow(SessionSummary summary)
    {
        Id = summary.Id;
        Update(summary);
    }

    public void Update(SessionSummary summary)
    {
        Set(ref _title, string.IsNullOrWhiteSpace(summary.Title) ? "未命名会话" : summary.Title);
        Set(ref _subtitle, summary.Cwd);
        Set(ref _isBusy, summary.Busy);
        Set(ref _isPending, summary.Pending > 0);
        Set(ref _status, DeriveStatus(summary));
    }

    public string Title { get => _title; set => Set(ref _title, value); }
    public string Status { get => _status; set => Set(ref _status, value); }
    public string Subtitle { get => _subtitle; set => Set(ref _subtitle, value); }
    public bool IsBusy { get => _isBusy; set => Set(ref _isBusy, value); }
    public bool IsPending { get => _isPending; set => Set(ref _isPending, value); }
    public bool IsSelected { get => _isSelected; set => Set(ref _isSelected, value); }

    internal static string DeriveStatus(SessionSummary summary) =>
        summary.Pending > 0 ? "等你处理"
        : summary.Busy ? "运行中"
        : summary.Error is not null ? "出错"
        : summary.Cancelled == true ? "已停止"
        : "就绪";
}

/// One projected message block rendered as a chat row.
public sealed class MessageRow
{
    public MessageRow(MessageBlock block)
    {
        Kind = block.Kind;
        Text = block.Text;
        ToolName = block.ToolName;
        IsError = block.IsError;
    }

    public BlockKind Kind { get; }
    public string Text { get; }
    public string? ToolName { get; }
    public bool IsError { get; }

    public bool IsUser => Kind == BlockKind.UserPrompt;
    public bool IsAssistant => Kind == BlockKind.AssistantText;
    public bool IsSystemNote => Kind == BlockKind.SystemNote;
    public bool IsThinking => Kind == BlockKind.Thinking;
    public bool IsTool => Kind is BlockKind.ToolCall or BlockKind.ToolResult;

    public string Header => Kind switch
    {
        BlockKind.UserPrompt => "你",
        BlockKind.AssistantText => "Agent",
        BlockKind.Thinking => "思考",
        BlockKind.ToolCall => ToolName is null ? "调用工具" : "调用工具：" + ToolName,
        BlockKind.ToolResult => IsError
            ? (ToolName is null ? "工具报错" : "工具报错：" + ToolName)
            : (ToolName is null ? "工具结果" : "工具结果：" + ToolName),
        BlockKind.SystemNote => "系统",
        _ => string.Empty,
    };

    public Visibility HeaderVisibility => string.IsNullOrEmpty(Header) ? Visibility.Collapsed : Visibility.Visible;

    public Visibility TextVisibility => string.IsNullOrEmpty(Text) ? Visibility.Collapsed : Visibility.Visible;
}

/// A pending approval/question. The MVP displays it and never answers it.
public sealed class InteractionRow
{
    public InteractionRow(BridgeInteraction interaction)
    {
        Id = interaction.Id;
        Title = interaction.Title ?? interaction.Name ?? "等待确认";
        Detail = RenderDetail(interaction);
        Kind = interaction.Name ?? interaction.Method ?? "interaction";
    }

    public string Id { get; }
    public string Title { get; }
    public string Detail { get; }
    public string Kind { get; }

    private static string RenderDetail(BridgeInteraction interaction)
    {
        if (interaction.Input is System.Text.Json.Nodes.JsonObject input)
        {
            foreach (var key in new[] { "command", "reason", "message", "cwd", "path" })
            {
                if (input[key] is System.Text.Json.Nodes.JsonValue value)
                    return key + ": " + value.ToJsonString();
            }
            return input.ToJsonString();
        }
        return interaction.Message ?? interaction.Input?.ToJsonString() ?? string.Empty;
    }
}
