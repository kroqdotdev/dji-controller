namespace Lavboard.Core;

/// <summary>Short names for tracks and strip captions, from device names.</summary>
public static class SourceNames
{
    private static readonly HashSet<string> Filler = new(StringComparer.OrdinalIgnoreCase)
    {
        "microphone", "mic", "audio", "usb", "usb2.0", "usb-c", "2.0", "input", "stream", "webcam", "device",
        // Windows endpoint names add these: "Headset Microphone (Jabra Evolve2 65)", "Line In (Realtek(R) Audio)".
        "headset", "line", "in",
    };

    /// <summary>
    /// A short tape-friendly default name: drops filler words, keeps two words, and adds the input
    /// number when a device has several inputs. Same rules as Track.defaultName in the macOS app.
    /// </summary>
    public static string DefaultName(string deviceName, int channel, bool stereo, int deviceChannels)
    {
        string plain = deviceName.Replace("(R)", "").Replace("(TM)", "").Replace('(', ' ').Replace(')', ' ');
        var all = plain.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // "Mads's AirPods Pro" names the owner, not the mic.
        var words = all.Where(w => !Filler.Contains(w) && !w.EndsWith("'s") && !w.EndsWith("’s"));
        string name = string.Join(' ', words.Take(2));
        if (name.Length == 0) name = all.FirstOrDefault() ?? "Input";
        if (stereo && deviceChannels > 2) name += $" {channel + 1}+{channel + 2}";
        else if (!stereo && deviceChannels > 1) name += $" {channel + 1}";
        return name;
    }

    /// <summary>A device name shortened the same way, without an input number.</summary>
    public static string ShortDeviceName(string deviceName) => DefaultName(deviceName, 0, false, 1);
}
