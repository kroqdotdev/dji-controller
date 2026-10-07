using System.Net.Http;
using System.Text.Json;
using Velopack;
using Velopack.Sources;

namespace Lavboard.Model;

public enum UpdateStage { Idle, Checking, Available, Downloading, Installing, ReadyToRestart, UpToDate, Failed }

/// <summary>
/// One-click updates with Velopack, mirroring UpdateController in the macOS app: a check on every
/// launch, an "Update to x.y.z" button that downloads, installs and restarts, and never a restart
/// in the middle of a recording.
/// </summary>
/// <remarks>
/// Windows releases are tagged windows-v*, next to the Mac's releases in the same repository and
/// never marked latest (the Mac's appcast lives at releases/latest). The newest windows-v release
/// carries Velopack's feed; <c>LAVBOARD_UPDATE_FEED</c> (a folder or URL) overrides it for testing.
/// </remarks>
public sealed class Updater : ObservableObject
{
    private const string Repository = "kroqdotdev/lavboard";
    private const string TagPrefix = "windows-v";
    private const string FeedFile = "releases.win.json";

    private UpdateStage stage;
    private string? availableVersion;
    private double? progress;
    private string? failure;
    private UpdateManager? manager;
    private UpdateInfo? update;

    public UpdateStage Stage { get => stage; private set { if (Set(ref stage, value)) Raise(nameof(IsBusy)); } }
    public string? AvailableVersion { get => availableVersion; private set => Set(ref availableVersion, value); }
    /// <summary>Download progress, 0 to 1, while downloading.</summary>
    public double? Progress { get => progress; private set => Set(ref progress, value); }
    public string? Failure { get => failure; private set => Set(ref failure, value); }

    /// <summary>Downloading or installing: recording waits meanwhile.</summary>
    public bool IsBusy => Stage is UpdateStage.Downloading or UpdateStage.Installing;
    /// <summary>Installed by Velopack, so updates can be applied (development builds can't).</summary>
    public bool IsInstalled { get; }
    public string CurrentVersion { get; }

    /// <summary>Asked right before restarting; return true to hold the restart (while recording).</summary>
    public Func<bool>? ShouldDeferRestart { get; set; }
    /// <summary>Raised right before the app exits to install, so it can save and shut audio down.</summary>
    public event EventHandler? Restarting;

    public Updater()
    {
        try
        {
            var probe = new UpdateManager(new SimpleFileSource(new DirectoryInfo(Path.GetTempPath())));
            IsInstalled = probe.IsInstalled;
            CurrentVersion = probe.CurrentVersion?.ToString() ?? AssemblyVersion();
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            CurrentVersion = AssemblyVersion();
        }
    }

    private static string AssemblyVersion() =>
        typeof(Updater).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";

    /// <summary>The launch check: quiet unless an update is found.</summary>
    public Task StartAsync() => IsInstalled ? CheckAsync(userInitiated: false) : Task.CompletedTask;

    /// <summary>A check the user asked for (Settings, or retrying after a failure).</summary>
    public async void CheckNow()
    {
        if (!IsInstalled)
        {
            Fail("Updates work in installed copies of Lavboard, not development builds.");
            return;
        }
        await CheckAsync(userInitiated: true);
    }

    private async Task CheckAsync(bool userInitiated)
    {
        if (Stage is UpdateStage.Checking or UpdateStage.Downloading or UpdateStage.Installing or UpdateStage.ReadyToRestart) return;
        if (userInitiated) Stage = UpdateStage.Checking;
        try
        {
            var source = await ResolveSource();
            update = null;
            if (source != null)
            {
                manager = new UpdateManager(source);
                update = await manager.CheckForUpdatesAsync();
            }
            if (update != null)
            {
                AvailableVersion = update.TargetFullRelease.Version.ToString();
                Stage = UpdateStage.Available;
            }
            else if (userInitiated)
            {
                ShowBriefly(UpdateStage.UpToDate);
            }
            else
            {
                Stage = UpdateStage.Idle;
            }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException or IOException or InvalidOperationException)
        {
            if (userInitiated) Fail(e.Message); else Stage = UpdateStage.Idle;
        }
    }

    /// <summary>Downloads the update, then installs and restarts, unless a recording holds the restart.</summary>
    public async void Install()
    {
        if (Stage != UpdateStage.Available || manager == null || update == null) return;
        Progress = null;
        Stage = UpdateStage.Downloading;
        try
        {
            var ui = SynchronizationContext.Current;
            await manager.DownloadUpdatesAsync(update, percent => ui?.Post(_ => Progress = percent / 100.0, null));
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Fail(e.Message);
            return;
        }
        if (ShouldDeferRestart?.Invoke() == true)
        {
            Stage = UpdateStage.ReadyToRestart;
            return;
        }
        Apply();
    }

    /// <summary>Restarts into an update held back while recording.</summary>
    public void RestartNow()
    {
        if (Stage == UpdateStage.ReadyToRestart && ShouldDeferRestart?.Invoke() != true) Apply();
    }

    private void Apply()
    {
        Stage = UpdateStage.Installing;
        Restarting?.Invoke(this, EventArgs.Empty);
        try
        {
            manager!.ApplyUpdatesAndRestart(update!.TargetFullRelease);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Fail(e.Message);
        }
    }

    private void Fail(string message)
    {
        Failure = message;
        Stage = UpdateStage.Failed;
    }

    private async void ShowBriefly(UpdateStage transient)
    {
        Stage = transient;
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (Stage == transient) Stage = UpdateStage.Idle;
    }

    /// <summary>Where the newest Windows release's feed lives, or null when there is none.</summary>
    private static async Task<IUpdateSource?> ResolveSource()
    {
        if (Environment.GetEnvironmentVariable("LAVBOARD_UPDATE_FEED") is { Length: > 0 } feed)
            return Directory.Exists(feed) ? new SimpleFileSource(new DirectoryInfo(feed)) : new SimpleWebSource(feed);

        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Lavboard");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        string json = await http.GetStringAsync($"https://api.github.com/repos/{Repository}/releases?per_page=100");
        using var releases = JsonDocument.Parse(json);
        // Newest first; the Mac's releases and drafts don't count.
        foreach (var release in releases.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            string? tag = release.GetProperty("tag_name").GetString();
            if (tag == null || !tag.StartsWith(TagPrefix, StringComparison.Ordinal)) continue;
            if (!release.GetProperty("assets").EnumerateArray().Any(a => a.GetProperty("name").GetString() == FeedFile)) continue;
            return new SimpleWebSource($"https://github.com/{Repository}/releases/download/{tag}/");
        }
        return null;
    }
}
