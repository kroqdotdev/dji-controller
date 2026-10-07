using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Lavboard.Controls;

/// <summary>The macOS segmented control: a soft track with the chosen segment raised.</summary>
public sealed partial class Segmented : UserControl
{
    private readonly Grid row = new() { Padding = new Thickness(2), ColumnSpacing = 0 };
    private readonly List<(string Id, Button Button)> segments = [];
    private string? selected;

    public event EventHandler<string>? SelectionChanged;

    public Segmented(IEnumerable<(string Id, string Name)> options)
    {
        int i = 0;
        foreach (var (id, name) in options)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition());
            var button = new Button
            {
                Style = (Style)Application.Current.Resources["PlainButton"], MinWidth = 56, Padding = new Thickness(10, 2, 10, 3),
                CornerRadius = new CornerRadius(5), Content = new TextBlock { Text = name, FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center },
            };
            AutomationProperties.SetName(button, name);
            button.Click += (_, _) => { if (id != selected) { Selected = id; SelectionChanged?.Invoke(this, id); } };
            Grid.SetColumn(button, i++);
            row.Children.Add(button);
            segments.Add((id, button));
        }
        Content = new Border { Background = (Brush)Application.Current.Resources["PopUpFill"], CornerRadius = new CornerRadius(7), Child = row };
    }

    public string? Selected
    {
        get => selected;
        set
        {
            selected = value;
            foreach (var (id, button) in segments)
            {
                bool on = id == value;
                button.Background = on ? (Brush)Application.Current.Resources["SegmentSelected"] : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
                AutomationProperties.SetItemStatus(button, on ? "Selected" : "");
            }
        }
    }
}
