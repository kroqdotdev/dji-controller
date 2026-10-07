using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Lavboard.MicSystems;
using Lavboard.Model;

namespace Lavboard;

public partial class App : Application
{
    private Window? window;

    /// <summary>Where a crash leaves its exception, so a report can include it.</summary>
    public static string CrashLogPath { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lavboard", "crash.log");

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
            window.Activate();
            model.Start();
        }
        catch (Exception e)
        {
            LogCrash(e);
            throw;
        }
    }

    /// <summary>The real engine, with every supported mic system.</summary>
    private static AppModel Live()
    {
        IMicSystem[] systems = [new DjiMicMini2S()];
        var engine = new WasapiEngine(systems, DispatcherQueue.GetForCurrentThread());
        return new AppModel(engine, systems, Track.DefaultSet());
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
