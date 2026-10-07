using Lavboard.Core;
using Xunit;

namespace Lavboard.Tests;

public class SourceNamesTests
{
    [Theory]
    // Windows endpoint names wrap the device in parentheses after a generic word.
    [InlineData("Microphone (Realtek USB2.0 Audio)", 0, false, 1, "Realtek")]
    [InlineData("Microphone (C922 Pro Stream Webcam)", 0, true, 2, "C922 Pro")]
    [InlineData("Headset Microphone (Jabra Evolve2 65)", 0, false, 1, "Jabra Evolve2")]
    [InlineData("Line In (Realtek(R) Audio)", 0, true, 2, "Realtek")]
    // Several inputs get their numbers; a stereo pair only when there are more than two.
    [InlineData("Line In (Focusrite USB Audio)", 2, false, 4, "Focusrite 3")]
    [InlineData("Microphone (Focusrite USB Audio)", 2, true, 4, "Focusrite 3+4")]
    // The owner's name isn't the mic's.
    [InlineData("Mads's AirPods Pro", 0, false, 1, "AirPods Pro")]
    // Nothing but filler keeps the first word.
    [InlineData("Microphone (USB Audio Device)", 0, false, 1, "Microphone")]
    public void DefaultNamesAreShortAndTapeFriendly(string device, int channel, bool stereo, int channels, string expected) =>
        Assert.Equal(expected, SourceNames.DefaultName(device, channel, stereo, channels));

    [Fact]
    public void ShortDeviceNamesDropTheInputNumber() =>
        Assert.Equal("C922 Pro", SourceNames.ShortDeviceName("Microphone (C922 Pro Stream Webcam)"));
}

public class DecibelsTests
{
    [Theory]
    [InlineData(0, "0 dB")]
    [InlineData(2.5, "+2.5 dB")]
    [InlineData(-6, "-6.0 dB")]
    [InlineData(-60, "Off")]
    public void LabelsMatchTheMac(double db, string expected) => Assert.Equal(expected, Decibels.Label(db));

    [Fact]
    public void TheBottomOfTheFaderIsSilence() => Assert.Equal(0f, Decibels.Linear(-60));
}
