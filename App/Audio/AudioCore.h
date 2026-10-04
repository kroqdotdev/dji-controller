#ifndef AUDIO_CORE_H
#define AUDIO_CORE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

/// Real-time mixing core. Everything called from the IOProc is lock-free and allocation-free;
/// parameter setters and meter reads are safe from any thread.

CF_ASSUME_NONNULL_BEGIN

#define AC_MAX_TRACKS 8
/// Every track can be stereo, plus the stereo program mix.
#define AC_MAX_RING_CHANNELS (AC_MAX_TRACKS * 2 + 2)

typedef struct AudioCore AudioCore;

/// Where a track reads its audio from, as indices into the IOProc's input AudioBufferList.
/// A buffer index of -1 means the source is missing and the track is silent.
typedef struct {
    int buffer;
    int channel;
    int bufferRight;  // stereo tracks only
    int channelRight; // stereo tracks only
    bool stereo;
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

CF_ASSUME_NONNULL_END

#endif
