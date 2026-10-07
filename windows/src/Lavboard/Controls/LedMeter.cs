using Lavboard.Model;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace Lavboard.Controls;

/// <summary>Hardware-style LED ladder: 30 segments of 2 dB from -60 dBFS to 0, as in the macOS app.</summary>
public sealed partial class LedMeter : UserControl
{
    public const float Floor = -60;
    public const int Segments = 30;
    private const double Gap = 2;

    private static readonly SolidColorBrush Red = Brush("ConsoleRed");
    private static readonly SolidColorBrush Amber = Brush("ConsoleAmber");
    private static readonly SolidColorBrush Green = Brush("ConsoleGreen");

    private readonly Canvas canvas = new();
    private readonly Rectangle[] leds = new Rectangle[Segments];

    public LedMeter()
    {
        Content = canvas;
        for (int i = 0; i < Segments; i++)
        {
            float top = Floor + (i + 1) * 2;
            leds[i] = new Rectangle { RadiusX = 1, RadiusY = 1, Opacity = 0.09, Fill = top > -3 ? Red : top > -12 ? Amber : Green };
            canvas.Children.Add(leds[i]);
        }
        SizeChanged += (_, e) => Layout(e.NewSize);
        AutomationProperties.SetName(this, "Level");
    }

    private void Layout(Size size)
    {
        double height = Math.Max((size.Height - Gap * (Segments - 1)) / Segments, 0);
        for (int i = 0; i < Segments; i++)
        {
            leds[i].Width = size.Width;
            leds[i].Height = height;
            Canvas.SetTop(leds[i], size.Height - (i + 1) * height - i * Gap);
        }
    }

    public void Show(in MeterStore.Level channel, bool dimmed)
    {
        int lit = SegmentIndex(channel.Db);
        int hold = SegmentIndex(channel.Hold);
        bool clipping = channel.Clipping;
        for (int i = 0; i < Segments; i++)
        {
            bool on = i < lit || (i == hold - 1 && hold > 0) || (i == Segments - 1 && clipping);
            double opacity = on ? (dimmed ? 0.3 : 1) : 0.09;
            if (leds[i].Opacity != opacity) leds[i].Opacity = opacity;
        }
        AutomationProperties.SetItemStatus(this, channel.Db <= Floor ? "Silent" : $"{channel.Db:0} dB");
    }

    /// <summary>Number of lit segments for a level.</summary>
    public static int SegmentIndex(float db) => (int)MathF.Floor((Math.Max(db, Floor) - Floor) / 2);

    public static double Fraction(float db) => (Math.Max(db, Floor) - Floor) / -Floor;

    internal static SolidColorBrush Brush(string key) => (SolidColorBrush)Application.Current.Resources[key];
}

/// <summary>dBFS labels aligned to <see cref="LedMeter"/>.</summary>
public sealed partial class MeterScale : UserControl
{
    private static readonly int[] Marks = [0, -6, -12, -18, -30, -45];
    private readonly Canvas canvas = new();
    private readonly TextBlock[] labels;

    public MeterScale()
    {
        Width = 18;
        Content = canvas;
        var style = (Style)Application.Current.Resources["ScaleText"];
        labels = Marks.Select(db => new TextBlock { Text = db.ToString(), Style = style }).ToArray();
        foreach (var label in labels) canvas.Children.Add(label);
        SizeChanged += (_, e) => Layout(e.NewSize);
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
    }

    private void Layout(Size size)
    {
        for (int i = 0; i < Marks.Length; i++)
        {
            var label = labels[i];
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double y = (1 - LedMeter.Fraction(Marks[i])) * size.Height;
            Canvas.SetLeft(label, (size.Width - label.DesiredSize.Width) / 2);
            Canvas.SetTop(label, y - label.DesiredSize.Height / 2);
        }
    }
}
