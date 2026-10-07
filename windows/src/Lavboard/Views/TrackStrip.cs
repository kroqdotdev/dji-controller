using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Lavboard.Controls;
using Lavboard.Core;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>
/// One mixer channel, laid out like TrackStrip in the macOS app: tape, source and battery, meters and
/// fader, level, mute key, gain, an optional balance row and the venue send. `compact` drops row
/// labels when the desk is crowded; the balance row is reserved on every strip whenever any track
/// is stereo, so the mute keys line up.
/// </summary>
public sealed partial class TrackStrip : UserControl
{
    private const double RowGap = 12;

    private readonly AppModel app;
    public Track Track { get; }

    private int index;
    private bool compact;
    private bool balanceRow;

    private readonly TapeLabel tape = new();
    private readonly TextBlock caption;
    private readonly BatteryGlyph battery = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock latency;
    private readonly LedMeter left = new(), right = new();
    private readonly Fader fader = new();
    private readonly Grid meterRow;
    private readonly Border missing;
    private readonly TextBlock missingText;
    private readonly TextBlock level;
    private readonly KeyButton mute = new();
    private readonly GainStepper stepper = new();
    private readonly LabeledRow gainRow;
    private readonly TextBlock gainCaption;
    private readonly ContentControl gainHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, Height = 22 };
    private readonly BalanceControl balance = new();
    private readonly LabeledRow balanceControlRow;
    private readonly Border balanceSlot = new() { Height = 22 };
    private readonly KeyButton venue = new() { Compact = true };
    private readonly LabeledRow venueRow;
    private readonly Border panel;

    public TrackStrip(AppModel app, Track track)
    {
        this.app = app;
        Track = track;
        var resources = Application.Current.Resources;

        caption = new TextBlock { Style = (Style)resources["StripLabelText"], TextTrimming = TextTrimming.CharacterEllipsis };
        latency = new TextBlock { Style = (Style)resources["StripLabelText"], Visibility = Visibility.Collapsed };
        var info = new Grid { Height = 18, ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        var badges = new Grid { Children = { battery, latency } };
        Grid.SetColumn(badges, 1);
        info.Children.Add(caption);
        info.Children.Add(badges);

        // Meters and fader share the height; the scale and LEDs line up with the fader travel.
        var meters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Children = { left, right } };
        meterRow = new Grid
        {
            ColumnSpacing = 6, HorizontalAlignment = HorizontalAlignment.Center,
            ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition { Width = GridLength.Auto } },
        };
        var scale = new MeterScale();
        Grid.SetColumn(meters, 1);
        Grid.SetColumn(fader, 2);
        meterRow.Children.Add(scale);
        meterRow.Children.Add(meters);
        meterRow.Children.Add(fader);
        missingText = new TextBlock
        {
            FontFamily = (FontFamily)resources["InterMedium"], FontWeight = FontWeights.Medium, FontSize = 12,
            Foreground = LedMeter.Brush("ConsoleSilk"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords,
        };
        missing = new Border
        {
            Background = LedMeter.Brush("ConsoleWell"), CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 6, 10, 6),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = missingText, Visibility = Visibility.Collapsed,
        };
        var meterZone = new Grid { Children = { meterRow, missing } };

        level = new TextBlock { Style = (Style)resources["ValueText"] };

        mute.LitBackground = LedMeter.Brush("ConsoleRed");
        mute.LitForeground = new SolidColorBrush(Microsoft.UI.Colors.White);
        mute.Click += (_, _) => app.ToggleMute(index);

        gainRow = new LabeledRow("Mic gain", stepper);
        gainCaption = new TextBlock { Style = (Style)resources["CaptionText"] };
        stepper.Step += (_, direction) => StepGain(direction);

        var balanceContent = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 5,
            Children = { ScaleLetter("L"), balance, ScaleLetter("R") },
        };
        balanceControlRow = new LabeledRow("Balance", balanceContent);
        balance.ValueChanged += (_, v) => Track.Balance = v;

        venue.LitBackground = LedMeter.Brush("ConsoleEngraving");
        venue.LitForeground = LedMeter.Brush("ConsoleInk");
        venue.Click += (_, _) => Track.SendToVenue = !Track.SendToVenue;
        AutomationProperties.SetName(venue, "Venue send");
        venueRow = new LabeledRow("Venue", venue, fillWhenCompact: true);

        fader.ValueChanged += (_, v) => Track.FaderDb = v;

        var rows = new Grid();
        int row = 0;
        void Add(FrameworkElement element, GridLength height, bool gapAbove = true)
        {
            rows.RowDefinitions.Add(new RowDefinition { Height = height });
            if (gapAbove) element.Margin = new Thickness(0, RowGap, 0, 0);
            Grid.SetRow(element, row++);
            rows.Children.Add(element);
        }
        Add(tape, GridLength.Auto, gapAbove: false);
        Add(info, GridLength.Auto);
        Add(meterZone, new GridLength(1, GridUnitType.Star));
        Add(level, GridLength.Auto);
        Add(mute, GridLength.Auto);
        Add(gainHost, GridLength.Auto);
        var balanceHost = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        Add(balanceHost, GridLength.Auto);
        Add(venueRow, GridLength.Auto);
        this.balanceHost = balanceHost;

        panel = new Border { Background = LedMeter.Brush("ConsolePanel"), CornerRadius = new CornerRadius(10), Child = rows };
        Content = panel;

        tape.Click += (_, _) => TrackEditor.Show(app, Track, tape);
        ContextFlyout = TrackMenu.Create(app, Track, () => TrackEditor.Show(app, Track, tape));

        // Not tied to Loaded and Unloaded: the desk re-adds kept strips when tracks change, and
        // WinUI may raise Unloaded after the new Loaded. The desk calls Detach when a track goes.
        Track.PropertyChanged += OnTrackChanged;
        app.Engine.Changed += OnEngineChanged;
        foreach (var system in app.MicSystems) system.PropertyChanged += OnSystemChanged;
    }

    /// <summary>Stops following the track and the engine, once the track is removed.</summary>
    public void Detach()
    {
        Track.PropertyChanged -= OnTrackChanged;
        app.Engine.Changed -= OnEngineChanged;
        foreach (var system in app.MicSystems) system.PropertyChanged -= OnSystemChanged;
    }

    private readonly ContentControl balanceHost;

    private static TextBlock ScaleLetter(string letter)
    {
        var text = new TextBlock { Text = letter, Style = (Style)Application.Current.Resources["ScaleText"], VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(text, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return text;
    }

    private void OnTrackChanged(object? sender, PropertyChangedEventArgs e) => Refresh();
    private void OnEngineChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);
    private void OnSystemChanged(object? sender, PropertyChangedEventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Position on the desk, strip width and whether the desk is crowded.</summary>
    public void Place(int index, double width, bool compact, bool balanceRow)
    {
        this.index = index;
        this.compact = compact;
        this.balanceRow = balanceRow;
        Width = width;
        double padding = compact ? 10 : 12;
        panel.Padding = new Thickness(padding);
        // Label, its minimum spacer and the L and R letters take the rest of the row.
        balance.Width = Math.Clamp(width - 2 * padding - (compact ? 0 : 46) - 22, 56, 96);
        Refresh();
    }

    public void ShowMeters(MeterStore meters)
    {
        left.Show(meters.Left[index], Track.Muted);
        if (Track.Source.IsStereo) right.Show(meters.Right[index], Track.Muted);
    }

    private void Refresh()
    {
        var source = Track.Source;
        bool available = app.Engine.IsTrackAvailable(index);
        tape.Show(string.IsNullOrEmpty(Track.Name) ? $"Track {index + 1}" : Track.Name, Track.Color, source.ChannelLabel);

        caption.Text = Caption(source);
        battery.Show(source is TransmitterSource ? app.Transmitter(source) : null);
        double? ms = app.Engine.TrackLatencyMs(index);
        latency.Visibility = source is not TransmitterSource && ms is not null ? Visibility.Visible : Visibility.Collapsed;
        if (ms is double m)
        {
            latency.Text = $"+{Math.Round(m)} ms";
            ToolTipService.SetToolTip(latency, $"Runs about {Math.Round(m)} ms behind the other inputs: this device has its own clock, so its audio is converted to 48 kHz.");
        }

        left.Width = source.IsStereo ? 7 : 12;
        right.Width = 7;
        right.Visibility = source.IsStereo ? Visibility.Visible : Visibility.Collapsed;
        meterRow.Opacity = available ? 1 : 0.35;
        missing.Visibility = available ? Visibility.Collapsed : Visibility.Visible;
        missingText.Text = MissingMessage(source);

        if (fader.Value != Track.FaderDb) fader.Value = Track.FaderDb;
        AutomationProperties.SetName(fader, $"{Track.Name} level");
        level.Text = Decibels.Label(Track.FaderDb);

        mute.Lit = Track.Muted;
        mute.Content = Track.Muted ? "Muted" : "Mute";
        mute.Legend = compact ? null : (index + 1).ToString();
        ToolTipService.SetToolTip(mute, $"Mute {Track.Name}. Shortcut: {index + 1}");

        RefreshGain();

        if (!balanceRow) balanceHost.Visibility = Visibility.Collapsed;
        else
        {
            balanceHost.Visibility = Visibility.Visible;
            balanceHost.Content = source.IsStereo ? balanceControlRow : balanceSlot;
            balanceControlRow.Compact = compact;
            balance.Value = Track.Balance;
            AutomationProperties.SetName(balance, $"{Track.Name} balance");
        }

        venue.Lit = Track.SendToVenue;
        venue.Content = compact ? "Venue" : (Track.SendToVenue ? "On" : "Off");
        venue.Width = compact ? double.NaN : 58;
        venue.HorizontalAlignment = compact ? HorizontalAlignment.Stretch : HorizontalAlignment.Right;
        AutomationProperties.SetItemStatus(venue, Track.SendToVenue ? "On" : "Off");
        ToolTipService.SetToolTip(venue, $"Send {Track.Name} to the venue output");
        venueRow.Compact = compact;
    }

    private void RefreshGain()
    {
        var source = Track.Source;
        if (source is TransmitterSource t && app.MicSystem(t.System) is { Gain: { } gain })
        {
            var state = app.Transmitter(source);
            double value = state?.PendingGainDb ?? state?.GainDb ?? 0;
            stepper.Show(GainLabel(value, gain.Step), state?.Connected ?? false, state?.PendingGainDb != null, value > gain.Min, value < gain.Max);
            ShowGainRow("Mic gain", "Gain on the transmitter itself. It changes the signal everywhere, including recordings and the receiver's own outputs.");
            return;
        }
        if (source is DeviceSource d && app.Engine.DeviceGain(d) is { } input)
        {
            // Rounded -0.4 dB would read "-0 dB"; whole dB, as on the Mac, with zero unsigned.
            double shown = Math.Round(input.Db) is var whole && whole == 0 ? 0 : whole;
            stepper.Show($"{shown:0} dB", true, false, input.Db > input.Min, input.Db < input.Max);
            ShowGainRow("Input gain", "The device's own input gain");
            return;
        }
        (gainCaption.Text, string help) = source switch
        {
            _ when source.IsTap => (compact ? "Level in app" : "Set the level in the app", "Lavboard records what the app plays; change its volume in the app itself"),
            TransmitterSource => (compact ? "Gain on mic" : "Set gain on the mic", "Lavboard can't change this transmitter's gain"),
            _ => (compact ? "Gain on device" : "Set gain on the device", "This device doesn't let apps change its gain"),
        };
        ToolTipService.SetToolTip(gainCaption, help);
        gainHost.Content = gainCaption;
    }

    private void ShowGainRow(string title, string help)
    {
        gainRow.Title = title;
        gainRow.Compact = compact;
        ToolTipService.SetToolTip(gainRow, help);
        gainHost.Content = gainRow;
    }

    private void StepGain(int direction)
    {
        switch (Track.Source)
        {
            case TransmitterSource t when app.MicSystem(t.System) is { Gain: { } gain } system:
                var state = app.Transmitter(Track.Source);
                double value = state?.PendingGainDb ?? state?.GainDb ?? 0;
                system.SetGain(Math.Clamp(value + direction * gain.Step, gain.Min, gain.Max), t.Slot);
                break;
            case DeviceSource d when app.Engine.DeviceGain(d) is { } input:
                app.Engine.SetDeviceGain(d, Math.Clamp(input.Db + direction, input.Min, input.Max));
                Refresh();
                break;
        }
    }

    public static string GainLabel(double db, double step)
    {
        if (db == 0) return "0 dB";
        return step == Math.Round(step) ? $"{db:+0;-0} dB" : $"{db:+0.0;-0.0} dB";
    }

    private string Caption(TrackSource source) => source switch
    {
        DeviceSource d => compact ? d.ChannelLabel : $"{SourceNames.ShortDeviceName(d.Name)}, {d.ChannelLabel}",
        _ => source.ChannelLabel,
    };

    private string MissingMessage(TrackSource source) => source switch
    {
        TransmitterSource t => app.Engine.IsReceiverPresent(t.System) ? $"No channel for TX{t.Slot + 1} in this mode" : "Receiver not connected",
        DeviceSource d => $"Plug in {d.Name}",
        AppSource a => $"Open {a.Name}",
        _ => "PC audio unavailable",
    };
}
