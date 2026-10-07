using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Lavboard.Controls;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>
/// The Settings popover, laid out like the macOS grouped form: each section a rounded box of rows
/// with its heading above and its footer below. Mic systems contribute the settings they declare.
/// </summary>
public sealed partial class SettingsView : UserControl
{
    private readonly AppModel app;
    private readonly StackPanel sections = new() { Width = 380, Padding = new Thickness(18), Spacing = 18 };

    public SettingsView(AppModel app)
    {
        this.app = app;
        Content = sections;
        foreach (var system in app.MicSystems) system.PropertyChanged += OnSystemChanged;
        app.PropertyChanged += OnAppChanged;
        Build();
    }

    private void OnAppChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppModel.IsRecording)) Build();
    }

    private void OnSystemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(IMicSystem.Settings) or nameof(IMicSystem.IsConnected)) DispatcherQueue.TryEnqueue(Build);
    }

    private void Build()
    {
        sections.Children.Clear();
        foreach (var system in app.ActiveMicSystems.Where(s => s.Settings.Count > 0))
            sections.Children.Add(Section(system.Name, system.Settings.Select(s => Row(s.Title, Control(system, s))), system.SettingsNote));

        var buffer = new PopUpButton
        {
            Choices = AppModel.BufferChoices.Select(f => $"{f} samples").ToList(),
            SelectedIndex = Math.Max(0, AppModel.BufferChoices.ToList().IndexOf(app.BufferFrames)),
        };
        AutomationProperties.SetName(buffer, "Audio buffer");
        // A new buffer size rebuilds the engine, which would leave a gap in a recording.
        buffer.IsEnabled = !app.IsRecording;
        buffer.SelectionChanged += (_, i) => app.BufferFrames = AppModel.BufferChoices[i];
        sections.Children.Add(Section(null, [Row("Audio buffer", buffer)], "Smaller buffers lower the delay but use more CPU."));

        // Windows has no app menu for "Check for Updates…", so it lives here.
        var check = new Button { Content = "Check for updates", FontSize = 13, IsEnabled = app.Updates.IsInstalled };
        check.Click += (_, _) => app.Updates.CheckNow();
        sections.Children.Add(Section(null, [Row($"Lavboard {app.Updates.CurrentVersion}", check)],
            app.Updates.IsInstalled ? "Lavboard checks for updates every time it starts." : "Development builds don't update themselves."));
    }

    private static FrameworkElement Control(IMicSystem system, MicSetting setting)
    {
        if (setting.IsToggle)
        {
            var toggle = new ToggleButton
            {
                Style = (Style)Application.Current.Resources["MacSwitch"], IsChecked = setting.On ?? false, IsEnabled = setting.IsKnown,
            };
            AutomationProperties.SetName(toggle, setting.Title);
            toggle.Click += (_, _) => system.SetToggle(setting.Id, toggle.IsChecked == true);
            return toggle;
        }
        var segmented = new Segmented(setting.Choices!.Select(c => (c.Id, c.Name)))
        {
            Selected = setting.Choice ?? setting.Choices!.FirstOrDefault()?.Id, IsEnabled = setting.IsKnown,
        };
        AutomationProperties.SetName(segmented, setting.Title);
        segmented.SelectionChanged += (_, id) => system.SetChoice(setting.Id, id);
        return segmented;
    }

    private static Grid Row(string title, FrameworkElement control)
    {
        var row = new Grid { MinHeight = 30, ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        row.Children.Add(new TextBlock { Text = title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Foreground = LedMeter.Brush("ConsoleSilk") });
        Grid.SetColumn(control, 1);
        control.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(control);
        return row;
    }

    private static StackPanel Section(string? heading, IEnumerable<FrameworkElement> rows, string? footer)
    {
        var resources = Application.Current.Resources;
        var section = new StackPanel { Spacing = 6 };
        if (heading != null)
            section.Children.Add(new TextBlock
            {
                Text = heading, FontFamily = (FontFamily)resources["InterSemiBold"], FontWeight = FontWeights.SemiBold, FontSize = 13,
                Foreground = LedMeter.Brush("ConsoleSilk"), Margin = new Thickness(10, 0, 10, 2),
            });
        var box = new StackPanel();
        foreach (var row in rows)
        {
            if (box.Children.Count > 0) box.Children.Add(new Border { Height = 1, Background = (Brush)resources["FormSeparator"] });
            row.Margin = new Thickness(0, 4, 0, 4);
            box.Children.Add(row);
        }
        section.Children.Add(new Border { Background = (Brush)resources["PopUpFill"], CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 2, 8, 2), Child = box });
        if (footer != null)
            section.Children.Add(new TextBlock { Text = footer, Style = (Style)resources["PopoverNote"], FontSize = 11, Margin = new Thickness(10, 0, 10, 0) });
        return section;
    }
}
