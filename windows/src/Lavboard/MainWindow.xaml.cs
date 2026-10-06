using Lavboard.Core;
using Lavboard.Core.Interop;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace Lavboard;

/// <summary>One endpoint as the device lists show it.</summary>
public sealed record DeviceRow(string Name, string Detail)
{
    public static DeviceRow From(AudioDevice device)
    {
        var parts = new List<string> { device.Channels == 1 ? "1 channel" : $"{device.Channels} channels", $"{device.SampleRate / 1000.0:0.#} kHz" };
        if (device.IsDefault) parts.Add("default");
        return new DeviceRow(device.Name, string.Join(", ", parts));
    }
}

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(1100, 700));
        Refresh();
    }

    private void Refresh()
    {
        try
        {
            int version = Native.LbEngineVersion();
            if (version != Native.ExpectedEngineVersion)
            {
                Subtitle.Text = $"This build expects engine {Native.ExpectedEngineVersion}, but found {version}. Reinstall Lavboard.";
                return;
            }
            var devices = AudioDevices.List();
            var inputs = devices.Where(d => d.IsInput).Select(DeviceRow.From).ToList();
            var outputs = devices.Where(d => !d.IsInput).Select(DeviceRow.From).ToList();
            InputList.ItemsSource = inputs;
            OutputList.ItemsSource = outputs;
            NoInputs.Visibility = inputs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            NoOutputs.Visibility = outputs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            Subtitle.Text = $"Windows preview, engine {version}. {Describe(inputs.Count, "input")} and {Describe(outputs.Count, "output")}.";
        }
        catch (DllNotFoundException)
        {
            Subtitle.Text = "The audio engine (LavboardEngine.dll) is missing. Reinstall Lavboard.";
        }
    }

    private static string Describe(int count, string noun) => count == 1 ? $"1 {noun}" : $"{count} {noun}s";
}
