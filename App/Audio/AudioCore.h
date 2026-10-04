#ifndef AUDIO_CORE_H
#define AUDIO_CORE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

/// Real-time mixing core. Everything called from the IOProc is lock-free and allocation-free;
/// parameter setters and meter reads are safe from any thread.

CF_ASSUME_NONNULL_BEGIN

#define AC_MAX_INPUTS 4
#define AC_RING_CHANNELS 6 // 4 isolated tracks + stereo program mix

typedef struct AudioCore AudioCore;

typedef struct {
    float peak[AC_MAX_INPUTS]; // since the previous read, pre-fader
    float rms[AC_MAX_INPUTS];  // latest IO buffer, pre-fader
    float streamPeak;
    float venuePeak;
    uint64_t callbacks;
    uint64_t overruns;
} AudioCoreMeters;

AudioCore *AudioCoreCreate(uint32_t ringFramesPowerOfTwo);
void AudioCoreDestroy(AudioCore *_Nullable core);

/// Buffer indices into the IOProc's AudioBufferLists. Only change while the IOProc is stopped.
/// Pass -1 for an output that is not in use.
void AudioCoreSetLayout(AudioCore *core, int inputBuffer, int inputChannels, int venueBuffer, int streamBuffer);

void AudioCoreSetChannelGain(AudioCore *core, int channel, float linear);
void AudioCoreSetChannelMute(AudioCore *core, int channel, bool muted);
void AudioCoreSetChannelVenueSend(AudioCore *core, int channel, bool enabled);
void AudioCoreSetStreamLevel(AudioCore *core, float linear);
void AudioCoreSetVenueLevel(AudioCore *core, float linear);

void AudioCoreReadMeters(AudioCore *core, AudioCoreMeters *out);

/// Recording: frames are interleaved AC_RING_CHANNELS floats.
void AudioCoreStartRecording(AudioCore *core);
void AudioCoreStopRecording(AudioCore *core);
uint32_t AudioCoreReadRecorded(AudioCore *core, float *destination, uint32_t maxFrames);

OSStatus AudioCoreIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *_Nullable clientData);

CF_ASSUME_NONNULL_END

#endif
