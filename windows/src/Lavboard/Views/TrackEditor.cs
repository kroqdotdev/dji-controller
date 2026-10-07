using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Lavboard.Controls;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>The popover under a tape label: rename, recolour, change the source or remove the track.</summary>
public sealed partial class TrackEditor : UserControl
{
    private readonly AppModel app;
    private readonly Track track;
    private readonly Flyout flyout;
    private readonly TextBox name;
    private readonly StackPanel swatches = new() { Orientation = Orientation.Horizontal, Spacing = 8 };

    public static void Show(AppModel app, Track track, FrameworkElement anchor)
    {
        var flyout = new Flyout
        {
            Placement = FlyoutPlacementMode.Bottom,
            // Like a macOS popover, it may extend past the window's edge to stay centred on the tape.
            ShouldConstrainToRootBounds = false,
            FlyoutPresenterStyle = (Style)Application.Current.Resources["PopoverPresenter"],
        };
        flyout.Content = new TrackEditor(app, track, flyout);
        flyout.ShowAt(anchor);
    }

    private TrackEditor(AppModel app, Track track, Flyout flyout)
    {
        this.app = app;
        this.track = track;
        this.flyout = flyout;
        var resources = Application.Current.Resources;
        int index = app.Tracks.IndexOf(track);

        name = new TextBox { Text = track.Name, PlaceholderText = "Who or what is on it", FontSize = 13 };
        AutomationProperties.SetName(name, "Name");
        name.TextChanged += (_, _) => track.Name = name.Text;
        name.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; flyout.Hide(); } };

        BuildSwatches();

        var sourceButton = new DropDownButton
        {
            Content = app.SourceDescription(track.Source), IsEnabled = app.CanEditTracks, FontSize = 13,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var sourceMenu = new MenuFlyout();
        sourceMenu.Opening += (_, _) => SourceMenu.Fill(sourceMenu.Items, app, track.Source, s =>
        {
            app.SetSource(track, s);
            sourceButton.Content = app.SourceDescription(s);
        });
        sourceButton.Flyout = sourceMenu;

        var source = new StackPanel { Spacing = 8, Children = { Heading("Source"), sourceButton } };
        if (app.Transmitter(track.Source)?.Serial is { Length: > 0 } serial)
            source.Children.Add(new TextBlock { Text = $"Serial {serial}. Tap this mic and its meter will move.", Style = (Style)resources["PopoverNote"] });

        var remove = new Button { Content = "Remove track", IsEnabled = app.CanEditTracks, FontSize = 13 };
        ToolTipService.SetToolTip(remove, app.CanEditTracks ? "Remove this track from the mixer" : "Stop recording to change tracks.");
        remove.Click += (_, _) => { flyout.Hide(); app.RemoveTrack(track); };
        var done = new Button { Content = "Done", Style = (Style)resources["AccentButtonStyle"], FontSize = 13, HorizontalAlignment = HorizontalAlignment.Right };
        done.Click += (_, _) => flyout.Hide();
        var buttons = new Grid { Children = { remove, done } };

        Content = new StackPanel
        {
            Width = 330, Padding = new Thickness(18), Spacing = 14,
            Children =
            {
                new TextBlock { Text = $"Track {index + 1}", Style = (Style)resources["PopoverTitle"] },
                name,
                new StackPanel { Spacing = 8, Children = { Heading("Tape colour"), swatches } },
                source,
                buttons,
            },
        };
        flyout.Opened += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
    }

    private static TextBlock Heading(string text) => new() { Text = text, Style = (Style)Application.Current.Resources["PopoverHeading"] };

    private void BuildSwatches()
    {
        swatches.Children.Clear();
        foreach (var color in Enum.GetValues<TapeColor>())
        {
            bool selected = track.Color == color;
            var chip = new Border
            {
                Width = 30, Height = 22, CornerRadius = new CornerRadius(2), Background = new SolidColorBrush(color.Fill()),
                Child = selected ? new FontIcon
                {
                    Glyph = "", FontSize = 11, FontWeight = FontWeights.Bold, Foreground = LedMeter.Brush("ConsoleInk"),
                } : null,
            };
            var ring = new Border
            {
                // SwiftUI pads the chip by 2 and strokes the ring inside that padding: 34 x 26 in all.
                Padding = new Thickness(0.5), CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1.5),
                BorderBrush = selected ? LedMeter.Brush("ConsoleSilk") : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                Child = chip,
            };
            var button = new Button { Style = (Style)Application.Current.Resources["PlainButton"], Content = ring };
            AutomationProperties.SetName(button, color.Label());
            ToolTipService.SetToolTip(button, color.Label());
            button.Click += (_, _) => { track.Color = color; BuildSwatches(); };
            swatches.Children.Add(button);
        }
    }
}
