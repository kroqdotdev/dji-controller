using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Lavboard.Controls;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>Record key, destination and format along the bottom, as on the Mac.</summary>
public sealed partial class TransportBar : UserControl
{
    private readonly AppModel app;
    private readonly KeyButton record = new() { Width = 120 };
    private readonly Ellipse dot = new() { Width = 14, Height = 14 };
    private readonly Rectangle square = new() { Width = 11, Height = 11, RadiusX = 2, RadiusY = 2, Fill = new SolidColorBrush(Microsoft.UI.Colors.White) };
    private readonly TextBlock recordText = new();
    private readonly TextBlock timer;
    private readonly TextBlock destination;
    private readonly HyperlinkButton change;
    private readonly HyperlinkButton show;
    private readonly TextBlock error;
    private readonly PopUpButton format = new();
    private readonly CheckBox backup;
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };

    public event EventHandler? ChooseFolder;
    public event EventHandler? ShowFolder;

    public TransportBar(AppModel app)
    {
        this.app = app;
        var resources = Application.Current.Resources;
        Height = 64;

        dot.Fill = LedMeter.Brush("ConsoleRed");
        record.LitBackground = LedMeter.Brush("ConsoleRed");
        record.LitForeground = new SolidColorBrush(Microsoft.UI.Colors.White);
        record.HorizontalAlignment = HorizontalAlignment.Left;
        record.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8,
            Children = { new Grid { Width = 14, VerticalAlignment = VerticalAlignment.Center, Children = { dot, square } }, recordText },
        };
        record.Click += (_, _) => app.ToggleRecording();
        ToolTipService.SetToolTip(record, "Record every mic to its own file, plus the stream mix (Ctrl+R)");
        record.KeyboardAccelerators.Add(new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.R, Modifiers = Windows.System.VirtualKeyModifiers.Control });

        timer = new TextBlock
        {
            FontFamily = (FontFamily)resources["InterSemiBold"], FontWeight = FontWeights.SemiBold, FontSize = 28,
            Foreground = LedMeter.Brush("ConsoleRed"), VerticalAlignment = VerticalAlignment.Center,
        };
        destination = new TextBlock
        {
            FontSize = 12, Foreground = LedMeter.Brush("ConsoleEngraving"), VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        change = new HyperlinkButton { Content = "Change…", Style = (Style)resources["LinkButton"] };
        change.Click += (_, _) => ChooseFolder?.Invoke(this, EventArgs.Empty);
        show = new HyperlinkButton { Content = "Show in Explorer", Style = (Style)resources["LinkButton"] };
        show.Click += (_, _) => ShowFolder?.Invoke(this, EventArgs.Empty);
        error = new TextBlock
        {
            FontFamily = (FontFamily)resources["InterMedium"], FontWeight = FontWeights.Medium, FontSize = 12,
            Foreground = LedMeter.Brush("ConsoleAmber"), VerticalAlignment = VerticalAlignment.Center, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
        };

        format.Choices = AppModel.RecordingFormats;
        format.SelectedIndex = AppModel.RecordingFormats.ToList().IndexOf(app.RecordingFormat);
        format.SelectionChanged += (_, i) => app.RecordingFormat = AppModel.RecordingFormats[i];
        ToolTipService.SetToolTip(format, "File format for the recordings");

        backup = new CheckBox { Content = "Backup on mics", Style = (Style)resources["MacCheckBox"], IsChecked = app.BackupOnTransmitters };
        backup.Click += (_, _) => app.BackupOnTransmitters = backup.IsChecked == true;
        ToolTipService.SetToolTip(backup, "Also start each transmitter's own recording, on mics that can");

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, Children = { record, timer, destination, change, show, error } };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, Children = { format, backup } };
        var row = new Grid
        {
            Padding = new Thickness(16, 0, 16, 0), ColumnSpacing = 18,
            ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } },
        };
        Grid.SetColumn(right, 1);
        row.Children.Add(left);
        row.Children.Add(right);
        Content = new Border { Background = LedMeter.Brush("ConsolePanel"), Child = row };

        clock.Tick += (_, _) => ShowTimer();
        app.PropertyChanged += OnAppChanged;
        Refresh();
    }

    private void OnAppChanged(object? sender, PropertyChangedEventArgs e) => Refresh();

    private void Refresh()
    {
        bool recording = app.IsRecording;
        record.Lit = recording;
        recordText.Text = recording ? "Stop" : "Record";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(record, recordText.Text);
        dot.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        square.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        record.IsEnabled = recording || app.CanRecord;
        ToolTipService.SetToolTip(record, app.Updates.IsBusy && !recording
            ? "Recording is unavailable while Lavboard updates."
            : "Record every mic to its own file, plus the stream mix (Ctrl+R)");

        timer.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        destination.Visibility = change.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        show.Visibility = !recording && app.LastRecordingFolder != null ? Visibility.Visible : Visibility.Collapsed;
        destination.Text = "Saving to " + FriendlyPath(app.RecordingFolder);
        error.Text = app.RecordingError ?? "";
        error.Visibility = app.RecordingError == null ? Visibility.Collapsed : Visibility.Visible;

        format.IsEnabled = backup.IsEnabled = !recording;
        backup.Visibility = app.CanBackUpOnTransmitters ? Visibility.Visible : Visibility.Collapsed;
        backup.IsChecked = app.BackupOnTransmitters;
        if (recording) { ShowTimer(); clock.Start(); } else clock.Stop();
    }

    private void ShowTimer()
    {
        if (app.RecordingStartedAt is { } started) timer.Text = (DateTime.Now - started).ToString(@"h\:mm\:ss");
    }

    /// <summary>Paths in the user's folder read like Explorer shows them: "Music\Lavboard".</summary>
    private static string FriendlyPath(string path)
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + System.IO.Path.DirectorySeparatorChar;
        return path.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? path[home.Length..] : path;
    }
}
