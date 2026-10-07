using System.Buffers.Binary;
using System.Globalization;
using Lavboard.Core.Interop;

namespace Lavboard.Core;

public enum RecordingFormat { Pcm24, Float32 }

/// <summary>A recording in progress.</summary>
public interface IRecording
{
    string Folder { get; }
    /// <summary>Finishes the files and returns how many buffers were dropped.</summary>
    ulong Stop();
}

public static class RecordingFormats
{
    /// <summary>The names the format picker shows, as on the Mac.</summary>
    public static string Label(this RecordingFormat format) => format == RecordingFormat.Pcm24 ? "24-bit" : "32-bit float";
    public static RecordingFormat Parse(string? label) => label == "32-bit float" ? RecordingFormat.Float32 : RecordingFormat.Pcm24;
}

/// <summary>A WAV file written as float samples arrive, in 24-bit PCM or 32-bit float.</summary>
public sealed class WavWriter : IDisposable
{
    private readonly FileStream file;
    private readonly int channels;
    private readonly RecordingFormat format;
    private readonly int sampleRate;
    private long dataBytes;
    private byte[] buffer = [];

    public WavWriter(string path, int channels, int sampleRate, RecordingFormat format)
    {
        this.channels = channels;
        this.format = format;
        this.sampleRate = sampleRate;
        file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16);
        WriteHeader();
    }

    private int BytesPerSample => format == RecordingFormat.Pcm24 ? 3 : 4;

    /// <summary>Appends interleaved frames.</summary>
    public void Write(ReadOnlySpan<float> interleaved)
    {
        int bytes = interleaved.Length * BytesPerSample;
        if (buffer.Length < bytes) buffer = new byte[bytes];
        var span = buffer.AsSpan(0, bytes);
        if (format == RecordingFormat.Float32)
        {
            for (int i = 0; i < interleaved.Length; i++) BinaryPrimitives.WriteSingleLittleEndian(span[(i * 4)..], interleaved[i]);
        }
        else
        {
            for (int i = 0; i < interleaved.Length; i++)
            {
                int value = (int)Math.Round(Math.Clamp(interleaved[i], -1f, 1f) * 8_388_607f);
                span[i * 3] = (byte)value;
                span[i * 3 + 1] = (byte)(value >> 8);
                span[i * 3 + 2] = (byte)(value >> 16);
            }
        }
        file.Write(span);
        dataBytes += bytes;
    }

    /// <param name="pad">The pad byte RIFF requires after an odd-sized data chunk.</param>
    private void WriteHeader(int pad = 0)
    {
        Span<byte> header = stackalloc byte[44];
        int blockAlign = channels * BytesPerSample;
        "RIFF"u8.CopyTo(header);
        BinaryPrimitives.WriteUInt32LittleEndian(header[4..], (uint)Math.Min(36 + dataBytes + pad, uint.MaxValue));
        "WAVEfmt "u8.CopyTo(header[8..]);
        BinaryPrimitives.WriteUInt32LittleEndian(header[16..], 16);
        BinaryPrimitives.WriteUInt16LittleEndian(header[20..], (ushort)(format == RecordingFormat.Float32 ? 3 : 1));
        BinaryPrimitives.WriteUInt16LittleEndian(header[22..], (ushort)channels);
        BinaryPrimitives.WriteUInt32LittleEndian(header[24..], (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(header[28..], (uint)(sampleRate * blockAlign));
        BinaryPrimitives.WriteUInt16LittleEndian(header[32..], (ushort)blockAlign);
        BinaryPrimitives.WriteUInt16LittleEndian(header[34..], (ushort)(BytesPerSample * 8));
        "data"u8.CopyTo(header[36..]);
        BinaryPrimitives.WriteUInt32LittleEndian(header[40..], (uint)Math.Min(dataBytes, uint.MaxValue));
        file.Write(header);
    }

    /// <summary>Writes the final sizes into the header and closes the file.</summary>
    public void Dispose()
    {
        int pad = (int)(dataBytes % 2);
        if (pad == 1) file.WriteByte(0);
        file.Position = 0;
        WriteHeader(pad);
        file.Dispose();
    }
}

/// <summary>
/// One recording: the core's ring buffer drained every 20 ms into one WAV per track (raw and
/// pre-fader, so live mutes never destroy material) plus the stereo mix. Mirrors Recorder in the
/// macOS app.
/// </summary>
public sealed class RecordingSession : IRecording
{
    private readonly IntPtr core;
    private readonly WavWriter[] files;
    private readonly int[] fileChannels;
    private readonly Thread thread;
    private volatile bool stopRequested;

    public string Folder { get; }

    private RecordingSession(IntPtr core, string folder, WavWriter[] files, int[] fileChannels)
    {
        this.core = core;
        Folder = folder;
        this.files = files;
        this.fileChannels = fileChannels;
        thread = new Thread(Run) { Name = "Recorder", IsBackground = true, Priority = ThreadPriority.AboveNormal };
    }

    /// <summary>
    /// Starts recording into a new "Session yyyy-MM-dd HH.mm.ss" folder inside <paramref name="parent"/>.
    /// Throws <see cref="IOException"/> or <see cref="UnauthorizedAccessException"/> when the folder
    /// can't be written, and <see cref="InvalidOperationException"/> while the core's tracks don't
    /// match <paramref name="tracks"/> yet.
    /// </summary>
    public static RecordingSession Start(IntPtr core, string parent, IReadOnlyList<(string Name, int Channels)> tracks, int sampleRate,
                                         RecordingFormat format, DateTime now)
    {
        if (Native.AudioCoreRingChannels(core) != tracks.Sum(t => t.Channels) + 2)
            throw new InvalidOperationException("Couldn't start recording: the tracks are still being set up. Try again in a moment.");
        string folder = Path.Combine(parent, "Session " + now.ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture));
        Directory.CreateDirectory(folder);
        var specs = tracks.Select((t, i) => (Name: $"{i + 1:00} {Sanitize(t.Name.Length == 0 ? $"Track {i + 1}" : t.Name)}.wav", t.Channels))
            .Append(($"{tracks.Count + 1:00} Mix.wav", 2)).ToList();
        var files = new List<WavWriter>();
        try
        {
            foreach (var spec in specs) files.Add(new WavWriter(Path.Combine(folder, spec.Item1), spec.Item2, sampleRate, format));
        }
        catch
        {
            foreach (var file in files) file.Dispose();
            throw;
        }
        var session = new RecordingSession(core, folder, files.ToArray(), specs.Select(s => s.Item2).ToArray());
        Native.AudioCoreStartRecording(core);
        session.thread.Start();
        return session;
    }

    /// <summary>Stops capture, writes what is buffered, closes the files and returns how many buffers the ring dropped.</summary>
    public unsafe ulong Stop()
    {
        Native.AudioCoreStopRecording(core);
        stopRequested = true;
        thread.Join();
        AudioCoreMeters meters;
        Native.AudioCoreReadMeters(core, &meters);
        return meters.Overruns;
    }

    private unsafe void Run()
    {
        const int chunk = 4096;
        int ringChannels = Native.AudioCoreRingChannels(core);
        var interleaved = new float[chunk * ringChannels];
        var scratch = new float[chunk * 2];
        while (true)
        {
            bool stopping = stopRequested;
            uint frames;
            do
            {
                fixed (float* p = interleaved) frames = Native.AudioCoreReadRecorded(core, p, chunk);
                if (frames == 0) break;
                int column = 0;
                for (int i = 0; i < files.Length; i++)
                {
                    int channels = fileChannels[i];
                    for (int f = 0; f < frames; f++)
                    {
                        for (int c = 0; c < channels; c++) scratch[f * channels + c] = interleaved[f * ringChannels + column + c];
                    }
                    files[i].Write(scratch.AsSpan(0, (int)frames * channels));
                    column += channels;
                }
            } while (frames == chunk);
            if (stopping) break;
            Thread.Sleep(20);
        }
        foreach (var file in files) file.Dispose();
    }

    private static string Sanitize(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string(name.Select(c => invalid.Contains(c) ? '-' : c).ToArray()).Trim().TrimEnd('.');
    }
}
