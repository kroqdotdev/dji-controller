using Lavboard.Core;
using Lavboard.MicSystems;
using Lavboard.Model;
using Xunit;

namespace Lavboard.Tests;

/// <summary>The engine opens the same devices, with the same clock, as the macOS engine would.</summary>
public class EnginePlanTests
{
    private static readonly IMicSystem[] Systems = [new DjiMicMini2S()];

    private static readonly AudioDevice Receiver = new("rx", "Microphone (Wireless Mic Rx)", true, 4, 48_000, false, 0x2CA3, 0x4115);
    private static readonly AudioDevice ReceiverStereo = Receiver with { Channels = 2, UsbProduct = 0x4015 };
    private static readonly AudioDevice ReceiverOut = new("rx-out", "Speakers (Wireless Mic Rx)", false, 2, 48_000, false, 0x2CA3, 0x4115);
    private static readonly AudioDevice UsbMic = new("usb", "Microphone (Realtek USB2.0 Audio)", true, 1, 48_000, true, 0x0BDA, 0x4937);
    private static readonly AudioDevice Webcam = new("c922", "Microphone (C922 Pro Stream Webcam)", true, 2, 32_000, false, 0x046D, 0x085C);
    private static readonly AudioDevice Headset = new("bt", "Headset (AirPods Pro)", true, 1, 16_000, false, IsBluetooth: true);
    private static readonly AudioDevice Speakers = new("spk", "Speakers (Realtek(R) Audio)", false, 2, 48_000, true);
    private static readonly AudioDevice Dock = new("dock", "Realtek USB2.0 Audio", false, 2, 48_000, false, 0x0BDA, 0x4937);

    private static readonly AudioDevice[] All = [Receiver, ReceiverOut, UsbMic, Webcam, Headset, Speakers, Dock];

    private static TrackSource Tx(int slot) => new TransmitterSource(DjiMicMini2S.SystemId, slot);
    private static TrackSource In(AudioDevice device, int channel = 0, bool stereo = false) => new DeviceSource(device.Id, device.Name, channel, stereo);

    private static EnginePlan Plan(TrackSource[] tracks, AudioDevice[]? devices = null, string? venue = null, string? stream = null) =>
        EnginePlan.Build(tracks, devices ?? All, Systems, venue, stream);

    [Fact]
    public void TheReceiverClocksTheMixerWheneverATrackUsesIt()
    {
        var plan = Plan([In(UsbMic), Tx(0), Tx(1)]);
        Assert.True(plan.ClockFromInput);
        Assert.Equal(["rx", "usb"], plan.Inputs.Select(d => d.Id));
        Assert.Equal(new PlannedTrack(1, 0, false), plan.Tracks[0]);
        Assert.Equal(new PlannedTrack(0, 0, false), plan.Tracks[1]);
        Assert.Equal(new PlannedTrack(0, 1, false), plan.Tracks[2]);
    }

    [Fact]
    public void ReceiversArentOfferedAsInputsOrOutputs()
    {
        var plan = Plan([]);
        Assert.Equal(Receiver, plan.Receivers[DjiMicMini2S.SystemId]);
        Assert.DoesNotContain(plan.UserInputs, d => d.Id == "rx");
        Assert.DoesNotContain(plan.UserOutputs, d => d.Id == "rx-out");
        Assert.Contains(plan.UserOutputs, d => d.Id == "dock");
    }

    [Fact]
    public void TransmittersWithoutAChannelInThisModeAreSilent()
    {
        var plan = Plan([Tx(0), Tx(2)], [ReceiverStereo, Speakers]);
        Assert.True(plan.Tracks[0].IsAvailable);
        Assert.False(plan.Tracks[1].IsAvailable);
    }

    [Fact]
    public void BluetoothNeverClocksTheMixer()
    {
        var plan = Plan([In(Headset), In(Webcam, 0, stereo: true)]);
        Assert.Equal(["c922", "bt"], plan.Inputs.Select(d => d.Id));
        Assert.Equal(new PlannedTrack(1, 0, false), plan.Tracks[0]);
        Assert.Equal(new PlannedTrack(0, 0, true), plan.Tracks[1]);
    }

    [Fact]
    public void WithOnlyBluetoothAnOutputClocksTheMixer()
    {
        var plan = Plan([In(Headset)], venue: "dock");
        Assert.False(plan.ClockFromInput);
        Assert.Equal(Dock, plan.ClockOutput);
        Assert.Equal(new PlannedTrack(0, 0, false), plan.Tracks[0]);

        // Without a mix output, the default output keeps time and plays silence.
        Assert.Equal(Speakers, Plan([In(Headset)]).ClockOutput);
    }

    [Fact]
    public void NothingToCaptureLeavesTheEngineIdle()
    {
        Assert.True(Plan([Tx(0)], [UsbMic, Speakers]).IsIdle);
        Assert.True(Plan([new AppSource("spotify.exe", "Spotify")]).IsIdle); // no process lookup: not running
    }

    [Fact]
    public void StreamAndVenueCantShareAnOutput()
    {
        var plan = Plan([Tx(0)], venue: "dock", stream: "dock");
        Assert.Equal(Dock, plan.Venue);
        Assert.Null(plan.Stream);
        Assert.NotNull(plan.Warning);
    }

    [Fact]
    public void ChannelsTheDeviceDoesntHaveAreSilent()
    {
        var plan = Plan([In(UsbMic, 0, stereo: true), In(Webcam, 2)]);
        Assert.False(plan.Tracks[0].IsAvailable);
        Assert.False(plan.Tracks[1].IsAvailable);
        Assert.True(plan.IsIdle);
    }

    private static uint? Running(string appId) => appId switch { "spotify.exe" => 4242, "msedge.exe" => 77, _ => null };

    [Fact]
    public void AppAudioIsCapturedAfterTheInputsOncePerApp()
    {
        TrackSource spotify = new AppSource("spotify.exe", "Spotify");
        var plan = EnginePlan.Build([Tx(0), spotify, new SystemAudioSource(), spotify], All, Systems, null, null, Running, ownProcessId: 999);
        Assert.Equal(["rx"], plan.Inputs.Select(d => d.Id));
        Assert.Equal([new PlannedLoopback(spotify.Identity, "Spotify", 4242, false), new PlannedLoopback("system-audio", "PC audio", 999, true)],
                     plan.Loopbacks);
        Assert.Equal(new PlannedTrack(1, 0, true), plan.Tracks[1]);
        Assert.Equal(new PlannedTrack(2, 0, true), plan.Tracks[2]);
        Assert.Equal(plan.Tracks[1], plan.Tracks[3]);
    }

    [Fact]
    public void AppsThatArentRunningAreSilent()
    {
        var plan = EnginePlan.Build([new AppSource("teams.exe", "Teams")], All, Systems, null, null, Running);
        Assert.False(plan.Tracks[0].IsAvailable);
        Assert.True(plan.IsIdle);
    }

    [Fact]
    public void AppAudioAloneRunsOnAnOutputClock()
    {
        var plan = EnginePlan.Build([new AppSource("msedge.exe", "Microsoft Edge")], All, Systems, null, null, Running);
        Assert.False(plan.IsIdle);
        Assert.False(plan.ClockFromInput);
        Assert.Equal(Speakers, plan.ClockOutput);
        Assert.Equal(new PlannedTrack(0, 0, true), plan.Tracks[0]);
    }

    [Fact]
    public void OnlyRealChangesChangeTheSignature()
    {
        TrackSource[] tracks = [Tx(0), In(UsbMic)];
        Assert.Equal(Plan(tracks, venue: "dock").Signature, Plan(tracks, venue: "dock").Signature);
        Assert.NotEqual(Plan(tracks, venue: "dock").Signature, Plan(tracks, venue: "spk").Signature);
        Assert.NotEqual(Plan(tracks).Signature, Plan(tracks, [Receiver with { SampleRate = 44_100 }, UsbMic, Speakers]).Signature);
    }
}
