using Lavboard.Core.Interop;

namespace Lavboard.Tests;

/// <summary>
/// Drives the mixer IOProc with synthetic buffers: a 4-channel "receiver" input buffer, a 2-channel
/// "USB device" input buffer, and stereo venue and stream outputs. Mirrors CoreHarness in the macOS tests.
/// </summary>
public sealed unsafe class CoreHarness : IDisposable
{
    public IntPtr Core { get; }
    private readonly int frames;

    public static readonly TrackLayout[] FourMono = Enumerable.Range(0, 4).Select(c => TrackLayout.Mono(0, c)).ToArray();

    public CoreHarness(uint ringFrames = 1 << 12, int frames = 64, TrackLayout[]? tracks = null)
    {
        Core = Native.AudioCoreCreate(ringFrames);
        this.frames = frames;
        tracks ??= FourMono;
        fixed (TrackLayout* t = tracks) Native.AudioCoreSetLayout(Core, t, tracks.Length, 0, 1);
    }

    public void Dispose() => Native.AudioCoreDestroy(Core);

    public sealed record Output((float Left, float Right)[] Venue, (float Left, float Right)[] Stream);

    /// <summary>One IO cycle with constant values: <paramref name="receiver"/> feeds input buffer 0, <paramref name="usb"/> buffer 1.</summary>
    public Output Cycle(float[]? receiver = null, float[]? usb = null)
    {
        receiver ??= [0.1f, 0.2f, 0.3f, 0.0f];
        usb ??= [0f, 0f];
        var rx = new float[frames * 4];
        var dev = new float[frames * 2];
        var venue = Enumerable.Repeat(9f, frames * 2).ToArray();
        var stream = Enumerable.Repeat(9f, frames * 2).ToArray();
        for (int f = 0; f < frames; f++)
        {
            for (int c = 0; c < 4; c++) rx[f * 4 + c] = receiver[c];
            for (int c = 0; c < 2; c++) dev[f * 2 + c] = usb[c];
        }
        using var input = new BufferList(2);
        using var output = new BufferList(2);
        var ts = new AudioTimeStamp();
        fixed (float* r = rx, d = dev, v = venue, s = stream)
        {
            input.Count = 2;
            input.Set(0, r, frames, 4);
            input.Set(1, d, frames, 2);
            output.Count = 2;
            output.Set(0, v, frames, 2);
            output.Set(1, s, frames, 2);
            Native.AudioCoreIOProc(0, &ts, input.Pointer, &ts, output.Pointer, &ts, Core);
        }
        return new Output(Pairs(venue), Pairs(stream));
    }

    private static (float, float)[] Pairs(float[] a) => Enumerable.Range(0, a.Length / 2).Select(i => (a[2 * i], a[2 * i + 1])).ToArray();

    public static bool All((float Left, float Right)[] samples, float left, float right) =>
        samples.All(s => MathF.Abs(s.Left - left) < 1e-5f && MathF.Abs(s.Right - right) < 1e-5f);
}
