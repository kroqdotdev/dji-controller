using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Lavboard.Controls;
using Lavboard.Core;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>Output strip: picks its device and sets its level. Same layout as MasterStrip in the macOS app.</summary>
public sealed partial class MasterStrip : UserControl
{

    private readonly AppModel app;
    private readonly string title;
    private readonly Func<string?> getDevice;
    private readonly Action<string?> setDevice;
    private readonly Func<double> getLevel;
    private readonly Action<double> setLevel;
    private readonly string? excluding;

    private readonly TextBlock deviceLabel;
    private readonly LedMeter meter = new() { Width = 12 };
    private readonly Fader fader = new();
    private readonly TextBlock level;
    private readonly TextBlock note;
    private readonly KeyButton action = new() { Lit = true, Compact = true, Visibility = Visibility.Collapsed };
    private bool hasDevice;

    public MasterStrip(AppModel app, string title, Func<string?> getDevice, Action<string?> setDevice,
                       Func<double> getLevel, Action<double> setLevel, string? excluding = null)
    {
        this.app = app;
        this.title = title;
        this.getDevice = getDevice;
        this.setDevice = setDevice;
        this.getLevel = getLevel;
        this.setLevel = setLevel;
        this.excluding = excluding;
        var resources = Application.Current.Resources;
        Width = DeskLayout.MasterWidth;

        var heading = new TextBlock
        {
            Text = title, FontFamily = (FontFamily)resources["InterSemiBold"], FontWeight = FontWeights.SemiBold, FontSize = 15,
            Foreground = LedMeter.Brush("ConsoleSilk"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 6),
        };

        // A borderless pop-up menu: the device name with a small chevron.
        deviceLabel = new TextBlock { Style = (Style)resources["StripLabelText"], Foreground = LedMeter.Brush("ConsoleSilk") };
        var chevron = new FontIcon
        {
            Glyph = "", FontSize = 8, FontWeight = FontWeights.Bold, Foreground = LedMeter.Brush("ConsoleSilk"), Margin = new Thickness(3, 1, 0, 0),
        };
        var label = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            ColumnDefinitions = { new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }, new ColumnDefinition { Width = GridLength.Auto } },
        };
        Grid.SetColumn(chevron, 1);
        label.Children.Add(deviceLabel);
        label.Children.Add(chevron);
        var picker = new Button { Style = (Style)resources["PlainButton"], Content = label, HorizontalAlignment = HorizontalAlignment.Stretch };
        ToolTipService.SetToolTip(picker, $"Choose where the {title.ToLowerInvariant()} mix goes");
        AutomationProperties.SetName(picker, $"{title} output");
        var menu = new MenuFlyout();
        menu.Opening += (_, _) => FillDevices(menu);
        picker.Flyout = menu;

        var meters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Children = { meter, fader } };
        fader.ValueChanged += (_, v) => { setLevel(v); Refresh(); };
        AutomationProperties.SetName(fader, $"{title} level");

        level = new TextBlock { Style = (Style)resources["ValueText"] };
        note = new TextBlock
        {
            FontSize = 11, Foreground = LedMeter.Brush("ConsoleEngraving"), TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center,
        };
        action.Click += (_, _) => pendingAction?.Invoke();
        var notes = new StackPanel { Spacing = 8, Height = 62, Children = { note, action } };

        var rows = new Grid { RowSpacing = 12 };
        UIElement[] children = [heading, picker, meters, level, notes];
        for (int i = 0; i < children.Length; i++)
        {
            rows.RowDefinitions.Add(new RowDefinition { Height = i == 2 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            Grid.SetRow((FrameworkElement)children[i], i);
            rows.Children.Add(children[i]);
        }
        Content = new Border { Background = LedMeter.Brush("ConsolePanel"), CornerRadius = new CornerRadius(10), Padding = new Thickness(12), Child = rows };

        var context = new MenuFlyout();
        context.Opening += (_, _) =>
        {
            context.Items.Clear();
            context.Items.Add(TrackMenu.Item("Reset level to 0 dB", () => { setLevel(0); Refresh(); }, getLevel() != 0));
        };
        ContextFlyout = context;

        // The output strips live as long as the window.
        app.Engine.Changed += OnEngineChanged;
        Refresh();
    }

    /// <summary>The note under the level, and an optional action key ("Set up").</summary>
    public void ShowNote(string? text, string? actionTitle = null, Action? run = null)
    {
        note.Text = text ?? "";
        note.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
        action.Content = actionTitle;
        action.Visibility = actionTitle != null && run != null ? Visibility.Visible : Visibility.Collapsed;
        pendingAction = run;
    }

    private Action? pendingAction;

    private void OnEngineChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private IEnumerable<Core.AudioDevice> Choices => app.Engine.Outputs.Where(o => o.Id != excluding);

    public void Refresh()
    {
        string? device = getDevice();
        var current = Choices.FirstOrDefault(o => o.Id == device);
        hasDevice = current != null;
        deviceLabel.Text = current?.Name ?? (device == null ? "Off" : "Unavailable");
        double value = getLevel();
        if (fader.Value != value) fader.Value = value;
        level.Text = Decibels.Label(value);
    }

    public void ShowMeter(in MeterStore.Level channel) => meter.Show(channel, !hasDevice);

    private void FillDevices(MenuFlyout menu)
    {
        menu.Items.Clear();
        string? device = getDevice();
        void Add(string text, string? id)
        {
            var item = new RadioMenuFlyoutItem { Text = text, GroupName = title, IsChecked = id == device };
            item.Click += (_, _) => { setDevice(id); Refresh(); };
            menu.Items.Add(item);
        }
        Add("Off", null);
        foreach (var output in Choices) Add(output.Name, output.Id);
        if (device != null && Choices.All(o => o.Id != device)) Add("Unavailable device", device);
    }
}
