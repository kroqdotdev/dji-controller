using System.Collections.Specialized;
using System.ComponentModel;
using Lavboard.Core;
using Microsoft.UI.Dispatching;

namespace Lavboard.Model;

/// <summary>Saves the app's settings half a second after the last change. Demo scenes don't use one.</summary>
public sealed class SettingsStore
{
    private readonly AppModel app;
    private readonly string path;
    private readonly DispatcherQueueTimer timer;

    private static readonly HashSet<string> Saved =
    [
        nameof(AppModel.StreamOutputId), nameof(AppModel.VenueOutputId), nameof(AppModel.StreamLevelDb), nameof(AppModel.VenueLevelDb),
        nameof(AppModel.BackupOnTransmitters), nameof(AppModel.RecordingFolder), nameof(AppModel.RecordingFormat), nameof(AppModel.BufferFrames),
    ];

    public SettingsStore(AppModel app, string path, DispatcherQueue ui)
    {
        this.app = app;
        this.path = path;
        timer = ui.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(500);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Save();
        app.PropertyChanged += (_, e) => { if (Saved.Contains(e.PropertyName ?? "")) Schedule(); };
        app.Tracks.CollectionChanged += OnTracksChanged;
        foreach (var track in app.Tracks) track.PropertyChanged += OnTrackChanged;
    }

    /// <summary>Applies saved settings to a new model, before it starts.</summary>
    public static void Apply(Settings settings, AppModel app)
    {
        app.StreamOutputId = settings.StreamOutputId;
        app.VenueOutputId = settings.VenueOutputId;
        app.StreamLevelDb = settings.StreamLevelDb;
        app.VenueLevelDb = settings.VenueLevelDb;
        app.BackupOnTransmitters = settings.BackupOnTransmitters;
        if (settings.RecordingFolder is { Length: > 0 } folder) app.RecordingFolder = folder;
        app.RecordingFormat = settings.RecordingFormat;
        if (AppModel.BufferChoices.Contains(settings.BufferFrames)) app.BufferFrames = settings.BufferFrames;
    }

    private void OnTracksChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems != null) foreach (Track t in e.NewItems) t.PropertyChanged += OnTrackChanged;
        if (e.OldItems != null) foreach (Track t in e.OldItems) t.PropertyChanged -= OnTrackChanged;
        Schedule();
    }

    // Mutes aren't saved: every launch starts with all mics live.
    private void OnTrackChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(Track.Muted)) Schedule();
    }

    private void Schedule()
    {
        timer.Stop();
        timer.Start();
    }

    public void Save()
    {
        timer.Stop();
        var settings = new Settings
        {
            Tracks = app.Tracks.ToList(),
            StreamOutputId = app.StreamOutputId,
            VenueOutputId = app.VenueOutputId,
            StreamLevelDb = app.StreamLevelDb,
            VenueLevelDb = app.VenueLevelDb,
            BackupOnTransmitters = app.BackupOnTransmitters,
            RecordingFolder = app.RecordingFolder,
            RecordingFormat = app.RecordingFormat,
            BufferFrames = app.BufferFrames,
        };
        try
        {
            settings.Save(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Unsaved settings aren't worth interrupting a show for; the next change tries again.
        }
    }
}
