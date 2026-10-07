using Lavboard.Core;
using Lavboard.Model;
using Xunit;

namespace Lavboard.Tests;

public sealed class SettingsTests : IDisposable
{
    private readonly string path = Path.Combine(Path.GetTempPath(), "lavboard-settings-" + Guid.NewGuid().ToString("N") + ".json");

    public void Dispose() => File.Delete(path);

    [Fact]
    public void TracksAndRoutingSurviveARoundTrip()
    {
        var host = new Track("Host", new TransmitterSource(Track.LegacySystemId, 0), TapeColor.Orange) { FaderDb = -3.5, Muted = true };
        var cam = new Track("Cam", new DeviceSource("{0.0.1.00000000}.{abc}", "Microphone (C922 Pro Stream Webcam)", 0, true), TapeColor.Violet)
        {
            Balance = -0.5, SendToVenue = false,
        };
        var spotify = new Track("Spotify", new AppSource("spotify.exe", "Spotify"));
        new Settings
        {
            Tracks = [host, cam, spotify, new Track("PC audio", new SystemAudioSource())],
            VenueOutputId = "dock", StreamLevelDb = -6, RecordingFormat = "32-bit float", BufferFrames = 128,
        }.Save(path);

        var loaded = Settings.Load(path);
        Assert.Equal(4, loaded.Tracks!.Count);
        Assert.Equal(host.Id, loaded.Tracks[0].Id);
        Assert.Equal(TapeColor.Orange, loaded.Tracks[0].Color);
        Assert.Equal(-3.5, loaded.Tracks[0].FaderDb);
        Assert.False(loaded.Tracks[0].Muted); // every launch starts live
        Assert.Equal(cam.Source, loaded.Tracks[1].Source);
        Assert.Equal(-0.5, loaded.Tracks[1].Balance);
        Assert.False(loaded.Tracks[1].SendToVenue);
        Assert.Equal(spotify.Source, loaded.Tracks[2].Source);
        Assert.IsType<SystemAudioSource>(loaded.Tracks[3].Source);
        Assert.Equal("dock", loaded.VenueOutputId);
        Assert.Equal(-6, loaded.StreamLevelDb);
        Assert.Equal("32-bit float", loaded.RecordingFormat);
        Assert.Equal(128, loaded.BufferFrames);
    }

    [Fact]
    public void UnreadableSettingsFallBackToDefaults()
    {
        File.WriteAllText(path, "{ not json");
        var settings = Settings.Load(path);
        Assert.Null(settings.Tracks);
        Assert.Equal(64, settings.BufferFrames);
        Assert.Null(Settings.Load(path + ".missing").Tracks);
    }
}
