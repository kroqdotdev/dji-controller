namespace Lavboard.Core;

public static class Decibels
{
    /// <summary>"0 dB", "+2.5 dB", or "Off" at the bottom of the fader.</summary>
    public static string Label(double db) => db <= -60 ? "Off" : db == 0 ? "0 dB" : $"{db:+0.0;-0.0} dB";

    /// <summary>Fader scale: the bottom of the travel (-60 dB) is silence.</summary>
    public static float Linear(double db) => db <= -60 ? 0 : (float)Math.Pow(10, db / 20);
}
