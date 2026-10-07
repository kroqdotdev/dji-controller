using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>The popover from the "Add track" slot: every source a new track can use.</summary>
public sealed partial class SourcePicker : UserControl
{
    public static void Show(AppModel app, FrameworkElement anchor, FlyoutPlacementMode placement = FlyoutPlacementMode.Right)
    {
        var flyout = new Flyout { Placement = placement, ShouldConstrainToRootBounds = false, FlyoutPresenterStyle = (Style)Application.Current.Resources["PopoverPresenter"] };
        flyout.Content = new SourcePicker(app, flyout);
        flyout.ShowAt(anchor);
    }

    private SourcePicker(AppModel app, Flyout flyout)
    {
        var resources = Application.Current.Resources;
        var groups = new StackPanel { Spacing = 14, Padding = new Thickness(14, 0, 14, 14) };

        StackPanel Group(string title, IReadOnlyList<SourceChoice> options, string? note = null)
        {
            var group = new StackPanel { Spacing = 4 };
            group.Children.Add(new TextBlock { Text = title, Style = (Style)resources["PopoverHeading"] });
            if (note != null)
                group.Children.Add(new TextBlock
                {
                    Text = note, Style = (Style)resources["PopoverNote"], Foreground = (Microsoft.UI.Xaml.Media.Brush)resources["TertiaryLabel"],
                    Margin = new Thickness(0, 0, 0, 2),
                });
            foreach (var choice in options)
            {
                var row = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
                row.Children.Add(new TextBlock { Text = choice.Title, TextTrimming = TextTrimming.CharacterEllipsis });
                string? trailing = choice.InUse ? "In use" : choice.Note;
                if (trailing != null)
                {
                    var side = new TextBlock { Text = trailing, Foreground = (Microsoft.UI.Xaml.Media.Brush)resources["SecondaryLabel"], Margin = new Thickness(8, 0, 0, 0) };
                    Grid.SetColumn(side, 1);
                    row.Children.Add(side);
                }
                var button = new Button { Style = (Style)resources["PickerRowButton"], Content = row, IsEnabled = !choice.InUse };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, trailing == null ? choice.Title : $"{choice.Title}, {trailing}");
                button.Click += (_, _) => { app.AddTrack(choice.Source, choice.DefaultName); flyout.Hide(); };
                group.Children.Add(button);
            }
            return group;
        }

        var choices = app.SourceChoices();
        foreach (var group in choices) groups.Children.Add(Group(group.Title, group.Options, group.Note));
        groups.Children.Add(Group("App audio", app.AppAudioChoices(),
            "Records what apps play, which keeps playing on the PC as usual."));
        if (choices.Count == 0)
            groups.Children.Add(new TextBlock
            {
                Text = "Plug in a mic, an audio interface or a wireless receiver to add it here.", FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)resources["SecondaryLabel"],
            });

        Content = new StackPanel
        {
            Width = 300,
            Children =
            {
                new TextBlock { Text = "Add a track", Style = (Style)resources["PopoverTitle"], Margin = new Thickness(14, 14, 14, 8) },
                new ScrollViewer { Content = groups, MaxHeight = 440 },
            },
        };
    }
}
