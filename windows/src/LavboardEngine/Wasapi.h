#pragma once

// WASAPI plumbing shared by the device list and the engine: COM scoping and one shared-mode,
// event-driven stream per endpoint.

#include <windows.h>
#include <mmdeviceapi.h> // before the property keys: it brings in DEFINE_PROPERTYKEY
#include <audioclient.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>

namespace lavboard {

/// Initialises COM for the calling thread if it isn't already, and undoes only what it did.
class ComScope {
public:
    ComScope() : hr_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ComScope() {
        if (SUCCEEDED(hr_)) CoUninitialize();
    }
    ComScope(const ComScope &) = delete;
    ComScope &operator=(const ComScope &) = delete;
    /// RPC_E_CHANGED_MODE means the thread already runs COM in another apartment, which is fine.
    bool ok() const { return SUCCEEDED(hr_) || hr_ == RPC_E_CHANGED_MODE; }

private:
    HRESULT hr_;
};

/// A shared-mode stream on one endpoint, opened in the endpoint's own mix format (32-bit float,
/// interleaved), signalling `event` each period.
class Stream {
public:
    Stream() = default;
    ~Stream();
    Stream(const Stream &) = delete;
    Stream &operator=(const Stream &) = delete;

    /// Opens the endpoint without starting it. `periodFrames` 0 asks for the smallest period the
    /// endpoint offers (IAudioClient3), otherwise the nearest it supports; endpoints without
    /// low-latency support use their default period. Returns a message on failure.
    std::wstring open(const std::wstring &id, bool capture, uint32_t periodFrames);
    /// Opens process loopback capture of `processId`'s tree (or everything but it, with
    /// `exclude`) as 32-bit float stereo at `rate`. Needs Windows 10 build 20348 or later.
    std::wstring openLoopback(uint32_t processId, bool exclude, uint32_t rate);
    HRESULT start();
    void stop();

    bool isCapture() const { return capture_ != nullptr; }
    uint32_t channels() const { return channels_; }
    uint32_t rate() const { return rate_; }
    /// Frames per event: the period the stream was opened with.
    uint32_t periodFrames() const { return periodFrames_; }
    /// The endpoint buffer, in frames.
    uint32_t bufferFrames() const { return bufferFrames_; }
    /// The engine's own latency for the stream (GetStreamLatency), in frames.
    uint32_t latencyFrames() const { return latencyFrames_; }
    HANDLE event() const { return event_; }
    const std::wstring &id() const { return id_; }

    IAudioCaptureClient *captureClient() const { return capture_.Get(); }
    IAudioRenderClient *renderClient() const { return render_.Get(); }
    IAudioClient *client() const { return client_.Get(); }

private:
    /// Event, buffer, latency and service setup shared by both kinds of stream.
    std::wstring finishOpen(bool capture);

    std::wstring id_;
    Microsoft::WRL::ComPtr<IAudioClient> client_;
    Microsoft::WRL::ComPtr<IAudioCaptureClient> capture_;
    Microsoft::WRL::ComPtr<IAudioRenderClient> render_;
    HANDLE event_ = nullptr;
    uint32_t channels_ = 0;
    uint32_t rate_ = 0;
    uint32_t periodFrames_ = 0;
    uint32_t bufferFrames_ = 0;
    uint32_t latencyFrames_ = 0;
    bool started_ = false;
};

/// "0x88890004" style text for an HRESULT the user can't act on but support can.
std::wstring hresultText(HRESULT hr);

} // namespace lavboard
