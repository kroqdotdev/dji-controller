#include "AudioCore.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AudioCore {
    _Atomic float gain[AC_MAX_TRACKS];
    _Atomic bool mute[AC_MAX_TRACKS];
    _Atomic bool venueSend[AC_MAX_TRACKS];
    _Atomic float balance[AC_MAX_TRACKS];
    _Atomic float streamLevel;
    _Atomic float venueLevel;

    _Atomic float peakLeft[AC_MAX_TRACKS];
    _Atomic float peakRight[AC_MAX_TRACKS];
    _Atomic float streamPeak;
    _Atomic float venuePeak;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t overruns;

    AudioCoreTrackLayout tracks[AC_MAX_TRACKS];
    int trackCount;
    AudioCoreAsyncSource *async[AC_MAX_ASYNC_SOURCES];
    int asyncCount;
    int ringChannels;
    int venueBuffer;
    int streamBuffer;

    // Smoothed per-side gains, owned by the IOProc: [track][0 = left, 1 = right].
    float curStream[AC_MAX_TRACKS][2];
    float curVenue[AC_MAX_TRACKS][2];
    float curStreamLevel;
    float curVenueLevel;

    float *ring;
    uint32_t ringFrames;
    _Atomic uint64_t writePos;
    _Atomic uint64_t readPos;
    _Atomic bool recording;
};

AudioCore *AudioCoreCreate(uint32_t ringFrames) {
    AudioCore *c = calloc(1, sizeof(AudioCore));
    c->ringFrames = ringFrames;
    c->ring = calloc((size_t)ringFrames * AC_MAX_RING_CHANNELS, sizeof(float));
    for (int i = 0; i < AC_MAX_TRACKS; i++) {
        atomic_init(&c->gain[i], 1.0f);
        atomic_init(&c->venueSend[i], true);
    }
    atomic_init(&c->streamLevel, 1.0f);
    atomic_init(&c->venueLevel, 1.0f);
    c->ringChannels = 2;
    c->venueBuffer = -1;
    c->streamBuffer = -1;
    return c;
}

void AudioCoreDestroy(AudioCore *c) {
    if (!c) return;
    free(c->ring);
    free(c);
}

void AudioCoreSetLayout(AudioCore *c, const AudioCoreTrackLayout *tracks, int trackCount, int venueBuffer, int streamBuffer) {
    if (trackCount < 0) trackCount = 0;
    if (trackCount > AC_MAX_TRACKS) trackCount = AC_MAX_TRACKS;
    int channels = 2;
    for (int i = 0; i < trackCount; i++) {
        c->tracks[i] = tracks[i];
        channels += tracks[i].stereo ? 2 : 1;
    }
    c->trackCount = trackCount;
    c->ringChannels = channels;
    c->venueBuffer = venueBuffer;
    c->streamBuffer = streamBuffer;
}

void AudioCoreSetAsyncSources(AudioCore *c, AudioCoreAsyncSource *const *sources, int count) {
    if (!sources || count < 0) count = 0;
    if (count > AC_MAX_ASYNC_SOURCES) count = AC_MAX_ASYNC_SOURCES;
    for (int i = 0; i < AC_MAX_ASYNC_SOURCES; i++) c->async[i] = i < count ? sources[i] : NULL;
    c->asyncCount = count;
}

int AudioCoreTrackCount(AudioCore *c) { return c->trackCount; }
int AudioCoreRingChannels(AudioCore *c) { return c->ringChannels; }

static inline bool validTrack(int t) { return t >= 0 && t < AC_MAX_TRACKS; }

void AudioCoreSetTrackGain(AudioCore *c, int t, float v) { if (validTrack(t)) atomic_store(&c->gain[t], v); }
void AudioCoreSetTrackMute(AudioCore *c, int t, bool m) { if (validTrack(t)) atomic_store(&c->mute[t], m); }
void AudioCoreSetTrackVenueSend(AudioCore *c, int t, bool on) { if (validTrack(t)) atomic_store(&c->venueSend[t], on); }
void AudioCoreSetTrackBalance(AudioCore *c, int t, float b) {
    if (validTrack(t)) atomic_store(&c->balance[t], b < -1 ? -1 : (b > 1 ? 1 : b));
}
void AudioCoreSetStreamLevel(AudioCore *c, float v) { atomic_store(&c->streamLevel, v); }
void AudioCoreSetVenueLevel(AudioCore *c, float v) { atomic_store(&c->venueLevel, v); }

void AudioCoreReadMeters(AudioCore *c, AudioCoreMeters *out) {
    for (int i = 0; i < AC_MAX_TRACKS; i++) {
        out->peakLeft[i] = atomic_exchange(&c->peakLeft[i], 0.0f);
        out->peakRight[i] = atomic_exchange(&c->peakRight[i], 0.0f);
    }
    out->streamPeak = atomic_exchange(&c->streamPeak, 0.0f);
    out->venuePeak = atomic_exchange(&c->venuePeak, 0.0f);
    out->callbacks = atomic_load(&c->callbacks);
    out->overruns = atomic_load(&c->overruns);
}

void AudioCoreStartRecording(AudioCore *c) {
    atomic_store(&c->readPos, atomic_load(&c->writePos));
    atomic_store(&c->overruns, 0);
    atomic_store(&c->recording, true);
}

void AudioCoreStopRecording(AudioCore *c) {
    atomic_store(&c->recording, false);
}

uint32_t AudioCoreReadRecorded(AudioCore *c, float *dst, uint32_t maxFrames) {
    size_t stride = (size_t)c->ringChannels;
    uint64_t w = atomic_load_explicit(&c->writePos, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&c->readPos, memory_order_relaxed);
    uint64_t avail = w - r;
    uint32_t n = avail < maxFrames ? (uint32_t)avail : maxFrames;
    uint32_t mask = c->ringFrames - 1;
    uint32_t start = (uint32_t)(r & mask);
    uint32_t first = n < c->ringFrames - start ? n : c->ringFrames - start;
    memcpy(dst, c->ring + (size_t)start * stride, (size_t)first * stride * sizeof(float));
    memcpy(dst + (size_t)first * stride, c->ring, (size_t)(n - first) * stride * sizeof(float));
    atomic_store_explicit(&c->readPos, r + n, memory_order_release);
    return n;
}

static inline float maxf(float a, float b) { return a > b ? a : b; }

static inline void raisePeak(_Atomic float *slot, float value) {
    if (value > atomic_load_explicit(slot, memory_order_relaxed)) atomic_store_explicit(slot, value, memory_order_relaxed);
}

/// Resolves one source channel to a sample pointer and stride, or NULL if it isn't available.
static inline const float *sourceChannel(const AudioBufferList *input, int buffer, int channel, UInt32 frames, UInt32 *stride) {
    if (buffer < 0 || buffer >= (int)input->mNumberBuffers || channel < 0) return NULL;
    const AudioBuffer *b = &input->mBuffers[buffer];
    if (!b->mData || channel >= (int)b->mNumberChannels) return NULL;
    if (b->mDataByteSize / (sizeof(float) * b->mNumberChannels) < frames) return NULL;
    *stride = b->mNumberChannels;
    return (const float *)b->mData + channel;
}

/// One channel of an async source rendered this cycle, or NULL.
static inline const float *asyncChannel(AudioCore *c, int source, int channel, bool rendered) {
    if (!rendered || source < 0 || source >= c->asyncCount || !c->async[source]) return NULL;
    return AudioCoreAsyncOutput(c->async[source], channel);
}

static inline float *outputBuffer(AudioBufferList *output, int index, UInt32 frames, UInt32 *stride) {
    if (index < 0 || index >= (int)output->mNumberBuffers) return NULL;
    AudioBuffer *b = &output->mBuffers[index];
    if (!b->mData || !b->mNumberChannels || b->mDataByteSize / (sizeof(float) * b->mNumberChannels) < frames) return NULL;
    *stride = b->mNumberChannels;
    return b->mData;
}

static inline void writeStereo(float *buffer, UInt32 stride, UInt32 f, float left, float right) {
    if (stride > 1) {
        buffer[(size_t)f * stride] = left;
        buffer[(size_t)f * stride + 1] = right;
    } else {
        buffer[(size_t)f * stride] = 0.5f * (left + right);
    }
}

OSStatus AudioCoreIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *clientData) {
    (void)device, (void)now, (void)inputTime, (void)outputTime;
    AudioCore *c = clientData;
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_relaxed);

    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }

    // Every buffer in an aggregate IO cycle has the same frame count; take it from any buffer.
    UInt32 frames = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers && frames == 0; b++) {
        if (input->mBuffers[b].mNumberChannels)
            frames = input->mBuffers[b].mDataByteSize / (UInt32)(sizeof(float) * input->mBuffers[b].mNumberChannels);
    }
    for (UInt32 b = 0; b < output->mNumberBuffers && frames == 0; b++) {
        if (output->mBuffers[b].mNumberChannels)
            frames = output->mBuffers[b].mDataByteSize / (UInt32)(sizeof(float) * output->mBuffers[b].mNumberChannels);
    }
    if (frames == 0) return noErr;

    // Devices on their own clock: resample this cycle's audio once per source, before mixing.
    bool asyncRendered = frames <= AC_ASYNC_MAX_FRAMES;
    for (int i = 0; asyncRendered && i < c->asyncCount; i++) {
        if (c->async[i]) AudioCoreAsyncRender(c->async[i], frames);
    }

    int tracks = c->trackCount;
    const float *srcL[AC_MAX_TRACKS], *srcR[AC_MAX_TRACKS];
    UInt32 strideL[AC_MAX_TRACKS], strideR[AC_MAX_TRACKS];
    float tS[AC_MAX_TRACKS][2], tV[AC_MAX_TRACKS][2], dS[AC_MAX_TRACKS][2], dV[AC_MAX_TRACKS][2];
    float inv = 1.0f / (float)frames;

    for (int t = 0; t < tracks; t++) {
        const AudioCoreTrackLayout *l = &c->tracks[t];
        strideL[t] = strideR[t] = 1;
        if (l->asyncSource >= 0) {
            srcL[t] = asyncChannel(c, l->asyncSource, l->channel, asyncRendered);
            srcR[t] = l->stereo ? asyncChannel(c, l->asyncSource, l->channelRight, asyncRendered) : NULL;
        } else {
            srcL[t] = sourceChannel(input, l->buffer, l->channel, frames, &strideL[t]);
            srcR[t] = l->stereo ? sourceChannel(input, l->bufferRight, l->channelRight, frames, &strideR[t]) : NULL;
        }

        float g = atomic_load_explicit(&c->mute[t], memory_order_relaxed) ? 0.0f
                                                                          : atomic_load_explicit(&c->gain[t], memory_order_relaxed);
        float sideL = 1.0f, sideR = 1.0f;
        if (l->stereo) {
            float bal = atomic_load_explicit(&c->balance[t], memory_order_relaxed);
            sideL = bal > 0 ? 1.0f - bal : 1.0f;
            sideR = bal < 0 ? 1.0f + bal : 1.0f;
        }
        bool venue = atomic_load_explicit(&c->venueSend[t], memory_order_relaxed);
        tS[t][0] = g * sideL;
        tS[t][1] = g * sideR;
        tV[t][0] = venue ? tS[t][0] : 0.0f;
        tV[t][1] = venue ? tS[t][1] : 0.0f;
        for (int s = 0; s < 2; s++) {
            dS[t][s] = (tS[t][s] - c->curStream[t][s]) * inv;
            dV[t][s] = (tV[t][s] - c->curVenue[t][s]) * inv;
        }
    }
    float tSL = atomic_load_explicit(&c->streamLevel, memory_order_relaxed);
    float tVL = atomic_load_explicit(&c->venueLevel, memory_order_relaxed);
    float dSL = (tSL - c->curStreamLevel) * inv;
    float dVL = (tVL - c->curVenueLevel) * inv;

    UInt32 vStride = 0, sStride = 0;
    float *vb = outputBuffer(output, c->venueBuffer, frames, &vStride);
    float *sb = outputBuffer(output, c->streamBuffer, frames, &sStride);

    int ringChannels = c->ringChannels;
    bool rec = atomic_load_explicit(&c->recording, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&c->writePos, memory_order_relaxed);
    if (rec) {
        uint64_t r = atomic_load_explicit(&c->readPos, memory_order_acquire);
        if (c->ringFrames - (w - r) < frames) {
            rec = false;
            atomic_fetch_add_explicit(&c->overruns, 1, memory_order_relaxed);
        }
    }
    uint32_t mask = c->ringFrames - 1;

    float pkL[AC_MAX_TRACKS] = {0}, pkR[AC_MAX_TRACKS] = {0};
    float gS[AC_MAX_TRACKS][2], gV[AC_MAX_TRACKS][2];
    memcpy(gS, c->curStream, sizeof gS);
    memcpy(gV, c->curVenue, sizeof gV);
    float gSL = c->curStreamLevel, gVL = c->curVenueLevel;
    float sPeak = 0.0f, vPeak = 0.0f;

    for (UInt32 f = 0; f < frames; f++) {
        float streamL = 0, streamR = 0, venueL = 0, venueR = 0;
        float *slot = rec ? c->ring + (size_t)((w + f) & mask) * (size_t)ringChannels : NULL;
        int col = 0;
        for (int t = 0; t < tracks; t++) {
            float left = srcL[t] ? srcL[t][(size_t)f * strideL[t]] : 0.0f;
            float right = c->tracks[t].stereo ? (srcR[t] ? srcR[t][(size_t)f * strideR[t]] : 0.0f) : left;
            pkL[t] = maxf(pkL[t], fabsf(left));
            pkR[t] = maxf(pkR[t], fabsf(right));
            for (int s = 0; s < 2; s++) {
                gS[t][s] += dS[t][s];
                gV[t][s] += dV[t][s];
            }
            streamL += left * gS[t][0];
            streamR += right * gS[t][1];
            venueL += left * gV[t][0];
            venueR += right * gV[t][1];
            if (slot) {
                slot[col++] = left;
                if (c->tracks[t].stereo) slot[col++] = right;
            }
        }
        gSL += dSL;
        gVL += dVL;
        streamL *= gSL;
        streamR *= gSL;
        venueL *= gVL;
        venueR *= gVL;
        if (sb) writeStereo(sb, sStride, f, streamL, streamR);
        if (vb) writeStereo(vb, vStride, f, venueL, venueR);
        if (slot) {
            slot[col++] = streamL;
            slot[col] = streamR;
        }
        sPeak = maxf(sPeak, maxf(fabsf(streamL), fabsf(streamR)));
        vPeak = maxf(vPeak, maxf(fabsf(venueL), fabsf(venueR)));
    }

    memcpy(c->curStream, tS, sizeof(float) * 2 * (size_t)tracks);
    memcpy(c->curVenue, tV, sizeof(float) * 2 * (size_t)tracks);
    c->curStreamLevel = tSL;
    c->curVenueLevel = tVL;
    if (rec) atomic_store_explicit(&c->writePos, w + frames, memory_order_release);

    for (int t = 0; t < tracks; t++) {
        raisePeak(&c->peakLeft[t], pkL[t]);
        raisePeak(&c->peakRight[t], pkR[t]);
    }
    raisePeak(&c->streamPeak, sb ? sPeak : 0.0f);
    raisePeak(&c->venuePeak, vb ? vPeak : 0.0f);
    return noErr;
}
