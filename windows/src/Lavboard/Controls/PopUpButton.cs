using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace Lavboard.Controls;

/// <summary>
/// The macOS pop-up button: the current choice on a soft fill with an up-and-down chevron, sized for
/// its longest choice, opening a menu of the choices.
/// </summary>
public sealed partial class PopUpButton : Button
{
    private readonly TextBlock text = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly MenuFlyout menu = new() { Placement = FlyoutPlacementMode.Bottom };
    private IReadOnlyList<string> choices = [];
    private int selectedIndex = -1;

    public event EventHandler<int>? SelectionChanged;

    public PopUpButton()
    {
        Style = (Style)Application.Current.Resources["PopUpButtonStyle"];
        var chevrons = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center, Spacing = -2, Margin = new Thickness(22, 0, 0, 0),
            Children =
            {
                new FontIcon { Glyph = "", FontSize = 8, FontWeight = Microsoft.UI.Text.FontWeights.Bold },
                new FontIcon { Glyph = "", FontSize = 8, FontWeight = Microsoft.UI.Text.FontWeights.Bold },
            },
        };
        var row = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        Grid.SetColumn(chevrons, 1);
        row.Children.Add(text);
        row.Children.Add(chevrons);
        Content = row;
        Flyout = menu;
        menu.Opening += (_, _) => Fill();
    }

    public IReadOnlyList<string> Choices
    {
        get => choices;
        set { choices = value; FitWidth(); Show(); }
    }

    public int SelectedIndex
    {
        get => selectedIndex;
        set { selectedIndex = value; Show(); }
    }

    private void Show()
    {
        string current = selectedIndex >= 0 && selectedIndex < choices.Count ? choices[selectedIndex] : "";
        text.Text = current;
        AutomationProperties.SetItemStatus(this, current);
    }

    /// <summary>Like a fixed-size macOS pop-up: wide enough for the longest choice, so it never jumps.</summary>
    private void FitWidth()
    {
        var probe = new TextBlock { FontSize = FontSize, FontFamily = FontFamily };
        double widest = 0;
        foreach (var choice in choices)
        {
            probe.Text = choice;
            probe.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            widest = Math.Max(widest, probe.DesiredSize.Width);
        }
        text.MinWidth = Math.Ceiling(widest);
    }

    private void Fill()
    {
        menu.Items.Clear();
        for (int i = 0; i < choices.Count; i++)
        {
            int index = i;
            var item = new RadioMenuFlyoutItem { Text = choices[i], GroupName = "choices", IsChecked = i == selectedIndex };
            item.Click += (_, _) =>
            {
                if (index == selectedIndex) return;
                SelectedIndex = index;
                SelectionChanged?.Invoke(this, index);
            };
            menu.Items.Add(item);
        }
    }
}
