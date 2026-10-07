#ifndef AUDIO_CORE_PLATFORM_H
#define AUDIO_CORE_PLATFORM_H

// The audio core's API uses CoreAudio's buffer types. On platforms without CoreAudio (Windows),
// these are layout-compatible stand-ins: a platform layer wraps its device buffers in them.

#include <stdint.h>

typedef int32_t OSStatus;
typedef uint32_t UInt32;
typedef uint32_t AudioObjectID;
enum { noErr = 0 };

typedef struct AudioBuffer {
    UInt32 mNumberChannels;
    UInt32 mDataByteSize;
    void *mData;
} AudioBuffer;

/// Variable length: allocate room for `mNumberBuffers` entries.
typedef struct AudioBufferList {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[1];
} AudioBufferList;

/// Opaque to the core, which only passes it through.
typedef struct AudioTimeStamp {
    double mSampleTime;
    uint64_t mHostTime;
} AudioTimeStamp;

#define CF_ASSUME_NONNULL_BEGIN
#define CF_ASSUME_NONNULL_END
#define _Nullable
#define _Nonnull

#endif
