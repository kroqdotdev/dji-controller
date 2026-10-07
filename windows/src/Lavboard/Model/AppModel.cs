using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI.Dispatching;

namespace Lavboard.Model;

/// <summary>
/// The app's state: tracks, routing and levels, mirroring AppModel in the macOS app. Views bind to it
/// and call its methods; it owns the meter timer.
/// </summary>
public sealed partial class AppModel : ObservableObject
{
    public ObservableCollection<Track> Tracks { get; } = [];
    public IReadOnlyList<IMicSystem> MicSystems { get; }
    public IAudioEngine Engine { get; }
    public MeterStore Meters { get; } = new();

    /// <summary>Raised 30 times a second after the meters update.</summary>
    public event EventHandler? MetersUpdated;

    private double streamLevelDb;
    private double venueLevelDb;
    private string? streamOutputId;
    private string? venueOutputId;
    private string recordingFormat = "24-bit";
    private bool backupOnTransmitters;
    private bool isRecording;
    private DateTime? recordingStartedAt;
    private string? lastRecordingFolder;
    private string? recordingError;
    private string recordingFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "Lavboard");
    private DispatcherQueueTimer? meterTimer;

    public AppModel(IAudioEngine engine, IReadOnlyList<IMicSystem> micSystems, IEnumerable<Track> tracks)
    {
        Engine = engine;
        MicSystems = micSystems;
        foreach (var track in tracks.Take(Track.Maximum))
        {
            Tracks.Add(track);
            track.PropertyChanged += OnTrackChanged;
        }
        Tracks.CollectionChanged += OnTracksChanged;
        engine.Changed += (_, _) => RaiseStatus();
        foreach (var system in micSystems) system.PropertyChanged += (_, _) => RaiseStatus();
    }

    public double StreamLevelDb { get => streamLevelDb; set => Set(ref streamLevelDb, value); }
    public double VenueLevelDb { get => venueLevelDb; set => Set(ref venueLevelDb, value); }
    public string? StreamOutputId { get => streamOutputId; set { if (Set(ref streamOutputId, value)) Reconfigure(); } }
    public string? VenueOutputId { get => venueOutputId; set { if (Set(ref venueOutputId, value)) Reconfigure(); } }
    public string RecordingFormat { get => recordingFormat; set => Set(ref recordingFormat, value); }
    public bool BackupOnTransmitters { get => backupOnTransmitters; set => Set(ref backupOnTransmitters, value); }
    public bool IsRecording
    {
        get => isRecording;
        private set { if (Set(ref isRecording, value)) { Raise(nameof(CanAddTrack)); Raise(nameof(CanEditTracks)); } }
    }
    public DateTime? RecordingStartedAt { get => recordingStartedAt; private set => Set(ref recordingStartedAt, value); }
    /// <summary>The last session's folder, for "Show in Explorer".</summary>
    public string? LastRecordingFolder { get => lastRecordingFolder; private set => Set(ref lastRecordingFolder, value); }
    public string? RecordingError { get => recordingError; private set => Set(ref recordingError, value); }
    public static IReadOnlyList<int> BufferChoices { get; } = [32, 64, 128, 256];
    private int bufferFrames = 64;
    public int BufferFrames { get => bufferFrames; set => Set(ref bufferFrames, value); }
    public static IReadOnlyList<string> RecordingFormats { get; } = ["24-bit", "32-bit float"];
    public string RecordingFolder { get => recordingFolder; set => Set(ref recordingFolder, value); }

    public bool CanRecord => Tracks.Count > 0;
    public bool CanAddTrack => Tracks.Count < Track.Maximum && !IsRecording;
    /// <summary>Tracks can't be added, removed or re-sourced mid-recording: the files are fixed at the start.</summary>
    public bool CanEditTracks => !IsRecording;
    public bool AnyStereo => Tracks.Any(t => t.Source.IsStereo);
    public bool CanBackUpOnTransmitters => MicSystems.Any(s => s.CanRecordOnTransmitters);

    public void Start()
    {
        Reconfigure();
        meterTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        meterTimer.Interval = TimeSpan.FromMilliseconds(1000.0 / 30);
        meterTimer.Tick += (_, _) => ReadMeters();
        meterTimer.Start();
    }

    private void ReadMeters()
    {
        Span<float> left = stackalloc float[Track.Maximum];
        Span<float> right = stackalloc float[Track.Maximum];
        Engine.ReadMeters(left, right, out float stream, out float venue);
        Meters.Update(left, right, stream, venue);
        MetersUpdated?.Invoke(this, EventArgs.Empty);
    }

    // MARK: Recording

    /// <summary>Starts or stops a session. The recorder itself comes with the WASAPI engine.</summary>
    public void ToggleRecording()
    {
        if (IsRecording)
        {
            IsRecording = false;
            RecordingStartedAt = null;
            return;
        }
        if (!CanRecord) return;
        LastRecordingFolder = Path.Combine(RecordingFolder, $"Session {DateTime.Now:yyyy-MM-dd HH.mm.ss}");
        RecordingStartedAt = DateTime.Now;
        IsRecording = true;
    }

    // MARK: Tracks

    public void AddTrack(TrackSource source, string name)
    {
        if (!CanAddTrack) return;
        Tracks.Add(new Track(name, source) { SendToVenue = !source.IsTap });
    }

    public void RemoveTrack(Track track)
    {
        if (CanEditTracks) Tracks.Remove(track);
    }

    /// <summary>Moves a track one place left (-1) or right (+1). Its mute key and file number follow its place.</summary>
    public void MoveTrack(Track track, int offset)
    {
        int i = Tracks.IndexOf(track);
        if (!CanEditTracks || i < 0 || i + offset < 0 || i + offset >= Tracks.Count) return;
        Tracks.Move(i, i + offset);
    }

    public void ToggleMute(int index)
    {
        if (index >= 0 && index < Tracks.Count) Tracks[index].Muted = !Tracks[index].Muted;
    }

    private void OnTracksChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems != null) foreach (Track t in e.NewItems) t.PropertyChanged += OnTrackChanged;
        if (e.OldItems != null) foreach (Track t in e.OldItems) t.PropertyChanged -= OnTrackChanged;
        Raise(nameof(CanAddTrack));
        Raise(nameof(CanRecord));
        Raise(nameof(AnyStereo));
        Reconfigure();
        RaiseStatus();
    }

    private void OnTrackChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Track.Source)) { Raise(nameof(AnyStereo)); Reconfigure(); RaiseStatus(); }
    }

    private void Reconfigure() => Engine.Configure(Tracks, StreamOutputId, VenueOutputId);

    // MARK: Mic systems

    public IMicSystem? MicSystem(string id) => MicSystems.FirstOrDefault(s => s.Id == id);

    public TransmitterState? Transmitter(TrackSource source) =>
        source is TransmitterSource t && MicSystem(t.System) is { } system && t.Slot < system.Transmitters.Count ? system.Transmitters[t.Slot] : null;

    public bool IsReceiverPresent(IMicSystem system) => system.IsConnected || Engine.IsReceiverPresent(system.Id);

    /// <summary>Systems the desk should show controls for: connected ones, and any a track uses.</summary>
    public IReadOnlyList<IMicSystem> ActiveMicSystems =>
        MicSystems.Where(s => IsReceiverPresent(s) || Tracks.Any(t => t.Source is TransmitterSource ts && ts.System == s.Id)).ToList();

    public bool HasTransmitterTracks => Tracks.Any(t => t.Source is TransmitterSource);

    // MARK: Title

    public string Title
    {
        get
        {
            var active = ActiveMicSystems;
            if (active.Count == 0) return "Lavboard";
            if (active.Count == 1)
            {
                var system = active[0];
                if (system.IsSwitchingMode) return "Receiver restarting";
                return IsReceiverPresent(system) ? "Receiver connected" : "Receiver not connected";
            }
            return $"{active.Count(IsReceiverPresent)} of {active.Count} receivers connected";
        }
    }

    /// <summary>The engine only takes over the subtitle when it needs attention.</summary>
    public string Subtitle
    {
        get
        {
            if (Engine.Failure is { } failure) return failure;
            if (Engine.Warning is { } warning) return warning;
            string tracks = Tracks.Count == 1 ? "1 track" : $"{Tracks.Count} tracks";
            var reporting = ActiveMicSystems.Where(s => s.IsConnected).ToList();
            if (!HasTransmitterTracks || reporting.Count == 0) return tracks;
            int on = reporting.Sum(s => s.Transmitters.Count(t => t.Connected));
            int total = reporting.Sum(s => s.TransmitterCount);
            return $"{on} of {total} mics on, {tracks}";
        }
    }

    private void RaiseStatus()
    {
        Raise(nameof(Title));
        Raise(nameof(Subtitle));
    }
}
