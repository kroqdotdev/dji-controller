using Lavboard.Core;

namespace Lavboard.Model;

/// <summary>An input device's own gain and its range, in dB.</summary>
public sealed record InputGain(double Db, double Min, double Max);

/// <summary>What the UI needs from the audio engine; the WASAPI engine and the demo both provide it.</summary>
public interface IAudioEngine
{
    /// <summary>Devices, availability or routing changed.</summary>
    event EventHandler? Changed;

    IReadOnlyList<AudioDevice> Inputs { get; }
    IReadOnlyList<AudioDevice> Outputs { get; }
    /// <summary>Apps that have opened audio, for app audio tracks; streaming apps left out.</summary>
    IReadOnlyList<AudioApp> Apps { get; }
    bool IsReceiverPresent(string systemId);
    bool IsTrackAvailable(int index);
    /// <summary>How far an own-clock track runs behind the other inputs, in milliseconds.</summary>
    double? TrackLatencyMs(int index);
    double? VenueLatencyMs { get; }
    string? Warning { get; }
    string? Failure { get; }

    /// <summary>The input device's own gain, for devices that let apps change it.</summary>
    InputGain? DeviceGain(DeviceSource source);
    void SetDeviceGain(DeviceSource source, double db);

    void Configure(IReadOnlyList<Track> tracks, string? streamOutputId, string? venueOutputId);
    /// <summary>Output levels of the two mixes, in dB (-60 is off).</summary>
    void SetLevels(double streamDb, double venueDb);
    /// <summary>The mixer period to ask devices for, in frames.</summary>
    void SetBufferFrames(int frames);
    /// <summary>Peaks since the previous call, linear 0...1.</summary>
    void ReadMeters(Span<float> left, Span<float> right, out float stream, out float venue);
}
