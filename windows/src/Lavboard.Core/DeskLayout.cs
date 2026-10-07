namespace Lavboard.Core;

/// <summary>
/// Strip widths on the desk, the same rules as the macOS Desk: roomy with few tracks, compact (row
/// labels become tooltips) below 150, never narrower than 112.
/// </summary>
public static class DeskLayout
{
    public const double StripMin = 112, StripMax = 196, CompactBelow = 150, AddSlotWidth = 96, MasterWidth = 128, Gap = 10;
    public const double PaddingX = 16, PaddingY = 14, SpacerMin = 14;
    public const int MaximumTracks = 8;

    /// <summary>Width of each track strip for the space available.</summary>
    public static double StripWidth(double available, int tracks, bool canAdd)
    {
        double masters = 2 * MasterWidth;
        double margins = PaddingX * 2 + SpacerMin;
        double add = canAdd ? AddSlotWidth + Gap : 0;
        // Between neighbours: strips, add slot, spacer and both outputs.
        double gaps = Gap * (tracks + 2);
        double perStrip = (available - masters - margins - add - gaps) / Math.Max(tracks, 1);
        return Math.Clamp(perStrip, StripMin, StripMax);
    }

    public static bool IsCompact(double stripWidth) => stripWidth < CompactBelow;

    /// <summary>The narrowest window that still fits every strip at its minimum width.</summary>
    public static double MinimumWidth(int tracks)
    {
        int slots = Math.Max(tracks, 1);
        double add = tracks < MaximumTracks ? AddSlotWidth + Gap : 0;
        return slots * StripMin + Gap * (slots + 2) + add + 2 * MasterWidth + PaddingX * 2 + SpacerMin;
    }
}
