using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Lavboard.Core;
using Lavboard.MicSystems;
using Lavboard.Model;

namespace Lavboard;

public partial class App : Application
{
    private Window? window;

    /// <summary>Where a crash leaves its exception, so a report can include it.</summary>
    public static string CrashLogPath { get; } = Path.Combine(Settings.DataFolder, "crash.log");

    public App()
    {
        UnhandledException += (_, e) => LogCrash(e.Exception);
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            // `--scene <name>` shows a demo desk instead of the real devices (see DemoScenes).
            var commandLine = Environment.GetCommandLineArgs();
            int scene = Array.IndexOf(commandLine, "--scene");
            var model = scene >= 0 ? DemoScenes.Create(scene + 1 < commandLine.Length ? commandLine[scene + 1] : null) : Live();
            window = new MainWindow(model);
            window.Closed += (_, _) => settingsStore?.Save();
            window.Activate();
            model.Start();
            // Installing an update exits the process: save and finish any recording first. The engine
            // stays up: if applying fails the app carries on, and exiting releases the devices anyway.
            model.Updates.Restarting += (_, _) =>
            {
                model.StopRecording();
                settingsStore?.Save();
            };
            if (scene < 0) _ = model.Updates.StartAsync();
        }
        catch (Exception e)
        {
            LogCrash(e);
            throw;
        }
    }

    private SettingsStore? settingsStore;

    /// <summary>The real engine, with every supported mic system and the saved settings.</summary>
    private AppModel Live()
    {
        IMicSystem[] systems = [new DjiMicMini2S()];
        var ui = DispatcherQueue.GetForCurrentThread();
        var settings = Settings.Load(Settings.DefaultPath);
        var model = new AppModel(new WasapiEngine(systems, ui), systems, settings.Tracks ?? Track.DefaultSet());
        SettingsStore.Apply(settings, model);
        settingsStore = new SettingsStore(model, Settings.DefaultPath, ui);
        return model;
    }

    private static void LogCrash(Exception e)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CrashLogPath)!);
            File.AppendAllText(CrashLogPath, $"{DateTime.Now:O}\n{e}\n\n");
        }
        catch (IOException) { }
    }
}
