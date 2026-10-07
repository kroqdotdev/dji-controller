using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;
using Lavboard.Core;
using Lavboard.Model;

namespace Lavboard.Controls;

/// <summary>Vertical fader in dB; the bottom of the travel is silence. Drag to move, double-click for 0 dB.</summary>
public sealed partial class Fader : UserControl
{
    public const double Minimum = -60;
    public const double Maximum = 12;
    private const double CapHeight = 26;

    public static readonly DependencyProperty ValueProperty =
        DependencyProperty.Register(nameof(Value), typeof(double), typeof(Fader), new PropertyMetadata(0.0, (d, e) => ((Fader)d).OnValueChanged((double)e.OldValue)));

    private readonly Canvas canvas = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    private readonly Rectangle track = new() { Width = 6, RadiusX = 2, RadiusY = 2, Fill = LedMeter.Brush("ConsoleWell") };
    private readonly Rectangle zeroTick = new() { Width = 22, Height = 1, Fill = LedMeter.Brush("ConsoleEngraving") };
    private readonly Border cap = new()
    {
        Width = 36, Height = CapHeight, CornerRadius = new CornerRadius(3), Background = LedMeter.Brush("ConsoleEngraving"),
        Child = new Rectangle { Height = 2, Fill = LedMeter.Brush("ConsoleInk"), VerticalAlignment = VerticalAlignment.Center },
    };
    private double? dragStart;
    private double dragOriginY;

    public Fader()
    {
        Width = 40;
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        Content = canvas;
        canvas.Children.Add(track);
        canvas.Children.Add(zeroTick);
        canvas.Children.Add(cap);
        SizeChanged += (_, _) => Layout();
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += (_, e) => { dragStart = null; ReleasePointerCapture(e.Pointer); };
        PointerCaptureLost += (_, _) => dragStart = null;
        DoubleTapped += (_, e) => { Value = 0; e.Handled = true; };
        KeyDown += OnKeyDown;
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeNorthSouth);
    }

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public event EventHandler<double>? ValueChanged;

    private double Travel => Math.Max(ActualHeight - CapHeight, 1);

    private void OnValueChanged(double old)
    {
        Layout();
        AutomationProperties.SetItemStatus(this, Decibels.Label(Value));
        if (FrameworkElementAutomationPeer.FromElement(this) is FaderAutomationPeer peer)
            peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, old, Value);
        ValueChanged?.Invoke(this, Value);
    }

    private void Layout()
    {
        double h = ActualHeight, w = ActualWidth;
        if (h <= 0) return;
        double span = Maximum - Minimum;
        double position = (Value - Minimum) / span;
        double zero = (0 - Minimum) / span;
        track.Height = Math.Max(h - CapHeight, 0);
        Canvas.SetLeft(track, (w - track.Width) / 2);
        Canvas.SetTop(track, CapHeight / 2);
        Canvas.SetLeft(zeroTick, (w - zeroTick.Width) / 2);
        Canvas.SetTop(zeroTick, h - (zero * Travel + CapHeight / 2) - 1);
        Canvas.SetLeft(cap, (w - cap.Width) / 2);
        Canvas.SetTop(cap, h - position * Travel - CapHeight);
    }

    /// <summary>Clamped to the range and rounded to half a dB, as on the Mac.</summary>
    internal void Apply(double next) => Value = Math.Round(Math.Clamp(next, Minimum, Maximum) * 2) / 2;

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        dragStart = Value;
        dragOriginY = e.GetCurrentPoint(this).Position.Y;
        CapturePointer(e.Pointer);
        Focus(FocusState.Pointer);
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (dragStart is not double start) return;
        double dy = e.GetCurrentPoint(this).Position.Y - dragOriginY;
        Apply(start - dy / Travel * (Maximum - Minimum));
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        double step = e.Key switch { VirtualKey.Up or VirtualKey.Right => 1, VirtualKey.Down or VirtualKey.Left => -1, VirtualKey.PageUp => 6, VirtualKey.PageDown => -6, _ => 0 };
        if (step == 0) return;
        Apply(Value + step);
        e.Handled = true;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new FaderAutomationPeer(this);
}

/// <summary>Presents the fader to screen readers as an adjustable level in dB.</summary>
public sealed partial class FaderAutomationPeer(Fader owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
{
    private Fader Fader => (Fader)Owner;
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
    protected override object? GetPatternCore(PatternInterface pattern) => pattern == PatternInterface.RangeValue ? this : base.GetPatternCore(pattern);
    public bool IsReadOnly => false;
    public double LargeChange => 6;
    public double SmallChange => 1;
    public double Maximum => Lavboard.Controls.Fader.Maximum;
    public double Minimum => Lavboard.Controls.Fader.Minimum;
    public double Value => Fader.Value;
    public void SetValue(double value) => Fader.Apply(value);
}
