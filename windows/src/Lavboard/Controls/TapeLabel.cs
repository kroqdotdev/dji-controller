using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Lavboard.Model;

namespace Lavboard.Controls;

/// <summary>The track's name on a piece of console tape. Shrinks to 70% before truncating, as on the Mac.</summary>
public sealed partial class TapeLabel : Button
{
    public const double TapeHeight = 36;
    private const double FontSizeFull = 22;

    private readonly Border tape = new() { Height = TapeHeight, CornerRadius = new CornerRadius(2), Padding = new Thickness(6, 0, 6, 0) };
    private readonly TextBlock text = new()
    {
        FontFamily = (FontFamily)Application.Current.Resources["TapeFont"], FontWeight = FontWeights.ExtraBold, FontSize = FontSizeFull,
        Foreground = LedMeter.Brush("ConsoleInk"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
    };

    public TapeLabel()
    {
        Style = (Style)Application.Current.Resources["PlainButton"];
        HorizontalAlignment = HorizontalAlignment.Stretch;
        tape.Child = text;
        Content = tape;
        SizeChanged += (_, _) => Fit();
    }

    public void Show(string name, TapeColor color, string channel)
    {
        text.Text = name;
        tape.Background = new SolidColorBrush(color.Fill());
        AutomationProperties.SetName(this, $"{name}, {channel}");
        AutomationProperties.SetHelpText(this, "Opens the track editor");
        ToolTipService.SetToolTip(this, $"Rename, recolour or change the source of {name}");
        Fit();
    }

    private void Fit()
    {
        double available = tape.ActualWidth - tape.Padding.Left - tape.Padding.Right;
        if (available <= 0) return;
        text.FontSize = FontSizeFull;
        text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double needed = text.DesiredSize.Width;
        text.FontSize = needed > available ? Math.Max(FontSizeFull * 0.7, FontSizeFull * available / needed) : FontSizeFull;
    }
}
