using Lavboard.Core.Interop;
using Xunit;

namespace Lavboard.Tests;

public unsafe class AudioCoreTests
{
    [Fact]
    public void EngineReportsTheExpectedApiVersion() => Assert.Equal(Native.ExpectedEngineVersion, Native.LbEngineVersion());

    [Fact]
    public void MonoTracksMixToTheCentreOfBothOutputs()
    {
        using var h = new CoreHarness();
        h.Cycle();
        var output = h.Cycle();
        Assert.True(CoreHarness.All(output.Stream, 0.6f, 0.6f));
        Assert.True(CoreHarness.All(output.Venue, 0.6f, 0.6f));
    }

    [Fact]
    public void MuteRemovesOnlyThatTrackFromBothMixes()
    {
        using var h = new CoreHarness();
        h.Cycle();
        Native.AudioCoreSetTrackMute(h.Core, 1, true);
        h.Cycle();
        var output = h.Cycle();
        Assert.True(CoreHarness.All(output.Stream, 0.4f, 0.4f));
        Assert.True(CoreHarness.All(output.Venue, 0.4f, 0.4f));
    }

    [Fact]
    public void StereoTrackKeepsItsSidesAndHonoursBalance()
    {
        using var h = new CoreHarness(tracks: [TrackLayout.StereoPair(1, 0, 1)]);
        float[] usb = [0.2f, 0.4f];
        h.Cycle(usb: usb);
        Assert.True(CoreHarness.All(h.Cycle(usb: usb).Stream, 0.2f, 0.4f));
        Native.AudioCoreSetTrackBalance(h.Core, 0, 1);
        h.Cycle(usb: usb);
        Assert.True(CoreHarness.All(h.Cycle(usb: usb).Stream, 0f, 0.4f));
    }

    [Fact]
    public void RecordsEachTracksChannelsThenTheMix()
    {
        using var h = new CoreHarness(tracks: [TrackLayout.Mono(0, 1), TrackLayout.StereoPair(1, 0, 1)]);
        Assert.Equal(5, Native.AudioCoreRingChannels(h.Core));
        float[] usb = [0.25f, 0.5f];
        h.Cycle(usb: usb);
        Native.AudioCoreSetTrackMute(h.Core, 0, true);
        Native.AudioCoreStartRecording(h.Core);
        h.Cycle(usb: usb);
        h.Cycle(usb: usb);
        Native.AudioCoreStopRecording(h.Core);
        var buffer = new float[1024 * Native.MaxRingChannels];
        uint frames;
        fixed (float* b = buffer) frames = Native.AudioCoreReadRecorded(h.Core, b, 1024);
        Assert.Equal(128u, frames);
        var last = buffer.AsSpan(127 * 5, 5);
        Assert.Equal(0.2f, last[0], 1e-6f);  // mono track, raw even though muted
        Assert.Equal(0.25f, last[1], 1e-6f); // stereo track left
        Assert.Equal(0.5f, last[2], 1e-6f);  // stereo track right
        Assert.Equal(0.25f, last[3], 1e-5f); // the mix reflects the mute
        Assert.Equal(0.5f, last[4], 1e-5f);
    }

    [Fact]
    public void LayoutIsCappedAtEightTracks()
    {
        var many = Enumerable.Range(0, 12).Select(i => TrackLayout.Mono(0, i % 4)).ToArray();
        using var h = new CoreHarness(tracks: many);
        Assert.Equal(8, Native.AudioCoreTrackCount(h.Core));
        Assert.Equal(10, Native.AudioCoreRingChannels(h.Core));
    }

    [Fact]
    public void MetersReportPreFaderPeaks()
    {
        using var h = new CoreHarness(tracks: [TrackLayout.Mono(0, 0), TrackLayout.StereoPair(1, 0, 1)]);
        Native.AudioCoreSetTrackMute(h.Core, 0, true);
        h.Cycle(usb: [0.2f, 0.4f]);
        AudioCoreMeters m;
        Native.AudioCoreReadMeters(h.Core, &m);
        Assert.Equal(0.1f, m.PeakLeft[0], 1e-6f);
        Assert.Equal(0.2f, m.PeakLeft[1], 1e-6f);
        Assert.Equal(0.4f, m.PeakRight[1], 1e-6f);
        Assert.Equal(1ul, m.Callbacks);
    }
}
