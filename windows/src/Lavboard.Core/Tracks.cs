using System.Text.Json.Serialization;
using Windows.UI;

namespace Lavboard.Model;

/// <summary>Console tape colours; all light enough for dark ink. Pink stands in for red so a label never reads as "muted".</summary>
public enum TapeColor { White, Yellow, Orange, Pink, Green, Blue, Violet }

public static class TapeColors
{
    public static Color Fill(this TapeColor color) => color switch
    {
        TapeColor.Yellow => Color.FromArgb(255, 0xF2, 0xD6, 0x5E),
        TapeColor.Orange => Color.FromArgb(255, 0xF4, 0xA9, 0x64),
        TapeColor.Pink => Color.FromArgb(255, 0xF2, 0xA0, 0xB4),
        TapeColor.Green => Color.FromArgb(255, 0x93, 0xD6, 0xA4),
        TapeColor.Blue => Color.FromArgb(255, 0x93, 0xBD, 0xF4),
        TapeColor.Violet => Color.FromArgb(255, 0xBD, 0xAA, 0xF2),
        _ => Color.FromArgb(255, 0xEC, 0xEA, 0xE2),
    };

    public static string Label(this TapeColor color) => color.ToString();
}

/// <summary>Where a track's audio comes from. Mirrors TrackSource in the macOS app.</summary>
[JsonPolymorphic(TypeDiscriminatorPropertyName = "kind")]
[JsonDerivedType(typeof(TransmitterSource), "transmitter")]
[JsonDerivedType(typeof(DeviceSource), "device")]
[JsonDerivedType(typeof(AppSource), "app")]
[JsonDerivedType(typeof(SystemAudioSource), "systemAudio")]
public abstract record TrackSource
{
    /// <summary>Identifies the physical input, ignoring cached names.</summary>
    public abstract string Identity { get; }
    /// <summary>Short description for the strip, e.g. "TX2" or "In 3+4".</summary>
    public abstract string ChannelLabel { get; }
    public virtual bool IsStereo => false;
    public bool IsTap => this is AppSource or SystemAudioSource;
}

/// <summary>A transmitter slot (0-based, shown as TX1, TX2 ...) of a wireless mic system.</summary>
public sealed record TransmitterSource(string System, int Slot) : TrackSource
{
    public override string Identity => $"{System}#tx{Slot}";
    public override string ChannelLabel => $"TX{Slot + 1}";
}

/// <summary>A channel, or a stereo pair starting at <see cref="Channel"/>, on any input device.</summary>
public sealed record DeviceSource(string Uid, string Name, int Channel, bool Stereo) : TrackSource
{
    public override string Identity => $"{Uid}#{Channel}#{Stereo}";
    public override string ChannelLabel => Stereo ? $"In {Channel + 1}+{Channel + 2}" : $"In {Channel + 1}";
    public override bool IsStereo => Stereo;
}

/// <summary>What one app plays.</summary>
public sealed record AppSource(string AppId, string Name) : TrackSource
{
    public override string Identity => $"app#{AppId}";
    public override string ChannelLabel => "App audio";
    public override bool IsStereo => true;
}

/// <summary>Everything playing on the PC, except Lavboard and streaming apps.</summary>
public sealed record SystemAudioSource : TrackSource
{
    public override string Identity => "system-audio";
    public override string ChannelLabel => "All apps";
    public override bool IsStereo => true;
}

/// <summary>One mixer channel. Mute isn't saved: every launch starts with all mics live.</summary>
public sealed class Track : ObservableObject
{
    public const int Maximum = 8;
    public const string LegacySystemId = "dji-mic-mini-2s";

    private string name;
    private TapeColor color;
    private double faderDb;
    private bool sendToVenue = true;
    private double balance;
    private TrackSource source;
    private bool muted;

    public Track(string name, TrackSource source, TapeColor color = TapeColor.White)
    {
        this.name = name;
        this.source = source;
        this.color = color;
    }

    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get => name; set => Set(ref name, value); }
    public TapeColor Color { get => color; set => Set(ref color, value); }
    public double FaderDb { get => faderDb; set => Set(ref faderDb, value); }
    public bool SendToVenue { get => sendToVenue; set => Set(ref sendToVenue, value); }
    /// <summary>-1 (left) ... 1 (right); stereo tracks only.</summary>
    public double Balance { get => balance; set => Set(ref balance, value); }
    public TrackSource Source { get => source; set => Set(ref source, value); }
    [JsonIgnore] public bool Muted { get => muted; set => Set(ref muted, value); }

    public static IEnumerable<Track> DefaultSet() =>
        Enumerable.Range(0, 4).Select(i => new Track($"Mic {i + 1}", new TransmitterSource(LegacySystemId, i)));
}
