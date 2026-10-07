#pragma once

// The Windows engine's C API, on top of the shared core in Shared/AudioCore. Everything here is
// callable from C# through P/Invoke (see Lavboard.Core/Native.cs).
//
// Windows has no aggregate devices, so the engine does what a macOS aggregate does by hand: one
// endpoint clocks the mixer and every other device runs through the shared async resampler. An
// input on its own clock feeds an async source that the mixer reads; an output on its own clock
// reads an async source that the mixer feeds.

#include <stdint.h>

#include "AudioCore.h"

#ifdef __cplusplus
extern "C" {
#endif

#define LB_ID_LENGTH 256
#define LB_NAME_LENGTH 256
#define LB_MAX_INPUTS AC_MAX_TRACKS
#define LB_PROBLEM_LENGTH 128

/// One active audio endpoint.
typedef struct {
    wchar_t id[LB_ID_LENGTH];     // IMMDevice id, stable across reboots
    wchar_t name[LB_NAME_LENGTH]; // friendly name, e.g. "Microphone (Wireless Mic Rx)"
    int32_t isInput;              // 1 for capture endpoints, 0 for render endpoints
    int32_t channels;             // channels in the shared-mode mix format
    int32_t sampleRate;           // shared-mode mix format rate
    int32_t isDefault;            // the default endpoint for its direction (console role)
    int32_t usbVendor;            // USB vendor and product IDs, or 0 when the device isn't USB
    int32_t usbProduct;
    int32_t isBluetooth;
} LbDevice;

/// Bumped whenever this API changes, so the app can refuse a mismatched DLL.
int32_t LbEngineVersion(void);

/// Fills up to `capacity` active endpoints of both directions and returns how many exist (which
/// can exceed `capacity`). Returns a negative HRESULT-derived code if enumeration fails.
int32_t LbListDevices(LbDevice *devices, int32_t capacity);

/// The endpoint's own volume, in dB, for capture devices whose driver offers one (most USB mics).
/// Returns 0 and fills the range on success; nonzero when the endpoint has no volume control.
int32_t LbGetInputGain(const wchar_t *id, float *db, float *minimumDb, float *maximumDb);
int32_t LbSetInputGain(const wchar_t *id, float db);

/// An app's audio session on an output: the process that opened it, and whether it is playing.
typedef struct {
    uint32_t processId;
    int32_t active;
} LbAudioSession;

/// Fills up to `capacity` audio sessions across every active output (system sounds left out) and
/// returns how many exist. One process can have several.
int32_t LbListAudioSessions(LbAudioSession *sessions, int32_t capacity);

/// Calls `callback` (on a system thread) whenever endpoints appear, disappear, change state or
/// format, or the default endpoint changes. Pass NULL to stop. One callback per process.
typedef void (*LbDeviceCallback)(void *context);
int32_t LbWatchDevices(LbDeviceCallback callback, void *context);

// MARK: Engine

typedef struct LbEngine LbEngine;

/// Where a track reads from: channel `channel` (and `channel + 1` when stereo) of source `input`,
/// counting the config's inputs first and then its loopbacks. An input of -1 means the source is
/// missing and the track stays silent.
typedef struct {
    int32_t input;
    int32_t channel;
    int32_t stereo;
} LbTrackSpec;

/// What an app plays (`processId` and its child processes), or with `exclude` everything except
/// that process tree: process loopback capture, stereo at the mixer's rate.
typedef struct {
    uint32_t processId;
    int32_t exclude;
} LbLoopbackSpec;

typedef struct {
    /// Capture endpoints the tracks read from. With `clockFromInput`, inputs[0] clocks the mixer
    /// and its channels reach the mixer directly; every other input is resampled.
    int32_t inputCount;
    const wchar_t *inputIds[LB_MAX_INPUTS];
    int32_t clockFromInput;
    /// App and system audio, resampled like inputs on their own clock. Inputs and loopbacks
    /// together are at most LB_MAX_INPUTS.
    int32_t loopbackCount;
    LbLoopbackSpec loopbacks[LB_MAX_INPUTS];
    /// Render endpoint that clocks the mixer when no input does: the stream or venue output, or
    /// any other output, which then plays silence.
    const wchar_t *clockOutputId;
    /// Render endpoints for the two mixes, or NULL for off.
    const wchar_t *venueId;
    const wchar_t *streamId;
    int32_t trackCount;
    LbTrackSpec tracks[AC_MAX_TRACKS];
    /// Requested mixer period in frames; 0 for the clock endpoint's smallest.
    uint32_t periodFrames;
} LbEngineConfig;

typedef struct {
    int32_t sampleRate;   // the mixer's rate: the clock endpoint's
    int32_t periodFrames; // the clock endpoint's period
    /// Mic to venue output, in ms; negative when the venue is off or didn't start.
    double venueLatencyMs;
    /// Per track: how far a resampled track runs behind the clock's own inputs, in ms; negative
    /// for tracks on the clock input and for silent tracks.
    double trackLatencyMs[AC_MAX_TRACKS];
    /// Per source (inputs, then loopbacks): 1 if it started.
    int32_t inputRunning[LB_MAX_INPUTS];
    /// Per source and for each output: empty if it started, otherwise why not, worded to follow
    /// the device's name ("isn't connected", "is blocked by the Windows privacy settings").
    wchar_t inputErrors[LB_MAX_INPUTS][LB_PROBLEM_LENGTH];
    wchar_t venueError[LB_PROBLEM_LENGTH];
    wchar_t streamError[LB_PROBLEM_LENGTH];
} LbEngineInfo;

/// An engine that mixes with `core`, which must outlive it.
LbEngine *LbEngineCreate(AudioCore *core);
/// Stops whatever runs, then opens and starts `config`. Returns 0 on success; otherwise a
/// negative code, with the reason in `error` worded to follow the clock device's name. `info` is
/// filled either way.
int32_t LbEngineStart(LbEngine *engine, const LbEngineConfig *config, LbEngineInfo *info, wchar_t *error, int32_t errorCapacity);
/// Stops every stream and leaves the core's layout silent.
void LbEngineStop(LbEngine *engine);
void LbEngineDestroy(LbEngine *engine);
/// 1 while running; 0 once stopped or after a device failed (unplugged, format changed). The
/// device callback fires in the second case, and the app rebuilds.
int32_t LbEngineIsRunning(LbEngine *engine);
/// Stats of input `input`'s resampler (zeros for the clock input or an input that isn't running).
void LbEngineReadInputStats(LbEngine *engine, int32_t input, AudioCoreAsyncStats *out);
/// Stats of an output's resampler: 0 for the venue, 1 for the stream (zeros when it's the clock or off).
void LbEngineReadOutputStats(LbEngine *engine, int32_t output, AudioCoreAsyncStats *out);

#ifdef __cplusplus
}
#endif
