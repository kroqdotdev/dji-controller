#pragma once

// The Windows engine's C API, on top of the shared core in Shared/AudioCore. Everything here is
// callable from C# through P/Invoke (see Lavboard.Core/Native.cs).

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LB_ID_LENGTH 256
#define LB_NAME_LENGTH 256

/// One active audio endpoint.
typedef struct {
    wchar_t id[LB_ID_LENGTH];     // IMMDevice id, stable across reboots
    wchar_t name[LB_NAME_LENGTH]; // friendly name, e.g. "Microphone (Wireless Mic Rx)"
    int32_t isInput;              // 1 for capture endpoints, 0 for render endpoints
    int32_t channels;             // channels in the shared-mode mix format
    int32_t sampleRate;           // shared-mode mix format rate
    int32_t isDefault;            // the default endpoint for its direction (console role)
} LbDevice;

/// Bumped whenever this API changes, so the app can refuse a mismatched DLL.
int32_t LbEngineVersion(void);

/// Fills up to `capacity` active endpoints of both directions and returns how many exist (which
/// can exceed `capacity`). Returns a negative HRESULT-derived code if enumeration fails.
int32_t LbListDevices(LbDevice *devices, int32_t capacity);

#ifdef __cplusplus
}
#endif
