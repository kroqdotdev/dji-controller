using System.Runtime.InteropServices;
using Lavboard.Core.Interop;

namespace Lavboard.Core;

/// <summary>What the native engine reports after starting a plan.</summary>
public sealed record EngineStatus(int SampleRate, int PeriodFrames, double? VenueLatencyMs, IReadOnlyList<double?> TrackLatencyMs,
                                  IReadOnlyList<string> Problems);

/// <summary>Thrown when the clock device can't start, so nothing runs.</summary>
public sealed class EngineStartException(string message) : Exception(message);

/// <summary>
/// The shared mixing core plus the WASAPI engine around it (LavboardEngine.dll). Start and Stop
/// block while devices open and close, so call them off the UI thread; everything else is cheap
/// and safe from any thread.
/// </summary>
public sealed unsafe class NativeEngine : IDisposable
{
    /// <summary>Why a capture endpoint didn't open when the Windows microphone privacy setting blocks desktop apps.</summary>
    public const string PrivacyReason = "is blocked by the Windows privacy settings";

    /// <summary>About 11 s of 18-channel audio for the recorder, as on the Mac.</summary>
    private const uint RingFrames = 1 << 19;

    public IntPtr Core { get; }
    private readonly IntPtr engine;
    private readonly Lock gate = new();

    public NativeEngine()
    {
        Core = Native.AudioCoreCreate(RingFrames);
        engine = Native.LbEngineCreate(Core);
    }

    public bool IsRunning => Native.LbEngineIsRunning(engine) != 0;

    /// <summary>
    /// Opens and starts <paramref name="plan"/>, replacing whatever ran. <paramref name="applyControls"/>
    /// runs after the old layout stops and before the new one starts, so per-track settings (which
    /// the core keys by track index) never reach the wrong track while tracks move.
    /// </summary>
    public EngineStatus Start(EnginePlan plan, uint periodFrames, Action<IntPtr>? applyControls = null)
    {
        lock (gate)
        {
            Native.LbEngineStop(engine);
            applyControls?.Invoke(Core);
            var strings = new List<IntPtr>();
            IntPtr Text(string? text)
            {
                if (text == null) return IntPtr.Zero;
                var p = Marshal.StringToHGlobalUni(text);
                strings.Add(p);
                return p;
            }
            try
            {
                var config = new LbEngineConfig
                {
                    InputCount = Math.Min(plan.Inputs.Count, Native.MaxInputs),
                    ClockFromInput = plan.ClockFromInput ? 1 : 0,
                    LoopbackCount = Math.Min(plan.Loopbacks.Count, Native.MaxInputs - Math.Min(plan.Inputs.Count, Native.MaxInputs)),
                    ClockOutputId = Text(plan.ClockOutput?.Id),
                    VenueId = Text(plan.Venue?.Id),
                    StreamId = Text(plan.Stream?.Id),
                    TrackCount = Math.Min(plan.Tracks.Count, Native.MaxTracks),
                    PeriodFrames = periodFrames,
                };
                for (int i = 0; i < config.InputCount; i++) config.InputIds[i] = Text(plan.Inputs[i].Id);
                for (int l = 0; l < config.LoopbackCount; l++)
                {
                    config.Loopbacks[l] = new LbLoopbackSpec { ProcessId = plan.Loopbacks[l].ProcessId, Exclude = plan.Loopbacks[l].Exclude ? 1 : 0 };
                }
                for (int t = 0; t < config.TrackCount; t++)
                {
                    var track = plan.Tracks[t];
                    config.Tracks[t] = new LbTrackSpec { Input = track.Input, Channel = track.Channel, Stereo = track.Stereo ? 1 : 0 };
                }

                LbEngineInfo info;
                char* error = stackalloc char[256];
                int result = Native.LbEngineStart(engine, &config, &info, error, 256);
                if (result != 0) throw new EngineStartException(new string(error));

                var problems = new List<string>();
                for (int i = 0; i < config.InputCount; i++)
                {
                    string why = Read(info.InputErrors + i * Native.ProblemLength);
                    if (why.Length > 0) problems.Add($"{plan.Inputs[i].Name} {why}, so its tracks are silent.");
                }
                for (int l = 0; l < config.LoopbackCount; l++)
                {
                    string why = Read(info.InputErrors + (config.InputCount + l) * Native.ProblemLength);
                    if (why.Length > 0) problems.Add($"Couldn't capture {plan.Loopbacks[l].Name} ({why}), so its track is silent.");
                }
                if (plan.Venue != null && Read(info.VenueError) is { Length: > 0 } venueWhy) problems.Add($"{plan.Venue.Name} {venueWhy}, so the venue mix is silent.");
                if (plan.Stream != null && Read(info.StreamError) is { Length: > 0 } streamWhy) problems.Add($"{plan.Stream.Name} {streamWhy}, so the stream mix is silent.");

                var latencies = new double?[config.TrackCount];
                for (int t = 0; t < latencies.Length; t++) latencies[t] = info.TrackLatencyMs[t] >= 0 ? info.TrackLatencyMs[t] : null;
                return new EngineStatus(info.SampleRate, info.PeriodFrames, info.VenueLatencyMs >= 0 ? info.VenueLatencyMs : null, latencies, problems);
            }
            finally
            {
                foreach (var p in strings) Marshal.FreeHGlobal(p);
            }
        }
    }

    private static string Read(char* chars) => new(chars);

    public void Stop()
    {
        lock (gate) Native.LbEngineStop(engine);
    }

    public AudioCoreAsyncStats InputStats(int input)
    {
        AudioCoreAsyncStats stats;
        Native.LbEngineReadInputStats(engine, input, &stats);
        return stats;
    }

    public void Dispose()
    {
        lock (gate)
        {
            Native.LbEngineDestroy(engine);
            Native.AudioCoreDestroy(Core);
        }
    }

    // MARK: Device changes

    /// <summary>Raised on a system thread whenever endpoints change; hop to the UI thread before acting.</summary>
    public static event Action? DevicesChanged;

    [UnmanagedCallersOnly]
    private static void OnDevicesChanged(IntPtr context) => DevicesChanged?.Invoke();

    /// <summary>Starts forwarding endpoint changes to <see cref="DevicesChanged"/>.</summary>
    public static void WatchDevices() => Native.LbWatchDevices(&OnDevicesChanged, IntPtr.Zero);
}
