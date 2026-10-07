#ifndef AUDIO_CORE_H
#define AUDIO_CORE_H

#if defined(__APPLE__)
#include <CoreAudio/CoreAudio.h>
#else
#include "AudioCorePlatform.h" // CoreAudio's buffer types, for platforms without CoreAudio
#endif
#include <stdbool.h>
#include <stdint.h>

/// Real-time mixing core. Everything called from the IOProc is lock-free and allocation-free;
/// parameter setters and meter reads are safe from any thread.

#ifdef __cplusplus
extern "C" {
#endif

CF_ASSUME_NONNULL_BEGIN

#define AC_MAX_TRACKS 8
/// Every track can be stereo, plus the stereo program mix.
#define AC_MAX_RING_CHANNELS (AC_MAX_TRACKS * 2 + 2)

/// Devices that run on their own clock (Bluetooth mics, devices without 48 kHz) are captured by
/// their own IOProc and resampled in the mixer. At most one per track.
#define AC_MAX_ASYNC_SOURCES AC_MAX_TRACKS
/// Input channels an async source captures: the device's first ones.
#define AC_ASYNC_MAX_CHANNELS 8
/// Longest mixer IO cycle async sources are resampled for; longer cycles leave them silent.
#define AC_ASYNC_MAX_FRAMES 4096

typedef struct AudioCore AudioCore;
typedef struct AudioCoreAsyncSource AudioCoreAsyncSource;

/// Where a track reads its audio from. With `asyncSource` -1, `buffer` and `channel` index the
/// mixer IOProc's input AudioBufferList, and a buffer index of -1 means the source is missing and
/// the track is silent. With `asyncSource` >= 0, the channels are that async source's channels and
/// the buffer fields are ignored.
typedef struct {
    int buffer;
    int channel;
    int bufferRight;  // stereo tracks only
    int channelRight; // stereo tracks only
    bool stereo;
    int asyncSource;
} AudioCoreTrackLayout;

typedef struct {
    float peakLeft[AC_MAX_TRACKS];  // since the previous read, pre-fader (mono tracks: the only channel)
    float peakRight[AC_MAX_TRACKS]; // stereo tracks only
    float streamPeak;
    float venuePeak;
    uint64_t callbacks;
    uint64_t overruns;
} AudioCoreMeters;

AudioCore *AudioCoreCreate(uint32_t ringFramesPowerOfTwo);
void AudioCoreDestroy(AudioCore *_Nullable core);

/// Track sources and output buffer indices (-1 for an output that is not in use).
/// Only change while the IOProc is stopped.
void AudioCoreSetLayout(AudioCore *core, const AudioCoreTrackLayout *_Nullable tracks, int trackCount,
                        int venueBuffer, int streamBuffer);
/// The async sources that track layouts refer to by index. Only change while the IOProc is stopped;
/// the sources must outlive their use here.
void AudioCoreSetAsyncSources(AudioCore *core, AudioCoreAsyncSource *const _Nullable *_Nullable sources, int count);
int AudioCoreTrackCount(AudioCore *core);
/// Interleaved channels per recorded frame: each track's channels in order, then the stereo mix.
int AudioCoreRingChannels(AudioCore *core);

void AudioCoreSetTrackGain(AudioCore *core, int track, float linear);
void AudioCoreSetTrackMute(AudioCore *core, int track, bool muted);
void AudioCoreSetTrackVenueSend(AudioCore *core, int track, bool enabled);
/// -1 (left) ... 0 (centre) ... 1 (right). Only affects stereo tracks.
void AudioCoreSetTrackBalance(AudioCore *core, int track, float balance);
void AudioCoreSetStreamLevel(AudioCore *core, float linear);
void AudioCoreSetVenueLevel(AudioCore *core, float linear);

void AudioCoreReadMeters(AudioCore *core, AudioCoreMeters *out);

/// Recording: frames are interleaved AudioCoreRingChannels floats.
void AudioCoreStartRecording(AudioCore *core);
void AudioCoreStopRecording(AudioCore *core);
uint32_t AudioCoreReadRecorded(AudioCore *core, float *destination, uint32_t maxFrames);

OSStatus AudioCoreIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *_Nullable clientData);

// MARK: Async sources

typedef struct {
    double bufferedFrames; // smoothed source frames waiting to be resampled
    double correction;     // current ratio nudge; 0.0001 means the source is read 100 ppm faster
    uint64_t underruns;
    uint64_t overflows;
    bool running;          // buffered enough and producing audio
} AudioCoreAsyncStats;

/// A device on its own clock. `AudioCoreAsyncIOProc`, installed on the device with the source as
/// client data, captures its first `channels` input channels at `sourceRate`. The mixer resamples
/// them to `targetRate`, nudging the ratio by up to 0.2% so that about `latencyFrames` source
/// frames stay buffered on top of the resampler's own lookahead. Returns NULL for invalid rates.
AudioCoreAsyncSource *_Nullable AudioCoreAsyncCreate(int channels, double sourceRate, double targetRate,
                                                     uint32_t latencyFrames);
void AudioCoreAsyncDestroy(AudioCoreAsyncSource *_Nullable source);

/// Source frames the resampler needs beyond the read position, on each side.
int AudioCoreAsyncLookahead(AudioCoreAsyncSource *source);

OSStatus AudioCoreAsyncIOProc(AudioObjectID device, const AudioTimeStamp *now,
                              const AudioBufferList *input, const AudioTimeStamp *inputTime,
                              AudioBufferList *output, const AudioTimeStamp *outputTime, void *_Nullable clientData);

/// Resamples the next `frames` output frames (at most AC_ASYNC_MAX_FRAMES) into the source's
/// output buffers. The mixer IOProc calls this once per cycle; exposed for tests.
void AudioCoreAsyncRender(AudioCoreAsyncSource *source, uint32_t frames);
/// One channel of the last render, or NULL for a channel the source doesn't capture.
const float *_Nullable AudioCoreAsyncOutput(AudioCoreAsyncSource *source, int channel);

void AudioCoreAsyncReadStats(AudioCoreAsyncSource *source, AudioCoreAsyncStats *out);

CF_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif
