using System.Buffers.Binary;
using Lavboard.Core;
using Lavboard.Core.Interop;
using Xunit;

namespace Lavboard.Tests;

public sealed class RecordingTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "lavboard-tests-" + Guid.NewGuid().ToString("N"));

    public RecordingTests() => Directory.CreateDirectory(folder);
    public void Dispose() => Directory.Delete(folder, recursive: true);

    private static (int Format, int Channels, int Rate, int Bits, int RiffSize, int DataSize) Header(byte[] wav) =>
        (BinaryPrimitives.ReadUInt16LittleEndian(wav.AsSpan(20)), BinaryPrimitives.ReadUInt16LittleEndian(wav.AsSpan(22)),
         (int)BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(24)), BinaryPrimitives.ReadUInt16LittleEndian(wav.AsSpan(34)),
         (int)BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(4)), (int)BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(40)));

    [Fact]
    public void TwentyFourBitFilesHoldScaledIntegers()
    {
        string path = Path.Combine(folder, "a.wav");
        using (var wav = new WavWriter(path, 2, 48_000, RecordingFormat.Pcm24)) wav.Write([0.5f, -1f, 0f, 1f]);
        var bytes = File.ReadAllBytes(path);
        Assert.Equal((1, 2, 48_000, 24, 36 + 12, 12), Header(bytes));
        int first = bytes[44] | bytes[45] << 8 | (sbyte)bytes[46] << 16;
        int second = bytes[47] | bytes[48] << 8 | (sbyte)bytes[49] << 16;
        Assert.Equal(4_194_304, first);
        Assert.Equal(-8_388_607, second);
    }

    [Fact]
    public void OddDataChunksArePadded()
    {
        string path = Path.Combine(folder, "b.wav");
        using (var wav = new WavWriter(path, 1, 44_100, RecordingFormat.Pcm24)) wav.Write([0.25f]);
        var bytes = File.ReadAllBytes(path);
        Assert.Equal(44 + 3 + 1, bytes.Length);
        Assert.Equal((1, 1, 44_100, 24, 36 + 3 + 1, 3), Header(bytes));
    }

    [Fact]
    public unsafe void SessionsWriteEveryTrackRawPlusTheMix()
    {
        using var core = new CoreHarness(ringFrames: 1 << 14);
        core.Cycle();
        (string, int)[] tracks = [("Host", 1), ("Q/A", 1), ("", 1), ("Panel", 1)];
        var session = RecordingSession.Start(core.Core, folder, tracks, 48_000, RecordingFormat.Float32, new DateTime(2026, 10, 7, 21, 30, 5));
        // A muted track still records: files are pre-fader.
        Native.AudioCoreSetTrackMute(core.Core, 1, true);
        for (int i = 0; i < 20; i++) core.Cycle();
        Assert.Equal(0ul, session.Stop());

        string dir = Path.Combine(folder, "Session 2026-10-07 21.30.05");
        Assert.Equal(dir, session.Folder);
        Assert.Equal(["01 Host.wav", "02 Q-A.wav", "03 Track 3.wav", "04 Panel.wav", "05 Mix.wav"],
                     Directory.GetFiles(dir).Select(Path.GetFileName).Order());
        var guest = File.ReadAllBytes(Path.Combine(dir, "02 Q-A.wav"));
        Assert.Equal((3, 1, 48_000, 32, 36 + 20 * 64 * 4, 20 * 64 * 4), Header(guest));
        Assert.Equal(0.2f, BinaryPrimitives.ReadSingleLittleEndian(guest.AsSpan(44 + 4 * 10)), 5);
        var mix = File.ReadAllBytes(Path.Combine(dir, "05 Mix.wav"));
        Assert.Equal(2, Header(mix).Channels);
    }

    [Fact]
    public void SessionsWaitForTheTracksToBeSetUp()
    {
        using var core = new CoreHarness();
        Assert.Throws<InvalidOperationException>(() =>
            RecordingSession.Start(core.Core, folder, [("Only one", 1)], 48_000, RecordingFormat.Pcm24, DateTime.Now));
    }
}
