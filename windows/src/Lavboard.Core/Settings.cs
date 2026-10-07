using System.Text.Json;
using System.Text.Json.Serialization;
using Lavboard.Model;

namespace Lavboard.Core;

/// <summary>Everything the app remembers between launches; the same settings the macOS app keeps in its defaults.</summary>
public sealed class Settings
{
    public List<Track>? Tracks { get; set; }
    public string? StreamOutputId { get; set; }
    public string? VenueOutputId { get; set; }
    public double StreamLevelDb { get; set; }
    public double VenueLevelDb { get; set; }
    public bool BackupOnTransmitters { get; set; }
    public string? RecordingFolder { get; set; }
    public string RecordingFormat { get; set; } = "24-bit";
    public int BufferFrames { get; set; } = 64;

    /// <summary>
    /// %APPDATA%\Lavboard. Not %LOCALAPPDATA%\Lavboard: that is the installer's folder, which
    /// Velopack owns and removes on uninstall. Declared first: static initializers run in order.
    /// </summary>
    public static string DataFolder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lavboard");

    public static string DefaultPath { get; } = Path.Combine(DataFolder, "settings.json");

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        // Hand-edited files may put the source's "kind" after its other fields.
        AllowOutOfOrderMetadataProperties = true,
    };

    /// <summary>The saved settings, or defaults when there are none or they can't be read.</summary>
    public static Settings Load(string path)
    {
        try
        {
            using var file = File.OpenRead(path);
            var settings = JsonSerializer.Deserialize<Settings>(file, Options) ?? new Settings();
            settings.Tracks = settings.Tracks?.Take(Track.Maximum).ToList();
            return settings;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            return new Settings();
        }
    }

    /// <summary>Writes atomically, so a crash mid-save never leaves a half-written file.</summary>
    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, Options));
        File.Move(temporary, path, overwrite: true);
    }
}
