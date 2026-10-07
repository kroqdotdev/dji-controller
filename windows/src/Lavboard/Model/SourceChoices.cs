using Lavboard.Core;

namespace Lavboard.Model;

/// <summary>One entry in the source picker.</summary>
public sealed record SourceChoice(TrackSource Source, string Title, string DefaultName, bool InUse, string? Note = null);

/// <summary>A heading in the source picker: a mic system, an input device, or app audio.</summary>
public sealed record SourceGroup(string Title, IReadOnlyList<SourceChoice> Options, string? Note = null);

/// <summary>An app that has opened audio, for app audio tracks.</summary>
public sealed record AudioApp(string AppId, string Name, bool Playing);

public sealed partial class AppModel
{
    /// <summary>Everything a track could use right now, marking sources other tracks already use.</summary>
    public IReadOnlyList<SourceGroup> SourceChoices()
    {
        var used = Tracks.Select(t => t.Source.Identity).ToHashSet();
        var groups = new List<SourceGroup>();
        foreach (var system in MicSystems.Where(IsReceiverPresent))
        {
            var options = Enumerable.Range(0, system.TransmitterCount).Select(slot =>
            {
                var source = new TransmitterSource(system.Id, slot);
                // Only a module with a control link knows whether a transmitter is on.
                bool off = system.IsConnected && slot < system.Transmitters.Count && !system.Transmitters[slot].Connected;
                return new SourceChoice(source, $"TX{slot + 1}", $"Mic {slot + 1}", used.Contains(source.Identity), off ? "Off" : null);
            }).ToList();
            groups.Add(new SourceGroup(system.Name, options));
        }
        foreach (var device in Engine.Inputs.Where(d => d.Channels > 0))
        {
            int channels = device.Channels;
            SourceChoice Choice(int channel, bool stereo, string title)
            {
                var source = new DeviceSource(device.Id, device.Name, channel, stereo);
                return new SourceChoice(source, title, SourceNames.DefaultName(device.Name, channel, stereo, channels), used.Contains(source.Identity));
            }
            var options = new List<SourceChoice>();
            if (channels == 1) options.Add(Choice(0, false, "Mono input"));
            else
            {
                for (int c = 0; c < channels; c++) options.Add(Choice(c, false, $"Input {c + 1}"));
                for (int c = 0; c + 1 < channels; c += 2) options.Add(Choice(c, true, $"Inputs {c + 1} and {c + 2}, stereo"));
            }
            groups.Add(new SourceGroup(device.Name, options, OwnClockNote(device)));
        }
        return groups;
    }

    /// <summary>All PC audio, then each app that has opened audio.</summary>
    public IReadOnlyList<SourceChoice> AppAudioChoices()
    {
        var used = Tracks.Select(t => t.Source.Identity).ToHashSet();
        var all = new SystemAudioSource();
        var choices = new List<SourceChoice> { new(all, "All PC audio", "PC audio", used.Contains(all.Identity)) };
        foreach (var app in Engine.Apps)
        {
            var source = new AppSource(app.AppId, app.Name);
            choices.Add(new SourceChoice(source, app.Name, app.Name, used.Contains(source.Identity), app.Playing ? "Playing" : null));
        }
        return choices;
    }

    /// <summary>What to expect from a device that can't run on the engine's 48 kHz clock.</summary>
    public static string? OwnClockNote(Core.AudioDevice device) =>
        device.SampleRate == 48_000 ? null : $"Converted from {Kilohertz(device.SampleRate)}, slightly behind the other inputs.";

    public static string Kilohertz(double rate)
    {
        double khz = rate / 1000;
        return khz == Math.Round(khz) ? $"{khz:0} kHz" : $"{khz:0.0} kHz";
    }

    public string SourceDescription(TrackSource source) => source switch
    {
        TransmitterSource t => $"{MicSystem(t.System)?.Name ?? "Wireless receiver"}, {source.ChannelLabel}",
        DeviceSource d => $"{d.Name}, {source.ChannelLabel}",
        AppSource a => $"{a.Name}, app audio",
        _ => "All PC audio",
    };

    public void SetSource(Track track, TrackSource source)
    {
        if (!CanEditTracks) return;
        track.Source = source;
        if (!source.IsStereo) track.Balance = 0;
    }
}
