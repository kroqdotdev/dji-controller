using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Lavboard.Model;

namespace Lavboard.Controls;

/// <summary>Left/right balance for stereo tracks. Drag the cap; double-click to centre.</summary>
public sealed partial class BalanceControl : UserControl
{
    private const double CapSize = 14;
    private readonly Canvas canvas = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    private readonly Rectangle track = new() { Height = 4, RadiusX = 2, RadiusY = 2, Fill = LedMeter.Brush("ConsoleWell") };
    private readonly Rectangle centre = new() { Width = 1, Height = 10, Fill = LedMeter.Brush("ConsoleEngraving") };
    private readonly Border cap = new() { Width = CapSize, Height = CapSize, CornerRadius = new CornerRadius(3), Background = LedMeter.Brush("ConsoleEngraving") };
    private double value;
    private double? dragStart;
    private double dragOriginX;

    public BalanceControl()
    {
        MinWidth = 56;
        MaxWidth = 96;
        Height = 22;
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        Content = canvas;
        canvas.Children.Add(track);
        canvas.Children.Add(centre);
        canvas.Children.Add(cap);
        SizeChanged += (_, _) => Layout();
        PointerPressed += (_, e) => { dragStart = value; dragOriginX = e.GetCurrentPoint(this).Position.X; CapturePointer(e.Pointer); e.Handled = true; };
        PointerMoved += (_, e) =>
        {
            if (dragStart is not double start) return;
            double travel = Math.Max(ActualWidth - CapSize, 1);
            Set(start + (e.GetCurrentPoint(this).Position.X - dragOriginX) / travel * 2);
        };
        PointerReleased += (_, e) => { dragStart = null; ReleasePointerCapture(e.Pointer); };
        DoubleTapped += (_, _) => Set(0);
        KeyDown += (_, e) =>
        {
            double step = e.Key switch { VirtualKey.Right or VirtualKey.Up => 0.1, VirtualKey.Left or VirtualKey.Down => -0.1, _ => 0 };
            if (step != 0) { Set(value + step); e.Handled = true; }
        };
    }

    public double Value { get => value; set { this.value = Math.Clamp(value, -1, 1); Layout(); Describe(); } }
    public event EventHandler<double>? ValueChanged;

    private void Set(double next)
    {
        Value = next;
        ValueChanged?.Invoke(this, Value);
    }

    private void Describe() =>
        AutomationProperties.SetItemStatus(this, value == 0 ? "Centre" : $"{Math.Abs(value) * 100:0}% {(value < 0 ? "left" : "right")}");

    private void Layout()
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0) return;
        track.Width = w;
        Canvas.SetTop(track, (h - track.Height) / 2);
        Canvas.SetLeft(centre, w / 2);
        Canvas.SetTop(centre, (h - centre.Height) / 2);
        Canvas.SetLeft(cap, (value + 1) / 2 * Math.Max(w - CapSize, 1));
        Canvas.SetTop(cap, (h - CapSize) / 2);
    }
}

/// <summary>Minus and plus around a value, for hardware or device gain.</summary>
public sealed partial class GainStepper : UserControl
{
    private readonly Button minus, plus;
    private readonly TextBlock label;

    public GainStepper()
    {
        minus = StepButton("", -1);
        plus = StepButton("", 1);
        label = new TextBlock
        {
            FontFamily = (FontFamily)Application.Current.Resources["InterSemiBold"], FontWeight = FontWeights.SemiBold, FontSize = 13,
            Foreground = LedMeter.Brush("ConsoleSilk"), MinWidth = 40, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Children = { minus, label, plus } };
    }

    public event EventHandler<int>? Step;

    public void Show(string text, bool enabled, bool faded, bool canDecrease, bool canIncrease)
    {
        label.Text = text;
        label.Opacity = faded ? 0.5 : 1;
        minus.IsEnabled = enabled && canDecrease;
        plus.IsEnabled = enabled && canIncrease;
        AutomationProperties.SetItemStatus(this, text);
    }

    private Button StepButton(string glyph, int direction)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["PlainButton"],
            Content = new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(6), Background = LedMeter.Brush("ConsoleWell"),
                Child = new FontIcon { Glyph = glyph, FontSize = 10, FontWeight = FontWeights.Bold, Foreground = LedMeter.Brush("ConsoleSilk") },
            },
        };
        AutomationProperties.SetName(button, direction < 0 ? "Decrease" : "Increase");
        button.Click += (_, _) => Step?.Invoke(this, direction);
        return button;
    }
}

/// <summary>A strip row with its label on the left, or just the control when the desk is crowded.</summary>
public sealed partial class LabeledRow : UserControl
{
    private readonly TextBlock title;
    private readonly bool fillWhenCompact;
    private readonly ContentPresenter presenter = new() { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };

    /// <summary><paramref name="fillWhenCompact"/>: the control spans the row once its label is gone (the venue key); otherwise it centres.</summary>
    public LabeledRow(string text, UIElement content, bool fillWhenCompact = false)
    {
        this.fillWhenCompact = fillWhenCompact;
        // 22 like the Mac's rows; the compact venue key (23) may grow its row by a point, where
        // SwiftUI lets it overhang instead.
        MinHeight = 22;
        title = new TextBlock { Text = text, Style = (Style)Application.Current.Resources["StripLabelText"] };
        presenter.Content = content;
        var grid = new Grid { ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        Grid.SetColumn(presenter, 1);
        grid.Children.Add(title);
        grid.Children.Add(presenter);
        Content = grid;
    }

    public string Title { set => title.Text = value; }

    public bool Compact
    {
        set
        {
            title.Visibility = value ? Visibility.Collapsed : Visibility.Visible;
            presenter.HorizontalAlignment = value ? HorizontalAlignment.Stretch : HorizontalAlignment.Right;
            presenter.HorizontalContentAlignment = !value ? HorizontalAlignment.Right
                : fillWhenCompact ? HorizontalAlignment.Stretch : HorizontalAlignment.Center;
        }
    }
}

/// <summary>Transmitter battery, as Segoe Fluent's battery glyphs (SF Symbols' battery.* on the Mac).</summary>
public sealed partial class BatteryGlyph : UserControl
{
    private readonly FontIcon icon = new() { FontSize = 20 };

    public BatteryGlyph() => Content = icon;

    public void Show(TransmitterState? state)
    {
        if (state is not { Connected: true, Battery: double battery }) { Visibility = Visibility.Collapsed; return; }
        Visibility = Visibility.Visible;
        int percent = (int)Math.Round(battery * 100);
        bool low = percent <= 20 && !state.Charging;
        icon.Glyph = state.Charging ? "" : percent > 80 ? "" : percent > 55 ? "" : percent > 30 ? "" : percent > 10 ? "" : "";
        icon.Foreground = LedMeter.Brush(low ? "ConsoleRed" : "ConsoleEngraving");
        string text = state.Charging ? "Charging" : $"Battery about {percent}%";
        ToolTipService.SetToolTip(this, text);
        AutomationProperties.SetName(this, state.Charging ? "Charging" : $"Battery about {percent} percent");
    }
}

/// <summary>The empty channel at the end of the desk: click to add a track.</summary>
public sealed partial class AddTrackSlot : Button
{
    public AddTrackSlot()
    {
        Style = (Style)Application.Current.Resources["PlainButton"];
        var engraving = LedMeter.Brush("ConsoleEngraving");
        Content = new Grid
        {
            Children =
            {
                new Rectangle { Stroke = LedMeter.Brush("ConsoleSlotStroke"), StrokeThickness = 1.5, StrokeDashArray = [4, 3.33], RadiusX = 10, RadiusY = 10 },
                new StackPanel
                {
                    Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        new FontIcon { Glyph = "", FontSize = 20, FontWeight = FontWeights.SemiBold, Foreground = engraving },
                        new TextBlock { Text = "Add track", FontFamily = (FontFamily)Application.Current.Resources["InterSemiBold"], FontWeight = FontWeights.SemiBold, FontSize = 12, Foreground = engraving },
                    },
                },
            },
        };
        AutomationProperties.SetName(this, "Add track");
        ToolTipService.SetToolTip(this, $"Add a mic or input (up to {Track.Maximum} tracks)");
    }
}
