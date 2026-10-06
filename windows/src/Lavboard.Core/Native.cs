using System.Runtime.InteropServices;

namespace Lavboard.Core.Interop;

// Mirrors of the C types in Shared/AudioCore/AudioCore.h, AudioCorePlatform.h and
// src/LavboardEngine/Engine.h. Field order and sizes must match the C structs exactly.

[StructLayout(LayoutKind.Sequential)]
public struct AudioBuffer
{
    public uint NumberChannels;
    public uint DataByteSize;
    public IntPtr Data;
}

[StructLayout(LayoutKind.Sequential)]
public struct AudioTimeStamp
{
    public double SampleTime;
    public ulong HostTime;
}

/// <summary>Where a track reads its audio from; see AudioCoreTrackLayout.</summary>
[StructLayout(LayoutKind.Sequential)]
public struct TrackLayout
{
    public int Buffer;
    public int Channel;
    public int BufferRight;
    public int ChannelRight;
    public byte Stereo;
    public int AsyncSource;

    public static TrackLayout Mono(int buffer, int channel) =>
        new() { Buffer = buffer, Channel = channel, BufferRight = -1, ChannelRight = -1, AsyncSource = -1 };

    public static TrackLayout StereoPair(int buffer, int left, int right) =>
        new() { Buffer = buffer, Channel = left, BufferRight = buffer, ChannelRight = right, Stereo = 1, AsyncSource = -1 };

    public static TrackLayout Async(int source, int channel) =>
        new() { Buffer = -1, Channel = channel, BufferRight = -1, ChannelRight = -1, AsyncSource = source };
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct AudioCoreMeters
{
    public fixed float PeakLeft[Native.MaxTracks];
    public fixed float PeakRight[Native.MaxTracks];
    public float StreamPeak;
    public float VenuePeak;
    public ulong Callbacks;
    public ulong Overruns;
}

[StructLayout(LayoutKind.Sequential)]
public struct AudioCoreAsyncStats
{
    public double BufferedFrames;
    public double Correction;
    public ulong Underruns;
    public ulong Overflows;
    public byte Running;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct LbDevice
{
    public fixed char Id[Native.IdLength];
    public fixed char Name[Native.NameLength];
    public int IsInput;
    public int Channels;
    public int SampleRate;
    public int IsDefault;
}

public static unsafe partial class Native
{
    public const int MaxTracks = 8;
    public const int MaxRingChannels = MaxTracks * 2 + 2;
    public const int AsyncMaxFrames = 4096;
    public const int IdLength = 256;
    public const int NameLength = 256;
    /// <summary>The engine API version this build expects (LbEngineVersion).</summary>
    public const int ExpectedEngineVersion = 1;

    private const string Engine = "LavboardEngine";

    [LibraryImport(Engine)] public static partial int LbEngineVersion();
    [LibraryImport(Engine)] public static partial int LbListDevices(LbDevice* devices, int capacity);

    [LibraryImport(Engine)] public static partial IntPtr AudioCoreCreate(uint ringFramesPowerOfTwo);
    [LibraryImport(Engine)] public static partial void AudioCoreDestroy(IntPtr core);
    [LibraryImport(Engine)] public static partial void AudioCoreSetLayout(IntPtr core, TrackLayout* tracks, int trackCount, int venueBuffer, int streamBuffer);
    [LibraryImport(Engine)] public static partial void AudioCoreSetAsyncSources(IntPtr core, IntPtr* sources, int count);
    [LibraryImport(Engine)] public static partial int AudioCoreTrackCount(IntPtr core);
    [LibraryImport(Engine)] public static partial int AudioCoreRingChannels(IntPtr core);
    [LibraryImport(Engine)] public static partial void AudioCoreSetTrackGain(IntPtr core, int track, float linear);
    [LibraryImport(Engine)] public static partial void AudioCoreSetTrackMute(IntPtr core, int track, [MarshalAs(UnmanagedType.U1)] bool muted);
    [LibraryImport(Engine)] public static partial void AudioCoreSetTrackVenueSend(IntPtr core, int track, [MarshalAs(UnmanagedType.U1)] bool enabled);
    [LibraryImport(Engine)] public static partial void AudioCoreSetTrackBalance(IntPtr core, int track, float balance);
    [LibraryImport(Engine)] public static partial void AudioCoreSetStreamLevel(IntPtr core, float linear);
    [LibraryImport(Engine)] public static partial void AudioCoreSetVenueLevel(IntPtr core, float linear);
    [LibraryImport(Engine)] public static partial void AudioCoreReadMeters(IntPtr core, AudioCoreMeters* meters);
    [LibraryImport(Engine)] public static partial void AudioCoreStartRecording(IntPtr core);
    [LibraryImport(Engine)] public static partial void AudioCoreStopRecording(IntPtr core);
    [LibraryImport(Engine)] public static partial uint AudioCoreReadRecorded(IntPtr core, float* destination, uint maxFrames);
    [LibraryImport(Engine)] public static partial int AudioCoreIOProc(uint device, AudioTimeStamp* now, IntPtr input, AudioTimeStamp* inputTime,
                                                                      IntPtr output, AudioTimeStamp* outputTime, IntPtr clientData);

    [LibraryImport(Engine)] public static partial IntPtr AudioCoreAsyncCreate(int channels, double sourceRate, double targetRate, uint latencyFrames);
    [LibraryImport(Engine)] public static partial void AudioCoreAsyncDestroy(IntPtr source);
    [LibraryImport(Engine)] public static partial int AudioCoreAsyncLookahead(IntPtr source);
    [LibraryImport(Engine)] public static partial int AudioCoreAsyncIOProc(uint device, AudioTimeStamp* now, IntPtr input, AudioTimeStamp* inputTime,
                                                                           IntPtr output, AudioTimeStamp* outputTime, IntPtr clientData);
    [LibraryImport(Engine)] public static partial void AudioCoreAsyncRender(IntPtr source, uint frames);
    [LibraryImport(Engine)] public static partial float* AudioCoreAsyncOutput(IntPtr source, int channel);
    [LibraryImport(Engine)] public static partial void AudioCoreAsyncReadStats(IntPtr source, AudioCoreAsyncStats* stats);
}

/// <summary>An unmanaged AudioBufferList with room for a fixed number of buffers.</summary>
public sealed unsafe class BufferList : IDisposable
{
    // mNumberBuffers (4 bytes), padding to the pointer alignment, then the AudioBuffer array.
    private static readonly int Header = IntPtr.Size;

    public IntPtr Pointer { get; }
    public int Capacity { get; }

    public BufferList(int capacity)
    {
        Capacity = capacity;
        Pointer = Marshal.AllocHGlobal(Header + Math.Max(capacity, 1) * sizeof(AudioBuffer));
        Count = 0;
    }

    public int Count
    {
        get => *(int*)Pointer;
        set => *(uint*)Pointer = (uint)value;
    }

    public ref AudioBuffer this[int index] => ref ((AudioBuffer*)(Pointer + Header))[index];

    /// <summary>Points buffer <paramref name="index"/> at interleaved float samples.</summary>
    public void Set(int index, float* samples, int frames, int channels)
    {
        this[index] = new AudioBuffer { NumberChannels = (uint)channels, DataByteSize = (uint)(frames * channels * sizeof(float)), Data = (IntPtr)samples };
    }

    public void Dispose() => Marshal.FreeHGlobal(Pointer);
}
