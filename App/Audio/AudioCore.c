#include "AudioCore.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AudioCore {
    _Atomic float gain[AC_MAX_INPUTS];
    _Atomic bool mute[AC_MAX_INPUTS];
    _Atomic bool venueSend[AC_MAX_INPUTS];
    _Atomic float streamLevel;
    _Atomic float venueLevel;

    _Atomic float peak[AC_MAX_INPUTS];
    _Atomic float rms[AC_MAX_INPUTS];
    _Atomic float streamPeak;
    _Atomic float venuePeak;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t overruns;

    int inputBuffer;
    int inputChannels;
    int venueBuffer;
    int streamBuffer;

    // Smoothed gains, owned by the IOProc.
    float curStream[AC_MAX_INPUTS];
    float curVenue[AC_MAX_INPUTS];
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
    c->ring = calloc((size_t)ringFrames * AC_RING_CHANNELS, sizeof(float));
    for (int i = 0; i < AC_MAX_INPUTS; i++) {
        atomic_init(&c->gain[i], 1.0f);
        atomic_init(&c->venueSend[i], true);
    }
    atomic_init(&c->streamLevel, 1.0f);
    atomic_init(&c->venueLevel, 1.0f);
    c->inputBuffer = -1;
    c->venueBuffer = -1;
    c->streamBuffer = -1;
    return c;
}

void AudioCoreDestroy(AudioCore *c) {
    if (!c) return;
    free(c->ring);
    free(c);
}

void AudioCoreSetLayout(AudioCore *c, int inputBuffer, int inputChannels, int venueBuffer, int streamBuffer) {
    c->inputBuffer = inputBuffer;
    c->inputChannels = inputChannels < AC_MAX_INPUTS ? inputChannels : AC_MAX_INPUTS;
    c->venueBuffer = venueBuffer;
    c->streamBuffer = streamBuffer;
}

void AudioCoreSetChannelGain(AudioCore *c, int ch, float v) { if (ch >= 0 && ch < AC_MAX_INPUTS) atomic_store(&c->gain[ch], v); }
void AudioCoreSetChannelMute(AudioCore *c, int ch, bool m) { if (ch >= 0 && ch < AC_MAX_INPUTS) atomic_store(&c->mute[ch], m); }
void AudioCoreSetChannelVenueSend(AudioCore *c, int ch, bool on) { if (ch >= 0 && ch < AC_MAX_INPUTS) atomic_store(&c->venueSend[ch], on); }
void AudioCoreSetStreamLevel(AudioCore *c, float v) { atomic_store(&c->streamLevel, v); }
void AudioCoreSetVenueLevel(AudioCore *c, float v) { atomic_store(&c->venueLevel, v); }

void AudioCoreReadMeters(AudioCore *c, AudioCoreMeters *out) {
    for (int i = 0; i < AC_MAX_INPUTS; i++) {
        out->peak[i] = atomic_exchange(&c->peak[i], 0.0f);
        out->rms[i] = atomic_load(&c->rms[i]);
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
    uint64_t w = atomic_load_explicit(&c->writePos, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&c->readPos, memory_order_relaxed);
    uint64_t avail = w - r;
    uint32_t n = avail < maxFrames ? (uint32_t)avail : maxFrames;
    uint32_t mask = c->ringFrames - 1;
    uint32_t start = (uint32_t)(r & mask);
    uint32_t first = n < c->ringFrames - start ? n : c->ringFrames - start;
    memcpy(dst, c->ring + (size_t)start * AC_RING_CHANNELS, (size_t)first * AC_RING_CHANNELS * sizeof(float));
    memcpy(dst + (size_t)first * AC_RING_CHANNELS, c->ring, (size_t)(n - first) * AC_RING_CHANNELS * sizeof(float));
    atomic_store_explicit(&c->readPos, r + n, memory_order_release);
    return n;
}

static inline float maxf(float a, float b) { return a > b ? a : b; }

static inline void raisePeak(_Atomic float *slot, float value) {
    if (value > atomic_load_explicit(slot, memory_order_relaxed)) atomic_store_explicit(slot, value, memory_order_relaxed);
}

OSStatus AudioCoreIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *clientData) {
    AudioCore *c = clientData;
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_relaxed);

    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    if (c->inputBuffer < 0 || c->inputBuffer >= (int)input->mNumberBuffers) return noErr;

    const AudioBuffer *ib = &input->mBuffers[c->inputBuffer];
    const float *in = ib->mData;
    UInt32 inStride = ib->mNumberChannels;
    if (!in || inStride == 0) return noErr;
    UInt32 frames = ib->mDataByteSize / (UInt32)(sizeof(float) * inStride);
    int nch = c->inputChannels < (int)inStride ? c->inputChannels : (int)inStride;

    float *vb = NULL, *sb = NULL;
    UInt32 vStride = 0, sStride = 0;
    if (c->venueBuffer >= 0 && c->venueBuffer < (int)output->mNumberBuffers) {
        AudioBuffer *b = &output->mBuffers[c->venueBuffer];
        vStride = b->mNumberChannels;
        if (b->mData && vStride && b->mDataByteSize / (sizeof(float) * vStride) >= frames) vb = b->mData;
    }
    if (c->streamBuffer >= 0 && c->streamBuffer < (int)output->mNumberBuffers) {
        AudioBuffer *b = &output->mBuffers[c->streamBuffer];
        sStride = b->mNumberChannels;
        if (b->mData && sStride && b->mDataByteSize / (sizeof(float) * sStride) >= frames) sb = b->mData;
    }

    // Targets for this buffer; gains ramp linearly from the previous buffer's values.
    float tS[AC_MAX_INPUTS], tV[AC_MAX_INPUTS], dS[AC_MAX_INPUTS], dV[AC_MAX_INPUTS];
    float inv = frames ? 1.0f / (float)frames : 0.0f;
    for (int ch = 0; ch < AC_MAX_INPUTS; ch++) {
        float g = atomic_load_explicit(&c->mute[ch], memory_order_relaxed) ? 0.0f
                                                                           : atomic_load_explicit(&c->gain[ch], memory_order_relaxed);
        tS[ch] = g;
        tV[ch] = atomic_load_explicit(&c->venueSend[ch], memory_order_relaxed) ? g : 0.0f;
        dS[ch] = (tS[ch] - c->curStream[ch]) * inv;
        dV[ch] = (tV[ch] - c->curVenue[ch]) * inv;
    }
    float tSL = atomic_load_explicit(&c->streamLevel, memory_order_relaxed);
    float tVL = atomic_load_explicit(&c->venueLevel, memory_order_relaxed);
    float dSL = (tSL - c->curStreamLevel) * inv;
    float dVL = (tVL - c->curVenueLevel) * inv;

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

    float pk[AC_MAX_INPUTS] = {0}, ss[AC_MAX_INPUTS] = {0};
    float sPeak = 0.0f, vPeak = 0.0f;
    float gS[AC_MAX_INPUTS], gV[AC_MAX_INPUTS];
    memcpy(gS, c->curStream, sizeof gS);
    memcpy(gV, c->curVenue, sizeof gV);
    float gSL = c->curStreamLevel, gVL = c->curVenueLevel;

    for (UInt32 f = 0; f < frames; f++) {
        const float *frame = in + (size_t)f * inStride;
        float mixS = 0.0f, mixV = 0.0f;
        float *slot = rec ? c->ring + (size_t)((w + f) & mask) * AC_RING_CHANNELS : NULL;
        for (int ch = 0; ch < AC_MAX_INPUTS; ch++) {
            float x = ch < nch ? frame[ch] : 0.0f;
            pk[ch] = maxf(pk[ch], fabsf(x));
            ss[ch] += x * x;
            gS[ch] += dS[ch];
            gV[ch] += dV[ch];
            mixS += x * gS[ch];
            mixV += x * gV[ch];
            if (slot) slot[ch] = x;
        }
        gSL += dSL;
        gVL += dVL;
        float outS = mixS * gSL;
        float outV = mixV * gVL;
        if (sb) {
            sb[(size_t)f * sStride] = outS;
            if (sStride > 1) sb[(size_t)f * sStride + 1] = outS;
        }
        if (vb) {
            vb[(size_t)f * vStride] = outV;
            if (vStride > 1) vb[(size_t)f * vStride + 1] = outV;
        }
        if (slot) {
            slot[4] = outS;
            slot[5] = outS;
        }
        sPeak = maxf(sPeak, fabsf(outS));
        vPeak = maxf(vPeak, fabsf(outV));
    }

    memcpy(c->curStream, tS, sizeof tS);
    memcpy(c->curVenue, tV, sizeof tV);
    c->curStreamLevel = tSL;
    c->curVenueLevel = tVL;
    if (rec) atomic_store_explicit(&c->writePos, w + frames, memory_order_release);

    for (int ch = 0; ch < AC_MAX_INPUTS; ch++) {
        raisePeak(&c->peak[ch], pk[ch]);
        atomic_store_explicit(&c->rms[ch], frames ? sqrtf(ss[ch] * inv) : 0.0f, memory_order_relaxed);
    }
    raisePeak(&c->streamPeak, sb ? sPeak : 0.0f);
    raisePeak(&c->venuePeak, vb ? vPeak : 0.0f);
    return noErr;
}
