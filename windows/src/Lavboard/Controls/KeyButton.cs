using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Lavboard.Controls;

/// <summary>KeyStyle: a console key, flat when off and backlit when on.</summary>
public sealed partial class KeyButton : Button
{
    public static readonly DependencyProperty LitProperty =
        DependencyProperty.Register(nameof(Lit), typeof(bool), typeof(KeyButton), new PropertyMetadata(false, (d, _) => ((KeyButton)d).UpdateLook()));
    public static readonly DependencyProperty CompactProperty =
        DependencyProperty.Register(nameof(Compact), typeof(bool), typeof(KeyButton), new PropertyMetadata(false, (d, _) => ((KeyButton)d).UpdateLook()));
    public static readonly DependencyProperty LegendProperty =
        DependencyProperty.Register(nameof(Legend), typeof(string), typeof(KeyButton), new PropertyMetadata(null));

    public KeyButton()
    {
        Style = (Style)Application.Current.Resources["KeyButtonStyle"];
        UpdateLook();
    }

    public bool Lit { get => (bool)GetValue(LitProperty); set => SetValue(LitProperty, value); }
    /// <summary>Smaller type and padding, for keys inside strip rows.</summary>
    public bool Compact { get => (bool)GetValue(CompactProperty); set => SetValue(CompactProperty, value); }
    /// <summary>Small shortcut legend printed in the key's corner.</summary>
    public string? Legend { get => (string?)GetValue(LegendProperty); set => SetValue(LegendProperty, value); }

    public Brush LitBackground { get; set; } = LedMeter.Brush("ConsoleSilk");
    public Brush LitForeground { get; set; } = LedMeter.Brush("ConsoleInk");

    public void UpdateLook()
    {
        Background = Lit ? LitBackground : LedMeter.Brush("ConsoleWell");
        Foreground = Lit ? LitForeground : LedMeter.Brush("ConsoleSilk");
        BorderBrush = Lit ? new SolidColorBrush(Microsoft.UI.Colors.Transparent) : LedMeter.Brush("ConsoleKeyStroke");
        FontSize = Compact ? 12 : 14;
        // SwiftUI pads one line of text: 10 pt around 14 pt type, 4 pt around 12 pt type. The
        // stroke is drawn inside the key there, so fix the heights rather than add padding.
        Padding = Compact ? new Thickness(6, 0, 6, 0) : new Thickness(8, 0, 8, 0);
        Height = Compact ? 23 : 36;
    }
}
