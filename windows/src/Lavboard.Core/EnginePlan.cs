using Lavboard.Model;

namespace Lavboard.Core;

/// <summary>Where one track's audio comes from in a plan: channel (and channel + 1) of input <see cref="Input"/>.</summary>
public sealed record PlannedTrack(int Input, int Channel, bool Stereo)
{
    public static PlannedTrack Missing(bool stereo) => new(-1, -1, stereo);
    public bool IsAvailable => Input >= 0;
}

/// <summary>
/// What the engine should open for a set of tracks and outputs: the same choices the macOS engine
/// makes when it builds its aggregate device. A wireless receiver clocks the mixer if a track uses
/// one, otherwise the first other input a track uses; Bluetooth never clocks it. With no input,
/// an output does.
/// </summary>
public sealed record EnginePlan
{
    /// <summary>Inputs to open; with <see cref="ClockFromInput"/>, the first clocks the mixer.</summary>
    public required IReadOnlyList<AudioDevice> Inputs { get; init; }
    public required bool ClockFromInput { get; init; }
    /// <summary>The output that clocks the mixer when no input does.</summary>
    public AudioDevice? ClockOutput { get; init; }
    public AudioDevice? Venue { get; init; }
    public AudioDevice? Stream { get; init; }
    public required IReadOnlyList<PlannedTrack> Tracks { get; init; }
    /// <summary>The input endpoint of each mic system's receiver that is plugged in, by system ID.</summary>
    public required IReadOnlyDictionary<string, AudioDevice> Receivers { get; init; }
    /// <summary>Inputs and outputs a user can pick (receivers aren't: their transmitters are).</summary>
    public required IReadOnlyList<AudioDevice> UserInputs { get; init; }
    public required IReadOnlyList<AudioDevice> UserOutputs { get; init; }
    /// <summary>A routing choice that can't be honoured, worded for the user.</summary>
    public string? Warning { get; init; }

    /// <summary>Nothing to capture: the engine stays stopped.</summary>
    public bool IsIdle => Inputs.Count == 0;

    /// <summary>Equal for plans the engine would open identically, so unchanged plans don't rebuild.</summary>
    public string Signature => string.Join("#",
        Inputs.Select(Describe)
            .Append(ClockFromInput ? "in" : "out:" + Describe(ClockOutput))
            .Append("venue:" + Describe(Venue))
            .Append("stream:" + Describe(Stream))
            .Concat(Tracks.Select(t => $"{t.Input}|{t.Channel}|{t.Stereo}")));

    private static string Describe(AudioDevice? device) => device == null ? "-" : $"{device.Id}|{device.Channels}|{device.SampleRate}";

    public static EnginePlan Build(IReadOnlyList<TrackSource> tracks, IReadOnlyList<AudioDevice> devices, IReadOnlyList<IMicSystem> micSystems,
                                   string? venueId, string? streamId)
    {
        var receivers = new Dictionary<string, AudioDevice>();
        var userInputs = new List<AudioDevice>();
        var userOutputs = new List<AudioDevice>();
        foreach (var device in devices)
        {
            var system = micSystems.FirstOrDefault(s => s.IsReceiver(device));
            if (system != null)
            {
                if (device.IsInput) receivers.TryAdd(system.Id, device);
                continue;
            }
            (device.IsInput ? userInputs : userOutputs).Add(device);
        }

        var venue = userOutputs.FirstOrDefault(o => o.Id == venueId);
        var stream = userOutputs.FirstOrDefault(o => o.Id == streamId);
        string? warning = null;
        if (stream != null && stream.Id == venue?.Id)
        {
            warning = "Stream and venue can't use the same output.";
            stream = null;
        }

        // Each track's device and channels, before inputs get their indices.
        var resolved = tracks.Select(source => Resolve(source, receivers, userInputs, micSystems)).ToList();

        // Receivers first (the clock if a track uses one), then other devices in track order.
        var used = new List<AudioDevice>();
        foreach (var r in resolved.OfType<(AudioDevice Device, int Channel, bool Stereo)>().OrderBy(r => receivers.ContainsValue(r.Device) ? 0 : 1))
        {
            if (used.All(d => d.Id != r.Device.Id)) used.Add(r.Device);
        }
        var clock = used.FirstOrDefault(d => !d.IsBluetooth);
        if (clock != null)
        {
            used.Remove(clock);
            used.Insert(0, clock);
        }

        var planned = tracks.Select((source, i) => resolved[i] is { } r
            ? new PlannedTrack(used.FindIndex(d => d.Id == r.Device.Id), r.Channel, r.Stereo)
            : PlannedTrack.Missing(source.IsStereo)).ToList();

        return new EnginePlan
        {
            Inputs = used,
            ClockFromInput = clock != null,
            ClockOutput = clock != null ? null : stream ?? venue ?? userOutputs.FirstOrDefault(o => o.IsDefault) ?? userOutputs.FirstOrDefault(),
            Venue = venue,
            Stream = stream,
            Tracks = planned,
            Receivers = receivers,
            UserInputs = userInputs,
            UserOutputs = userOutputs,
            Warning = warning,
        };
    }

    private static (AudioDevice Device, int Channel, bool Stereo)? Resolve(TrackSource source, Dictionary<string, AudioDevice> receivers,
                                                                          List<AudioDevice> inputs, IReadOnlyList<IMicSystem> systems)
    {
        switch (source)
        {
            case TransmitterSource t:
                if (!receivers.TryGetValue(t.System, out var receiver)) return null;
                if (systems.FirstOrDefault(s => s.Id == t.System)?.AudioChannel(t.Slot) is not int channel || channel >= receiver.Channels) return null;
                return (receiver, channel, false);
            case DeviceSource d:
                var device = inputs.FirstOrDefault(i => i.Id == d.Uid);
                if (device == null || d.Channel < 0 || d.Channel + (d.Stereo ? 1 : 0) >= device.Channels) return null;
                return (device, d.Channel, d.Stereo);
            default:
                // App and system audio come with process loopback capture.
                return null;
        }
    }
}
