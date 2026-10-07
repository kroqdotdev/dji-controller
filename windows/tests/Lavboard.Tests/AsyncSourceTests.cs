using Lavboard.Core.Interop;
using Xunit;

namespace Lavboard.Tests;

/// <summary>Simulates a device on its own clock feeding an async source while the mixer renders it.</summary>
public sealed unsafe class AsyncHarness : IDisposable
{
    public IntPtr Source { get; }
    private readonly double sourceRate, targetRate;
    private readonly int chunk;
    private readonly Func<int, float> signal;
    public double Drift { get; set; } = 1.0;
    private int produced;
    private double producerTime, consumerTime;

    public AsyncHarness(double sourceRate, Func<int, float> signal, uint latency = 256, int chunk = 160, double targetRate = 48_000)
    {
        Source = Native.AudioCoreAsyncCreate(1, sourceRate, targetRate, latency);
        this.sourceRate = sourceRate;
        this.targetRate = targetRate;
        this.chunk = chunk;
        this.signal = signal;
    }

    public void Dispose() => Native.AudioCoreAsyncDestroy(Source);

    private void Produce()
    {
        var data = new float[chunk];
        using var list = new BufferList(1);
        using var none = new BufferList(0);
        var ts = new AudioTimeStamp();
        while (producerTime <= consumerTime)
        {
            for (int f = 0; f < chunk; f++) data[f] = signal(produced + f);
            fixed (float* d = data)
            {
                list.Count = 1;
                list.Set(0, d, chunk, 1);
                Native.AudioCoreAsyncIOProc(0, &ts, list.Pointer, &ts, none.Pointer, &ts, Source);
            }
            produced += chunk;
            producerTime += chunk / (sourceRate * Drift);
        }
    }

    /// <summary>Runs the mixer side for <paramref name="seconds"/>, keeping the output if asked.</summary>
    public float[] Run(double seconds, bool keep = true, int frames = 64)
    {
        var output = keep ? new List<float>() : null;
        for (int i = 0; i < (int)(seconds * targetRate / frames); i++)
        {
            consumerTime += frames / targetRate;
            Produce();
            Native.AudioCoreAsyncRender(Source, (uint)frames);
            if (output != null) output.AddRange(new ReadOnlySpan<float>(Native.AudioCoreAsyncOutput(Source, 0), frames).ToArray());
        }
        return output?.ToArray() ?? [];
    }

    public AudioCoreAsyncStats Stats
    {
        get { AudioCoreAsyncStats s; Native.AudioCoreAsyncReadStats(Source, &s); return s; }
    }
}

public class AsyncSourceTests
{
    private static Func<int, float> Sine(double hz, double rate, float amplitude = 0.5f) =>
        n => amplitude * (float)Math.Sin(2 * Math.PI * hz * n / rate);

    /// <summary>Frequency from rising zero crossings, interpolated between samples.</summary>
    private static double Frequency(float[] x, double rate)
    {
        var crossings = new List<double>();
        for (int i = 1; i < x.Length; i++)
            if (x[i - 1] < 0 && x[i] >= 0) crossings.Add(i - 1 + -x[i - 1] / (x[i] - x[i - 1]));
        return (crossings.Count - 1) / ((crossings[^1] - crossings[0]) / rate);
    }

    private static double Rms(float[] x) => Math.Sqrt(x.Sum(v => (double)v * v) / x.Length);

    [Fact]
    public void UpsamplesAToneWithoutChangingPitchOrLevel()
    {
        using var h = new AsyncHarness(16_000, Sine(1_000, 16_000));
        h.Run(1, keep: false);
        var output = h.Run(1);
        Assert.InRange(Frequency(output, 48_000), 999, 1_001);
        Assert.InRange(Rms(output), 0.5 / Math.Sqrt(2) - 0.005, 0.5 / Math.Sqrt(2) + 0.005);
        Assert.Equal(0ul, h.Stats.Underruns);
    }

    /// <summary>
    /// A device that delivers in bursts (WASAPI loopback: 480 frames every 10 ms) on the mixer's own
    /// clock needs no correction, so the resampler must start with the right amount buffered
    /// rather than pull the pitch for the 20 s its slow loop takes to settle.
    /// </summary>
    [Fact]
    public void StartsOnTargetWhenTheDeviceDeliversInBursts()
    {
        using var h = new AsyncHarness(48_000, Sine(1_000, 48_000), latency: 1_072, chunk: 480);
        h.Run(2, keep: false, frames: 128);
        Assert.InRange(h.Stats.Correction, -1e-4, 1e-4);
        var output = h.Run(5, frames: 128);
        Assert.InRange(Frequency(output, 48_000), 999.95, 1_000.05);
        Assert.Equal(0ul, h.Stats.Underruns);
    }

    [Theory]
    [InlineData(1.001)]
    [InlineData(0.9995)]
    public void FollowsADriftingDeviceClock(double drift)
    {
        using var h = new AsyncHarness(32_000, Sine(440, 32_000), latency: 1_024, chunk: 512) { Drift = drift };
        h.Run(150, keep: false);
        var settled = h.Stats;
        var output = h.Run(10);
        Assert.Equal(0ul, h.Stats.Underruns);
        Assert.Equal(0ul, h.Stats.Overflows);
        Assert.InRange(settled.Correction, drift - 1 - 1e-4, drift - 1 + 1e-4);
        Assert.InRange(Frequency(output, 48_000), 440 * drift - 0.5, 440 * drift + 0.5);
    }
}
