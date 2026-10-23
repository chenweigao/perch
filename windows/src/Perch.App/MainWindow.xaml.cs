using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using Microsoft.Win32;

namespace Perch.App;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = new MainViewModel();
        DataContext = _viewModel;
        // Default to the secure-input token entry.
        _viewModel.UseSecureInput = true;
        TokenFileRadio.IsChecked = false;
        Closing += OnClosing;
    }

    private void TokenBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        // A PasswordBox cannot be data-bound (by design), so the SecureString is handed to
        // the view model directly and held only in memory for this connection.
        _viewModel.SecureToken = TokenBox.SecurePassword;
    }

    private void TokenFileRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not null) _viewModel.UseSecureInput = false;
    }

    private void BrowseToken_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "选择桥接令牌文件",
            CheckFileExists = true,
            Filter = "令牌或 JSON 文件 (*.token;*.json;*.txt)|*.token;*.json;*.txt|所有文件 (*.*)|*.*",
        };
        if (dialog.ShowDialog(this) == true)
        {
            _viewModel.UseSecureInput = false;
            _viewModel.TokenFilePath = dialog.FileName;
        }
    }

    private async void Connect_Click(object sender, RoutedEventArgs e) => await _viewModel.ConnectAsync();

    private async void Disconnect_Click(object sender, RoutedEventArgs e) => await _viewModel.DisconnectAsync();

    private async void Send_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.SendAsync();
        TranscriptScroll.ScrollToEnd();
    }

    private async void Cancel_Click(object sender, RoutedEventArgs e) => await _viewModel.CancelTurnAsync();

    private async void Composer_KeyDown(object sender, KeyEventArgs e)
    {
        // Enter sends, Shift+Enter inserts a newline.
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
        {
            e.Handled = true;
            if (_viewModel.CanSend)
            {
                await _viewModel.SendAsync();
                TranscriptScroll.ScrollToEnd();
            }
        }
    }

    private async void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        // Closing the window disconnects this client only; the remote bridge and any
        // running turn keep going.
        e.Cancel = true;
        await _viewModel.DisconnectAsync();
        Closing -= OnClosing;
        Close();
    }
}

/// Boolean → Visibility, inverted.
public sealed class InverseBooleanToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is Visibility.Collapsed;
}

/// Boolean negation, for radio-button two-way binding against UseSecureInput.
public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is not true;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is not true;
}
