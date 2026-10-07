using Lavboard.Core;

namespace Lavboard.Model;

// Demo content for working on the interface without hardware. `--scene readme` (the default)
// stages the macOS README screenshot; `--scene parity` and `--scene compact` stage scenes that a
// macOS debug build can also show (fake mic system, C922, Realtek), so the two apps can be
// compared side by side.

/// <summary>A pretend receiver whose capabilities are all simulated.</summary>
public sealed class DemoMicSystem(string id, string name, TransmitterState[] transmitters, GainCapability gain,
                                  IReadOnlyList<ReceiverMode> modes, string mode) : ObservableObject, IMicSystem
{
    private string mode = mode;

    public string Id => id;
    public string Name => name;
    public int TransmitterCount => transmitters.Length;
    public bool IsConnected => true;
    public IReadOnlyList<TransmitterState> Transmitters => transmitters;
    /// <summary>Which transmitters have a channel of their own in which mode.</summary>
    public Func<string, int, int?> Channels { get; init; } = (_, slot) => slot;
    public int? AudioChannel(int slot) => Channels(mode, slot);

    public GainCapability? Gain => gain;
    public void SetGain(double db, int slot)
    {
        transmitters[slot] = transmitters[slot] with { GainDb = db };
        Raise(nameof(Transmitters));
    }

    public bool CanRecordOnTransmitters => true;
    public void SetTransmitterRecording(bool on) { }

    public IReadOnlyList<ReceiverMode> Modes => modes;
    public string? CurrentModeId => mode;
    public bool IsSwitchingMode => false;
    public void SetMode(string id) { mode = id; Raise(nameof(CurrentModeId)); Raise(nameof(Notice)); }
    public Func<string, string, string?> Warning { get; init; } = (_, _) => null;
    public string? ModeSwitchWarning(string id) => Warning(mode, id);

    public Func<string, MicNotice?> Notices { get; init; } = _ => null;
    public MicNotice? Notice => Notices(mode);

    private readonly Dictionary<string, MicSetting> settings = [];
    public IReadOnlyList<MicSetting> InitialSettings { init { foreach (var s in value) settings[s.Id] = s; } }
    public IReadOnlyList<MicSetting> Settings => settings.Values.ToList();
    public string? SettingsNote { get; init; }
    public void SetToggle(string settingId, bool on) { settings[settingId] = settings[settingId] with { On = on }; Raise(nameof(Settings)); }
    public void SetChoice(string settingId, string choiceId) { settings[settingId] = settings[settingId] with { Choice = choiceId }; Raise(nameof(Settings)); }
}

/// <summary>Pretend devices and speech-like meters.</summary>
public sealed class DemoEngine(IReadOnlyList<AudioDevice> inputs, IReadOnlyList<AudioDevice> outputs, IReadOnlyList<DemoMicSystem> systems) : IAudioEngine
{
    public event EventHandler? Changed;

    public IReadOnlyList<AudioDevice> Inputs => inputs;
    public IReadOnlyList<AudioDevice> Outputs => outputs;
    public IReadOnlyList<AudioApp> Apps { get; init; } = [];
    public double? VenueMs { get; init; } = 6.5;
    /// <summary>Own-clock devices and app audio run this far behind, in ms.</summary>
    public double OwnClockMs { get; init; } = 13;
    public Dictionary<string, InputGain> Gains { get; init; } = [];

    private IReadOnlyList<Track> tracks = [];
    private string? streamOutput;
    private string? venueOutput;
    private readonly Talker[] talkers = Enumerable.Range(0, Track.Maximum).Select(i => new Talker(i)).ToArray();

    public bool IsReceiverPresent(string systemId) => systems.Any(s => s.Id == systemId);

    public bool IsTrackAvailable(int index) => index < tracks.Count && tracks[index].Source switch
    {
        TransmitterSource t => systems.FirstOrDefault(s => s.Id == t.System)?.AudioChannel(t.Slot) != null,
        DeviceSource d => inputs.Any(i => i.Id == d.Uid),
        _ => true,
    };

    public double? TrackLatencyMs(int index) => index < tracks.Count && tracks[index].Source switch
    {
        DeviceSource d => inputs.FirstOrDefault(i => i.Id == d.Uid)?.SampleRate != 48_000,
        var s => s.IsTap,
    } ? OwnClockMs : null;

    public double? VenueLatencyMs => venueOutput != null ? VenueMs : null;
    public string? Warning => null;
    public string? Failure => null;

    public InputGain? DeviceGain(DeviceSource source) => Gains.GetValueOrDefault(source.Uid);
    public void SetDeviceGain(DeviceSource source, double db)
    {
        if (Gains.TryGetValue(source.Uid, out var gain)) Gains[source.Uid] = gain with { Db = db };
    }

    public void Configure(IReadOnlyList<Track> tracks, string? streamOutputId, string? venueOutputId)
    {
        this.tracks = tracks.ToList();
        streamOutput = outputs.Any(o => o.Id == streamOutputId) ? streamOutputId : null;
        venueOutput = outputs.Any(o => o.Id == venueOutputId) ? venueOutputId : null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void ReadMeters(Span<float> left, Span<float> right, out float stream, out float venuePeak)
    {
        float mix = 0;
        for (int i = 0; i < Track.Maximum; i++)
        {
            float peak = i < tracks.Count && IsTrackAvailable(i) ? talkers[i].Next() : 0;
            left[i] = peak;
            right[i] = peak * 0.9f;
            if (i < tracks.Count && !tracks[i].Muted) mix = Math.Max(mix, peak * Decibels.Linear(tracks[i].FaderDb));
        }
        stream = streamOutput != null ? mix : 0;
        venuePeak = venueOutput != null ? mix : 0;
    }

    /// <summary>Syllables and pauses, at a level that depends on how close the talker is to the mic.</summary>
    private sealed class Talker(int seed)
    {
        private readonly Random random = new(seed * 7919 + 17);
        private readonly float loudness = seed switch { 0 => 0.32f, 1 => 0.26f, 2 => 0.07f, 3 => 0.05f, _ => 0.04f };
        private int framesLeft;
        private bool talking;
        private float level;

        public float Next()
        {
            if (--framesLeft <= 0)
            {
                talking = !talking;
                framesLeft = talking ? random.Next(3, 9) : random.Next(2, 6);
                level = talking ? loudness * (0.6f + 0.4f * random.NextSingle()) : loudness * 0.05f;
            }
            return level * (0.85f + 0.3f * random.NextSingle());
        }
    }
}

public static class DemoScenes
{
    private static readonly AudioDevice[] Outputs =
    [
        new("demo-venue", "Realtek USB2.0 Audio", false, 2, 48_000, false),
        new("demo-speakers", "Speakers (Realtek(R) Audio)", false, 2, 48_000, true),
        new("demo-cable", "CABLE Input (VB-Audio Virtual Cable)", false, 2, 48_000, false),
    ];

    private static readonly AudioApp[] Apps = [new("spotify.exe", "Spotify", true), new("ms-teams.exe", "Microsoft Teams", false)];

    public static AppModel Create(string? name) => name switch
    {
        "parity" => Parity(),
        "compact" => Compact(),
        _ => Readme(),
    };

    /// <summary>The macOS README scene: four presenters on a DJI receiver, Q&amp;A muted, venue on.</summary>
    public static AppModel Readme()
    {
        var dji = new DemoMicSystem(Track.LegacySystemId, "DJI Mic Mini 2S",
            Enumerable.Range(0, 4).Select(_ => new TransmitterState(Connected: true, Battery: 0.83, GainDb: 0)).ToArray(),
            new GainCapability(-12, 12, 1), [new("mono", "Mono"), new("stereo", "Stereo"), new("quad", "4-track")], "quad")
        {
            Channels = (mode, slot) => mode == "quad" ? slot : null,
            Warning = (current, next) => next == "quad" || current == "quad"
                ? "Switching to or from 4-track restarts the receiver. Audio drops out for a few seconds." : null,
            Notices = mode => mode == "quad" ? null
                : new MicNotice($"The receiver is in {(mode == "mono" ? "Mono" : "Stereo")} mode, so all mics arrive mixed together. Switch to 4-track to control each mic.",
                                "Switch to 4-track", "quad"),
        };
        AudioDevice[] inputs =
        [
            new("demo-usb", "Microphone (Realtek USB2.0 Audio)", true, 1, 48_000, false),
            new("demo-c922", "Microphone (C922 Pro Stream Webcam)", true, 2, 32_000, false),
        ];
        const string id = Track.LegacySystemId;
        Track[] tracks =
        [
            new("Host", new TransmitterSource(id, 0), TapeColor.Orange),
            new("Guest", new TransmitterSource(id, 1), TapeColor.Pink),
            new("Panel", new TransmitterSource(id, 2), TapeColor.Yellow),
            new("Q&A", new TransmitterSource(id, 3), TapeColor.Blue) { Muted = true },
        ];
        return new AppModel(new DemoEngine(inputs, Outputs, [dji]) { Apps = Apps }, [dji], tracks)
        {
            VenueOutputId = "demo-venue", BackupOnTransmitters = true,
        };
    }

    /// <summary>The parity scene plus both C922 channels on their own, which makes the desk compact.</summary>
    public static AppModel Compact()
    {
        var model = Parity();
        var c922 = model.Engine.Inputs.First(i => i.Id == "demo-c922");
        model.Tracks.Add(new Track("Cam L", new DeviceSource(c922.Id, c922.Name, 0, false), TapeColor.Green));
        model.Tracks.Add(new Track("Cam R", new DeviceSource(c922.Id, c922.Name, 1, false), TapeColor.Violet));
        return model;
    }

    /// <summary>
    /// The macOS parity scene: the debug build's fake two-transmitter system (TX1 live, TX2 off),
    /// the C922 as a stereo own-clock track with input gain, and a muted Realtek input.
    /// </summary>
    public static AppModel Parity()
    {
        var fake = new DemoMicSystem("fake", "Fake mic system",
            [new TransmitterState(Connected: true, Battery: 0.8, GainDb: 0), new TransmitterState()],
            new GainCapability(-10, 10, 2), [new("split", "Split"), new("merged", "Merged")], "split")
        {
            Channels = (mode, slot) => mode == "split" && slot == 0 ? 0 : null,
            Warning = (_, next) => next == "merged" ? "Merged mode mixes every mic into one channel." : null,
            Notices = mode => mode == "merged"
                ? new MicNotice("The fake receiver is in merged mode, so TX1 has no channel of its own.", "Switch to split", "split") : null,
            InitialSettings =
            [
                new("noise", "Noise cancellation", [new("off", "Off"), new("on", "On")], Choice: "off"),
                new("lowCut", "Low cut", On: false),
            ],
            SettingsNote = "Pretend settings; nothing is sent anywhere.",
        };
        AudioDevice[] inputs =
        [
            new("demo-c922", "Microphone (C922 Pro Stream Webcam)", true, 2, 32_000, false),
            new("demo-usb", "Microphone (Realtek USB2.0 Audio)", true, 1, 48_000, false),
        ];
        Track[] tracks =
        [
            new("Host", new TransmitterSource("fake", 0), TapeColor.Orange),
            new("Guest", new TransmitterSource("fake", 1), TapeColor.Pink),
            new("Panel", new DeviceSource("demo-c922", inputs[0].Name, 0, true), TapeColor.Yellow),
            new("Q&A", new DeviceSource("demo-usb", inputs[1].Name, 0, false), TapeColor.Blue) { Muted = true },
        ];
        var engine = new DemoEngine(inputs, Outputs, [fake])
        {
            Apps = Apps, VenueMs = 54.9, OwnClockMs = 0.3,
            Gains = new() { ["demo-c922"] = new InputGain(42, 0, 50) },
        };
        return new AppModel(engine, [fake], tracks) { VenueOutputId = "demo-venue", StreamOutputId = "lavboard-stream" };
    }
}
