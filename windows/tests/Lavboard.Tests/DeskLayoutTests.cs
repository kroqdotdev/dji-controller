using Lavboard.Core;
using Xunit;

namespace Lavboard.Tests;

/// <summary>The desk gives strips the same widths as the macOS app at the same window width.</summary>
public class DeskLayoutTests
{
    [Fact]
    public void FewTracksGetTheWidestStrips() => Assert.Equal(DeskLayout.StripMax, DeskLayout.StripWidth(1360, 4, canAdd: true));

    [Fact]
    public void SixTracksInTheDefaultWindowAreCompact()
    {
        // 1360 - 256 masters - 46 margins and spacer - 106 add slot - 80 gaps, over 6 strips.
        double width = DeskLayout.StripWidth(1360, 6, canAdd: true);
        Assert.Equal(145.33, width, 2);
        Assert.True(DeskLayout.IsCompact(width));
    }

    [Fact]
    public void StripsNeverShrinkBelowTheMinimum() => Assert.Equal(DeskLayout.StripMin, DeskLayout.StripWidth(900, 8, canAdd: false));

    [Theory]
    [InlineData(1)]
    [InlineData(4)]
    [InlineData(7)]
    [InlineData(8)]
    public void TheMinimumWidthFitsEveryStripAtItsMinimum(int tracks)
    {
        double width = DeskLayout.MinimumWidth(tracks);
        Assert.Equal(DeskLayout.StripMin, DeskLayout.StripWidth(width, tracks, canAdd: tracks < DeskLayout.MaximumTracks), 6);
        Assert.True(DeskLayout.StripWidth(width - 1, tracks, canAdd: tracks < DeskLayout.MaximumTracks) <= DeskLayout.StripMin);
    }
}
