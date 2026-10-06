#include "AudioCore.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Windowed-sinc resampler with drift correction for devices on their own clock.
//
// The device's IOProc (producer) appends interleaved frames to a ring. The mixer's IOProc
// (consumer) reads them at a fractional position that advances by sourceRate / targetRate per
// output frame, nudged by a PI controller that holds the buffered amount near its target. One
// producer, one consumer, no locks.

#define KERNEL_ZEROS 8        // sinc zero crossings on each side of the kernel
#define KERNEL_STEPS 512      // table entries per zero crossing (linearly interpolated)
#define MIN_CUTOFF 0.25       // limits the kernel length for large downsampling ratios
#define MAX_HALF_TAPS 32      // ceil(KERNEL_ZEROS / MIN_CUTOFF)
#define RING_FRAMES 32768u    // power of two; about 0.7 s at 48 kHz
#define MAX_CORRECTION 0.002  // largest ratio nudge, about 3.5 cents
#define KP 0.1                // per second of buffering error
#define KI 0.002              // per second squared
#define SMOOTHING_SECONDS 0.5 // time constant of the buffered-amount filter

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static float kernel[KERNEL_ZEROS * KERNEL_STEPS + 2];

static double besselI0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 40; k++) {
        double h = x / (2.0 * k);
        term *= h * h;
        sum += term;
    }
    return sum;
}

/// Kaiser-windowed sinc (beta 8.6, about 80 dB stopband) for t = 0 ... KERNEL_ZEROS.
static void buildKernel(void) {
    const double beta = 8.6, norm = besselI0(beta);
    for (int i = 0; i <= KERNEL_ZEROS * KERNEL_STEPS; i++) {
        double t = (double)i / KERNEL_STEPS;
        double sinc = i == 0 ? 1.0 : sin(M_PI * t) / (M_PI * t);
        double r = t / KERNEL_ZEROS;
        kernel[i] = (float)(sinc * besselI0(beta * sqrt(fmax(0.0, 1.0 - r * r))) / norm);
    }
    kernel[KERNEL_ZEROS * KERNEL_STEPS + 1] = 0;
}

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
static INIT_ONCE kernelOnce = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK buildKernelOnce(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once, (void)parameter, (void)context;
    buildKernel();
    return TRUE;
}
static void ensureKernel(void) { InitOnceExecuteOnce(&kernelOnce, buildKernelOnce, NULL, NULL); }
#else
#include <pthread.h>
static pthread_once_t kernelOnce = PTHREAD_ONCE_INIT;
static void ensureKernel(void) { pthread_once(&kernelOnce, buildKernel); }
#endif

static inline float kernelAt(double t) {
    double x = t * KERNEL_STEPS;
    if (x >= KERNEL_ZEROS * KERNEL_STEPS) return 0;
    int i = (int)x;
    float f = (float)(x - i);
    return kernel[i] + f * (kernel[i + 1] - kernel[i]);
}

struct AudioCoreAsyncSource {
    int channels;
    double sourceRate;
    double targetRate;
    double nominalStep; // source frames per output frame
    double cutoff;      // kernel cutoff relative to the source's Nyquist frequency
    int halfTaps;       // source frames used on each side of the read position
    double target;      // buffered source frames to hold, including the lookahead

    float *ring; // RING_FRAMES x channels, interleaved
    _Atomic uint64_t writePos; // frames written; producer only
    _Atomic uint64_t readPos;  // oldest frame the consumer still needs

    // Consumer state, owned by the mixer IOProc.
    bool primed;
    bool everPrimed;
    uint64_t base; // integer part of the read position
    double frac;   // fractional part
    double filtered;
    double integral;
    double correction;
    float weights[2 * MAX_HALF_TAPS];
    float out[AC_ASYNC_MAX_CHANNELS][AC_ASYNC_MAX_FRAMES];

    _Atomic double statBuffered;
    _Atomic double statCorrection;
    _Atomic uint64_t underruns;
    _Atomic uint64_t overflows;
    _Atomic bool running;
};

AudioCoreAsyncSource *AudioCoreAsyncCreate(int channels, double sourceRate, double targetRate, uint32_t latencyFrames) {
    if (!(sourceRate > 0) || !(targetRate > 0)) return NULL;
    ensureKernel();
    AudioCoreAsyncSource *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->channels = channels < 1 ? 1 : (channels > AC_ASYNC_MAX_CHANNELS ? AC_ASYNC_MAX_CHANNELS : channels);
    s->ring = calloc((size_t)RING_FRAMES * (size_t)s->channels, sizeof(float));
    if (!s->ring) {
        free(s);
        return NULL;
    }
    s->sourceRate = sourceRate;
    s->targetRate = targetRate;
    s->nominalStep = sourceRate / targetRate;
    // Upsampling keeps the source's band (minus a transition band); downsampling must also
    // remove everything above the target's Nyquist frequency.
    s->cutoff = fmax(MIN_CUTOFF, 0.92 * fmin(1.0, targetRate / sourceRate));
    s->halfTaps = (int)ceil(KERNEL_ZEROS / s->cutoff);
    double maxTarget = RING_FRAMES / 4.0;
    s->target = fmin((double)latencyFrames + s->halfTaps + 1, maxTarget);
    return s;
}

void AudioCoreAsyncDestroy(AudioCoreAsyncSource *s) {
    if (!s) return;
    free(s->ring);
    free(s);
}

int AudioCoreAsyncLookahead(AudioCoreAsyncSource *s) { return s->halfTaps; }

OSStatus AudioCoreAsyncIOProc(AudioObjectID device, const AudioTimeStamp *now,
                              const AudioBufferList *input, const AudioTimeStamp *inputTime,
                              AudioBufferList *output, const AudioTimeStamp *outputTime, void *clientData) {
    (void)device, (void)now, (void)inputTime, (void)outputTime;
    AudioCoreAsyncSource *s = clientData;
    // This IOProc never plays anything; keep any output streams of a combined device silent.
    if (output) {
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
        }
    }
    if (!s || !input) return noErr;

    UInt32 frames = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers && frames == 0; b++) {
        if (input->mBuffers[b].mNumberChannels)
            frames = input->mBuffers[b].mDataByteSize / (UInt32)(sizeof(float) * input->mBuffers[b].mNumberChannels);
    }
    if (frames == 0) return noErr;
    if (frames > RING_FRAMES / 2) frames = RING_FRAMES / 2;

    uint64_t w = atomic_load_explicit(&s->writePos, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&s->readPos, memory_order_acquire);
    if (RING_FRAMES - (w - r) < frames) {
        atomic_fetch_add_explicit(&s->overflows, 1, memory_order_relaxed);
        return noErr;
    }

    const uint32_t mask = RING_FRAMES - 1;
    const size_t stride = (size_t)s->channels;
    int dst = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers && dst < s->channels; b++) {
        const AudioBuffer *buf = &input->mBuffers[b];
        UInt32 n = buf->mNumberChannels;
        if (!n) continue;
        const float *data = buf->mData;
        bool usable = data && buf->mDataByteSize / (sizeof(float) * n) >= frames;
        for (UInt32 c = 0; c < n && dst < s->channels; c++, dst++) {
            for (UInt32 f = 0; f < frames; f++) {
                s->ring[(size_t)((w + f) & mask) * stride + (size_t)dst] = usable ? data[(size_t)f * n + c] : 0.0f;
            }
        }
    }
    for (; dst < s->channels; dst++) {
        for (UInt32 f = 0; f < frames; f++) s->ring[(size_t)((w + f) & mask) * stride + (size_t)dst] = 0.0f;
    }
    atomic_store_explicit(&s->writePos, w + frames, memory_order_release);
    return noErr;
}

static void setPosition(AudioCoreAsyncSource *s, double pos) {
    s->base = (uint64_t)pos;
    s->frac = pos - (double)s->base;
}

void AudioCoreAsyncRender(AudioCoreAsyncSource *s, uint32_t frames) {
    if (frames > AC_ASYNC_MAX_FRAMES) frames = AC_ASYNC_MAX_FRAMES;
    const int H = s->halfTaps;
    const int channels = s->channels;
    const uint32_t mask = RING_FRAMES - 1;
    uint64_t w = atomic_load_explicit(&s->writePos, memory_order_acquire);

    if (!s->primed) {
        uint64_t r = atomic_load_explicit(&s->readPos, memory_order_relaxed);
        if ((double)(w - r) >= s->target + H) {
            s->primed = true;
            setPosition(s, (double)w - s->target);
            s->filtered = s->target;
            s->integral = 0;
            s->correction = 0;
            if (!s->everPrimed) {
                // Frames dropped while waiting for the mixer to start aren't a fault.
                s->everPrimed = true;
                atomic_store_explicit(&s->overflows, 0, memory_order_relaxed);
            }
        }
    }

    uint32_t f = 0;
    if (s->primed) {
        double step = s->nominalStep * (1.0 + s->correction);
        for (; f < frames; f++) {
            uint64_t ip = s->base;
            if (ip + (uint64_t)H >= w) {
                s->primed = false;
                atomic_fetch_add_explicit(&s->underruns, 1, memory_order_relaxed);
                break;
            }
            float sum = 0;
            for (int k = -H + 1, j = 0; k <= H; k++, j++) {
                double d = fabs((double)k - s->frac) * s->cutoff;
                float wgt = kernelAt(d);
                s->weights[j] = wgt;
                sum += wgt;
            }
            float norm = sum != 0 ? 1.0f / sum : 0.0f;
            uint64_t first = ip - (uint64_t)(H - 1);
            for (int c = 0; c < channels; c++) {
                float acc = 0;
                for (int j = 0; j < 2 * H; j++) {
                    acc += s->ring[(size_t)((first + (uint64_t)j) & mask) * (size_t)channels + (size_t)c] * s->weights[j];
                }
                s->out[c][f] = acc * norm;
            }
            s->frac += step;
            double whole = floor(s->frac);
            s->base += (uint64_t)whole;
            s->frac -= whole;
        }
    }
    for (int c = 0; c < channels; c++) {
        if (f < frames) memset(&s->out[c][f], 0, sizeof(float) * (frames - f));
    }

    if (s->primed) {
        atomic_store_explicit(&s->readPos, s->base - (uint64_t)(H - 1), memory_order_release);

        double buffered = (double)w - ((double)s->base + s->frac);
        if (buffered > 2 * s->target + 0.05 * s->sourceRate) {
            // A burst after a stall: skip ahead rather than slowly speeding through it.
            setPosition(s, (double)w - s->target);
            buffered = s->target;
            s->filtered = s->target;
            s->integral = 0;
        }
        double dt = (double)frames / s->targetRate;
        double alpha = fmin(1.0, dt / SMOOTHING_SECONDS);
        s->filtered += alpha * (buffered - s->filtered);
        double error = (s->filtered - s->target) / s->sourceRate;
        double limit = MAX_CORRECTION / KI;
        s->integral = fmax(-limit, fmin(limit, s->integral + error * dt));
        s->correction = fmax(-MAX_CORRECTION, fmin(MAX_CORRECTION, KP * error + KI * s->integral));
    }
    atomic_store_explicit(&s->statBuffered, s->primed ? s->filtered : 0.0, memory_order_relaxed);
    atomic_store_explicit(&s->statCorrection, s->primed ? s->correction : 0.0, memory_order_relaxed);
    atomic_store_explicit(&s->running, s->primed, memory_order_relaxed);
}

const float *AudioCoreAsyncOutput(AudioCoreAsyncSource *s, int channel) {
    if (channel < 0 || channel >= s->channels) return NULL;
    return s->out[channel];
}

void AudioCoreAsyncReadStats(AudioCoreAsyncSource *s, AudioCoreAsyncStats *out) {
    out->bufferedFrames = atomic_load_explicit(&s->statBuffered, memory_order_relaxed);
    out->correction = atomic_load_explicit(&s->statCorrection, memory_order_relaxed);
    out->underruns = atomic_load_explicit(&s->underruns, memory_order_relaxed);
    out->overflows = atomic_load_explicit(&s->overflows, memory_order_relaxed);
    out->running = atomic_load_explicit(&s->running, memory_order_relaxed);
}
