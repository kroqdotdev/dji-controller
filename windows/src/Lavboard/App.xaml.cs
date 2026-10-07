using Microsoft.UI.Xaml;
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
            // Until the WASAPI engine lands, every launch shows a demo desk (later: only with --scene).
            var commandLine = Environment.GetCommandLineArgs();
            int scene = Array.IndexOf(commandLine, "--scene");
            var model = DemoScenes.Create(scene >= 0 && scene + 1 < commandLine.Length ? commandLine[scene + 1] : null);
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
