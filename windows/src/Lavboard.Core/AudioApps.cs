using System.Diagnostics;
using Lavboard.Core.Interop;

namespace Lavboard.Core;

/// <summary>An app that has opened audio, for app audio tracks. <see cref="AppId"/> is its executable's name, e.g. "spotify.exe".</summary>
public sealed record AudioApp(string AppId, string Name, bool Playing);

/// <summary>Apps with audio sessions, and the processes behind them, for process loopback capture.</summary>
public static class AudioApps
{
    /// <summary>
    /// Streaming apps never appear: capturing them would feed the stream back into itself. The
    /// same apps the macOS app leaves out.
    /// </summary>
    private static readonly HashSet<string> StreamingApps = new(StringComparer.OrdinalIgnoreCase)
    {
        "obs64.exe", "obs32.exe", "streamlabs obs.exe", "streamlabs desktop.exe", "lavboard.exe",
    };

    /// <summary>Every app with an audio session on any output, playing ones marked, Lavboard and streaming apps left out.</summary>
    public static unsafe IReadOnlyList<AudioApp> List()
    {
        int count = Native.LbListAudioSessions(null, 0);
        if (count <= 0) return [];
        var sessions = new LbAudioSession[count + 8];
        fixed (LbAudioSession* p = sessions) count = Math.Min(Native.LbListAudioSessions(p, sessions.Length), sessions.Length);

        var apps = new Dictionary<string, AudioApp>(StringComparer.OrdinalIgnoreCase);
        foreach (var session in sessions.Take(count))
        {
            if (session.ProcessId == Environment.ProcessId || Describe(session.ProcessId) is not { } app) continue;
            var (appId, name) = app;
            if (StreamingApps.Contains(appId)) continue;
            bool playing = session.Active != 0 || (apps.TryGetValue(appId, out var known) && known.Playing);
            apps[appId] = new AudioApp(appId, name, playing);
        }
        return apps.Values.OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>
    /// The process to capture for an app: its oldest running process with that executable name,
    /// which for browsers and Electron apps is the parent of the processes that actually play.
    /// Loopback capture includes the whole tree. Null when the app isn't running.
    /// </summary>
    public static uint? ProcessFor(string appId)
    {
        var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(appId));
        try
        {
            return processes.Select(p => (Process: p, Started: StartTime(p))).OrderBy(p => p.Started).Select(p => (uint?)p.Process.Id).FirstOrDefault();
        }
        finally
        {
            foreach (var p in processes) p.Dispose();
        }
    }

    private static DateTime StartTime(Process process)
    {
        try { return process.StartTime; }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { return DateTime.MaxValue; }
    }

    private static (string AppId, string Name)? Describe(uint processId)
    {
        try
        {
            using var process = Process.GetProcessById((int)processId);
            string appId = process.ProcessName + ".exe";
            string name = process.ProcessName;
            try
            {
                if (process.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } description) name = description;
            }
            catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                // Elevated and protected processes don't share their details; the process name will do.
            }
            return (appId.ToLowerInvariant(), name);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException)
        {
            return null; // gone since the session list was taken
        }
    }
}
