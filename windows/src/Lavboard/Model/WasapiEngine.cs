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
    private readonly SemaphoreSlim serial = new(1, 1);

    private IReadOnlyList<AudioDevice> devices = [];
    private IReadOnlyList<Track> tracks = [];
    private string? streamId, venueId;
    private int bufferFrames = 64;
    private EnginePlan plan;
    private string? startedSignature;
    private int generation;
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
        NativeEngine.DevicesChanged += () => ui.TryEnqueue(() => { deviceTimer.Stop(); deviceTimer.Start(); });
        NativeEngine.WatchDevices();
        devices = AudioDevices.List();
        foreach (var system in systems) system.PropertyChanged += (_, _) => ui.TryEnqueue(Replan);
    }

    public IReadOnlyList<AudioDevice> Inputs => plan.UserInputs;
    public IReadOnlyList<AudioDevice> Outputs => plan.UserOutputs;
    public IReadOnlyList<AudioApp> Apps => [];
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
        plan = EnginePlan.Build(tracks.Select(t => t.Source).ToList(), devices, systems, venueId, streamId);
        ApplyControls();
        if (plan.Signature != startedSignature) Rebuild();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Starts the plan on a background thread; only the newest plan is applied.</summary>
    private void Rebuild()
    {
        startedSignature = plan.Signature;
        int build = ++generation;
        var next = plan;
        uint period = (uint)bufferFrames;
        _ = Task.Run(async () =>
        {
            await serial.WaitAsync();
            try
            {
                if (build != Volatile.Read(ref generation)) return;
                EngineStatus? started = null;
                string? failed = null;
                if (next.IsIdle)
                {
                    native.Stop();
                }
                else
                {
                    try
                    {
                        started = native.Start(next, period);
                    }
                    catch (EngineStartException e)
                    {
                        var clock = next.ClockFromInput ? next.Inputs[0] : next.ClockOutput;
                        failed = $"{clock?.Name ?? "The audio device"} {e.Message}.";
                    }
                }
                ui.TryEnqueue(() =>
                {
                    if (build != generation) return;
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
        if (sender is Track track && e.PropertyName is nameof(Track.FaderDb) or nameof(Track.Muted) or nameof(Track.SendToVenue) or nameof(Track.Balance))
        {
            int index = ((List<Track>)tracks).IndexOf(track);
            if (index >= 0) ApplyControl(index);
        }
    }

    /// <summary>The core keys controls by track index, so they follow every layout change.</summary>
    private void ApplyControls()
    {
        for (int i = 0; i < tracks.Count && i < Native.MaxTracks; i++) ApplyControl(i);
    }

    private void ApplyControl(int index)
    {
        var track = tracks[index];
        Native.AudioCoreSetTrackGain(native.Core, index, Decibels.Linear(track.FaderDb));
        Native.AudioCoreSetTrackMute(native.Core, index, track.Muted);
        Native.AudioCoreSetTrackVenueSend(native.Core, index, track.SendToVenue);
        Native.AudioCoreSetTrackBalance(native.Core, index, (float)track.Balance);
    }

    public void Dispose()
    {
        native.Stop();
        native.Dispose();
    }
}
