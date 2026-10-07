using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Lavboard.Controls;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>The toolbar's update capsule, with the same states and words as UpdateButton on the Mac.</summary>
public sealed partial class UpdateButton : UserControl
{
    private readonly AppModel app;
    private readonly Button button;
    private readonly FontIcon icon = new() { FontSize = 13 };
    private readonly ProgressRing ring = new() { Width = 14, Height = 14, MinWidth = 0, MinHeight = 0 };
    private readonly TextBlock text = new() { VerticalAlignment = VerticalAlignment.Center };

    public UpdateButton(AppModel app)
    {
        this.app = app;
        button = new Button
        {
            Style = (Style)Application.Current.Resources["ToolbarButton"],
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { icon, ring, text } },
        };
        button.Click += (_, _) => Act();
        Content = button;
        app.Updates.PropertyChanged += OnChanged;
        app.PropertyChanged += OnChanged;
        Refresh();
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e) => Refresh();

    private void Act()
    {
        switch (app.Updates.Stage)
        {
            case UpdateStage.Available: app.Updates.Install(); break;
            case UpdateStage.ReadyToRestart: app.Updates.RestartNow(); break;
            case UpdateStage.Failed: app.Updates.CheckNow(); break;
        }
    }

    private void Refresh()
    {
        var updates = app.Updates;
        bool recording = app.IsRecording;
        (string? glyph, bool spinning, string label, string? tip, bool clickable) = updates.Stage switch
        {
            UpdateStage.Available => ("", false, $"Update to {updates.AvailableVersion}",
                recording ? "Stop recording to update." : $"Downloads Lavboard {updates.AvailableVersion} and restarts. Audio stops for a few seconds.", !recording),
            UpdateStage.Downloading => (null, true, "Updating", null, false),
            UpdateStage.Installing => (null, true, "Restarting", null, false),
            UpdateStage.ReadyToRestart => ("", false, "Restart to update",
                recording ? "The update is ready. Stop recording to restart into it." : "Restarts Lavboard into the new version. Audio stops for a few seconds.", !recording),
            UpdateStage.Checking => (null, true, "Checking for updates", null, false),
            UpdateStage.UpToDate => ("", false, "Lavboard is up to date", null, false),
            UpdateStage.Failed => ("", false, "Update failed", $"{updates.Failure} Click to try again.", true),
            _ => (null, false, "", null, false),
        };
        Visibility = updates.Stage == UpdateStage.Idle ? Visibility.Collapsed : Visibility.Visible;
        icon.Glyph = glyph ?? "";
        icon.Visibility = glyph != null ? Visibility.Visible : Visibility.Collapsed;
        ring.Visibility = spinning ? Visibility.Visible : Visibility.Collapsed;
        ring.IsActive = spinning;
        ring.IsIndeterminate = updates.Stage != UpdateStage.Downloading || updates.Progress == null;
        ring.Value = (updates.Progress ?? 0) * 100;
        text.Text = label;
        // "Up to date" reads as a quiet note, like the Mac's engraved label.
        button.Foreground = LedMeter.Brush(updates.Stage == UpdateStage.UpToDate ? "ConsoleEngraving" : "ConsoleSilk");
        button.IsHitTestVisible = clickable;
        button.IsTabStop = clickable;
        ToolTipService.SetToolTip(button, tip);
        AutomationProperties.SetName(button, label);
    }
}
