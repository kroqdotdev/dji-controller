using System.ComponentModel;
using Lavboard.Core;
using Lavboard.Core.Interop;
using Microsoft.UI.Dispatching;

namespace Lavboard.Model;

/// <summary>
/// The real engine: plans which endpoints to open (<see cref="EnginePlan"/>), runs the native
/// WASAPI engine off the UI thread, and keeps each track's gain, mute, venue send and balance in
/// the mixing core. Mirrors AudioEngine in the macOS app.
/// </summary>
public sealed class WasapiEngine : IAudioEngine, IDisposable
{
    public event EventHandler? Changed;

    private readonly NativeEngine native = new();
    private readonly IReadOnlyList<IMicSystem> systems;
    private readonly DispatcherQueue ui;
    private readonly DispatcherQueueTimer deviceTimer;
    private readonly DispatcherQueueTimer appTimer;
    private readonly SemaphoreSlim serial = new(1, 1);

    private IReadOnlyList<AudioDevice> devices = [];
    private IReadOnlyList<Track> tracks = [];
    private string? streamId, venueId;
    private int bufferFrames = 64;
    private EnginePlan plan;
    private string? startedSignature;
    private int generation;
    private int appliedGeneration;
    /// <summary>A rebuild hasn't landed yet, so the core's layout doesn't match <see cref="tracks"/>.</summary>
    private bool Building => appliedGeneration != generation;
    private EngineStatus? status;
    private string? failure;

    public WasapiEngine(IReadOnlyList<IMicSystem> systems, DispatcherQueue ui)
    {
        this.systems = systems;
        this.ui = ui;
        plan = EnginePlan.Build([], [], systems, null, null);
        // Endpoints come and go in bursts (a USB receiver brings several); settle before replanning.
        deviceTimer = ui.CreateTimer();
        deviceTimer.Interval = TimeSpan.FromMilliseconds(300);
        deviceTimer.IsRepeating = false;
        deviceTimer.Tick += (_, _) => RefreshDevices();
        appTimer = ui.CreateTimer();
        appTimer.Interval = TimeSpan.FromSeconds(2);
        appTimer.Tick += (_, _) =>
        {
            var next = EnginePlan.Build(tracks.Select(t => t.Source).ToList(), devices, systems, venueId, streamId,
                                        AudioApps.ProcessFor, (uint)Environment.ProcessId);
            if (next.Signature != plan.Signature) Replan();
        };
        NativeEngine.DevicesChanged += () => ui.TryEnqueue(() => { deviceTimer.Stop(); deviceTimer.Start(); });
        NativeEngine.WatchDevices();
        devices = AudioDevices.List();
        foreach (var system in systems) system.PropertyChanged += (_, _) => ui.TryEnqueue(Replan);
    }

    public IReadOnlyList<AudioDevice> Inputs => plan.UserInputs;
    public IReadOnlyList<AudioDevice> Outputs => plan.UserOutputs;
    public IReadOnlyList<AudioApp> Apps => AudioApps.List();
    public bool IsReceiverPresent(string systemId) => plan.Receivers.ContainsKey(systemId);
    public bool IsTrackAvailable(int index) => index < plan.Tracks.Count && plan.Tracks[index].IsAvailable;
    public double? TrackLatencyMs(int index) => status is { } s && index < s.TrackLatencyMs.Count ? s.TrackLatencyMs[index] : null;
    public double? VenueLatencyMs => status?.VenueLatencyMs;
    public string? Warning => plan.Warning ?? status?.Problems.FirstOrDefault();
    public string? Failure => failure;
    public bool MicrophoneBlocked =>
        (failure?.Contains(NativeEngine.PrivacyReason) ?? false) || (status?.Problems.Any(p => p.Contains(NativeEngine.PrivacyReason)) ?? false);

    public bool CanRecord => status != null && startedSignature == plan.Signature && native.IsRunning;

    public IRecording StartRecording(string folder, IReadOnlyList<(string Name, int Channels)> tracks, RecordingFormat format) =>
        RecordingSession.Start(native.Core, folder, tracks, status?.SampleRate ?? 48_000, format, DateTime.Now);

    /// <summary>Whole dB steps, like the macOS stepper; the endpoint rounds to what it supports.</summary>
    public InputGain? DeviceGain(DeviceSource source) =>
        devices.Any(d => d.Id == source.Uid) && AudioDevices.InputGain(source.Uid) is var (db, min, max) ? new InputGain(Math.Round(db), min, max) : null;

    public void SetDeviceGain(DeviceSource source, double db) => AudioDevices.SetInputGain(source.Uid, db);

    public void Configure(IReadOnlyList<Track> tracks, string? streamOutputId, string? venueOutputId)
    {
        foreach (var track in this.tracks) track.PropertyChanged -= OnTrackChanged;
        this.tracks = tracks.ToList();
        foreach (var track in this.tracks) track.PropertyChanged += OnTrackChanged;
        streamId = streamOutputId;
        venueId = venueOutputId;
        Replan();
    }

    public void SetLevels(double streamDb, double venueDb)
    {
        Native.AudioCoreSetStreamLevel(native.Core, Decibels.Linear(streamDb));
        Native.AudioCoreSetVenueLevel(native.Core, Decibels.Linear(venueDb));
    }

    public void SetBufferFrames(int frames)
    {
        if (frames == bufferFrames) return;
        bufferFrames = frames;
        startedSignature = null;
        Replan();
    }

    public unsafe void ReadMeters(Span<float> left, Span<float> right, out float stream, out float venue)
    {
        AudioCoreMeters meters;
        Native.AudioCoreReadMeters(native.Core, &meters);
        for (int i = 0; i < Math.Min(left.Length, Native.MaxTracks); i++)
        {
            left[i] = meters.PeakLeft[i];
            right[i] = meters.PeakRight[i];
        }
        stream = meters.StreamPeak;
        venue = meters.VenuePeak;
    }

    private void RefreshDevices()
    {
        devices = AudioDevices.List();
        // A stream that failed (its device went away mid-run) restarts with what is left.
        if (!native.IsRunning) startedSignature = null;
        Replan();
    }

    private void Replan()
    {
        plan = EnginePlan.Build(tracks.Select(t => t.Source).ToList(), devices, systems, venueId, streamId,
                                AudioApps.ProcessFor, (uint)Environment.ProcessId);
        // A process loopback follows one process: replan when a captured app quits or one starts.
        if (tracks.Any(t => t.Source is AppSource)) appTimer.Start(); else appTimer.Stop();
        if (plan.Signature != startedSignature) Rebuild();
        // While a rebuild is under way the core still has the old layout; the build applies these.
        if (!Building) ApplyControls();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Starts the plan on a background thread; only the newest plan is applied.</summary>
    private void Rebuild()
    {
        startedSignature = plan.Signature;
        int build = ++generation;
        var next = plan;
        uint period = (uint)bufferFrames;
        var controls = tracks.Take(Native.MaxTracks).Select(Controls.Of).ToArray();
        _ = Task.Run(async () =>
        {
            await serial.WaitAsync();
            try
            {
                if (build != Volatile.Read(ref generation)) return;
                EngineStatus? started = null;
                string? failed = null;
                var clock = next.ClockFromInput ? next.Inputs[0] : next.ClockOutput;
                if (next.IsIdle || clock == null)
                {
                    native.Stop();
                    if (!next.IsIdle) failed = "No output device to run the mixer on.";
                }
                else
                {
                    try
                    {
                        started = native.Start(next, period, core => { for (int i = 0; i < controls.Length; i++) controls[i].Apply(core, i); });
                    }
                    catch (EngineStartException e)
                    {
                        failed = $"{clock.Name} {e.Message}.";
                    }
                    catch (Exception e) when (e is not OutOfMemoryException)
                    {
                        // Still land the build below, so the UI and the track settings stay in step.
                        failed = $"The audio engine couldn't start: {e.Message}";
                    }
                }
                ui.TryEnqueue(() =>
                {
                    if (build != generation) return;
                    appliedGeneration = build;
                    status = started;
                    failure = failed;
                    ApplyControls();
                    Changed?.Invoke(this, EventArgs.Empty);
                });
            }
            finally
            {
                serial.Release();
            }
        });
    }

    private void OnTrackChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (Building || sender is not Track track || e.PropertyName is not (nameof(Track.FaderDb) or nameof(Track.Muted) or nameof(Track.SendToVenue) or nameof(Track.Balance)))
        {
            return; // a build in flight applies every track's settings when it lands
        }
        for (int i = 0; i < tracks.Count && i < Native.MaxTracks; i++)
        {
            if (ReferenceEquals(tracks[i], track)) ApplyControl(i);
        }
    }

    /// <summary>The core keys controls by track index, so they follow every layout change.</summary>
    private void ApplyControls()
    {
        for (int i = 0; i < tracks.Count && i < Native.MaxTracks; i++) ApplyControl(i);
    }

    private void ApplyControl(int index) => Controls.Of(tracks[index]).Apply(native.Core, index);

    /// <summary>A track's settings as the core holds them, captured so a build can apply them off the UI thread.</summary>
    private readonly record struct Controls(float Gain, bool Muted, bool Venue, float Balance)
    {
        public static Controls Of(Track track) => new(Decibels.Linear(track.FaderDb), track.Muted, track.SendToVenue, (float)track.Balance);

        public void Apply(IntPtr core, int index)
        {
            Native.AudioCoreSetTrackGain(core, index, Gain);
            Native.AudioCoreSetTrackMute(core, index, Muted);
            Native.AudioCoreSetTrackVenueSend(core, index, Venue);
            Native.AudioCoreSetTrackBalance(core, index, Balance);
        }
    }

    public void Dispose()
    {
        native.Stop();
        native.Dispose();
    }
}
