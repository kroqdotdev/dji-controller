#include "Wasapi.h"

#include <audioclientactivationparams.h>
#include <ksmedia.h>
#include <wrl/implements.h>

#include <algorithm>
#include <cwchar>

using Microsoft::WRL::ComPtr;

namespace lavboard {

namespace {

bool isFloat(const WAVEFORMATEX *format) {
    if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return format->wBitsPerSample == 32;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        auto *extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
        return extensible->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT && format->wBitsPerSample == 32;
    }
    return false;
}

} // namespace

std::wstring hresultText(HRESULT hr) {
    wchar_t text[16];
    swprintf_s(text, L"0x%08X", static_cast<unsigned>(hr));
    return text;
}

Stream::~Stream() {
    stop();
    if (event_) CloseHandle(event_);
}

std::wstring Stream::open(const std::wstring &id, bool capture, uint32_t periodFrames) {
    id_ = id;
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) return L"Windows audio isn't available (" + hresultText(hr) + L").";
    ComPtr<IMMDevice> device;
    hr = enumerator->GetDevice(id.c_str(), &device);
    if (FAILED(hr)) return L"isn't connected";
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_);
    if (FAILED(hr)) return L"couldn't be opened (" + hresultText(hr) + L")";

    WAVEFORMATEX *format = nullptr;
    hr = client_->GetMixFormat(&format);
    if (FAILED(hr) || !format) return L"has no usable format (" + hresultText(hr) + L")";
    struct FreeFormat {
        WAVEFORMATEX *f;
        ~FreeFormat() { CoTaskMemFree(f); }
    } freeFormat{format};
    // Shared-mode mix formats are 32-bit float on every Windows the app supports.
    if (!isFloat(format)) return L"uses an unsupported audio format";
    channels_ = format->nChannels;
    rate_ = format->nSamplesPerSec;

    event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event_) return L"couldn't be opened (no event)";

    // Low-latency shared mode: the smallest period the driver offers, or the requested one.
    bool initialised = false;
    ComPtr<IAudioClient3> client3;
    if (SUCCEEDED(client_.As(&client3))) {
        UINT32 defaultPeriod = 0, fundamental = 0, minimum = 0, maximum = 0;
        if (SUCCEEDED(client3->GetSharedModeEnginePeriod(format, &defaultPeriod, &fundamental, &minimum, &maximum)) && fundamental) {
            UINT32 period = minimum;
            if (periodFrames > 0) {
                period = (periodFrames + fundamental - 1) / fundamental * fundamental;
                period = std::clamp(period, minimum, maximum);
            }
            hr = client3->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period, format, nullptr);
            if (SUCCEEDED(hr)) {
                initialised = true;
                periodFrames_ = period;
            } else {
                // Another app holds the engine at a different period; fall back to the default.
                client_.Reset();
                hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_);
                if (FAILED(hr)) return L"couldn't be opened (" + hresultText(hr) + L")";
            }
        }
    }
    if (!initialised) {
        hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, format, nullptr);
        if (hr == E_ACCESSDENIED) return L"is blocked by the Windows privacy settings";
        if (FAILED(hr)) return L"couldn't start (" + hresultText(hr) + L")";
        REFERENCE_TIME defaultPeriod = 0, minimumPeriod = 0;
        client_->GetDevicePeriod(&defaultPeriod, &minimumPeriod);
        periodFrames_ = static_cast<uint32_t>((defaultPeriod * rate_ + 5'000'000) / 10'000'000);
    }

    return finishOpen(capture);
}

std::wstring Stream::finishOpen(bool capture) {
    HRESULT hr = client_->SetEventHandle(event_);
    if (FAILED(hr)) return L"couldn't start (" + hresultText(hr) + L")";
    UINT32 buffer = 0;
    client_->GetBufferSize(&buffer);
    bufferFrames_ = buffer;
    REFERENCE_TIME latency = 0;
    if (SUCCEEDED(client_->GetStreamLatency(&latency))) {
        latencyFrames_ = static_cast<uint32_t>((latency * rate_ + 5'000'000) / 10'000'000);
    }

    hr = capture ? client_->GetService(IID_PPV_ARGS(&capture_)) : client_->GetService(IID_PPV_ARGS(&render_));
    if (FAILED(hr)) return L"couldn't start (" + hresultText(hr) + L")";

    if (render_) {
        // Start from a full buffer of silence, so the first periods don't glitch.
        BYTE *data = nullptr;
        if (SUCCEEDED(render_->GetBuffer(bufferFrames_, &data))) render_->ReleaseBuffer(bufferFrames_, AUDCLNT_BUFFERFLAGS_SILENT);
    }
    return {};
}

namespace {

/// Receives the audio client that ActivateAudioInterfaceAsync creates. Free-threaded, as the API requires.
class ActivationHandler final
    : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>, Microsoft::WRL::FtmBase,
                                          IActivateAudioInterfaceCompletionHandler> {
public:
    ActivationHandler() : done(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
    ~ActivationHandler() override {
        if (done) CloseHandle(done);
    }

    STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation *operation) override {
        ComPtr<IUnknown> unknown;
        HRESULT activated = E_FAIL;
        HRESULT hr = operation->GetActivateResult(&activated, &unknown);
        result = FAILED(hr) ? hr : activated;
        if (SUCCEEDED(result)) unknown.As(&client);
        SetEvent(done);
        return S_OK;
    }

    HANDLE done;
    HRESULT result = E_PENDING;
    ComPtr<IAudioClient> client;
};

} // namespace

std::wstring Stream::openLoopback(uint32_t processId, bool exclude, uint32_t rate) {
    id_ = L"loopback";
    AUDIOCLIENT_ACTIVATION_PARAMS params = {};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = processId;
    params.ProcessLoopbackParams.ProcessLoopbackMode =
        exclude ? PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE : PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT activation = {};
    activation.vt = VT_BLOB;
    activation.blob.cbSize = sizeof(params);
    activation.blob.pBlobData = reinterpret_cast<BYTE *>(&params);

    auto handler = Microsoft::WRL::Make<ActivationHandler>();
    ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
    HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &activation, handler.Get(), &operation);
    if (FAILED(hr)) return L"needs a newer version of Windows (" + hresultText(hr) + L")";
    if (WaitForSingleObject(handler->done, 3000) != WAIT_OBJECT_0) return L"didn't respond";
    if (FAILED(handler->result) || !handler->client) return L"couldn't be captured (" + hresultText(handler->result) + L")";
    client_ = handler->client;

    // Process loopback has no mix format of its own; it converts to whatever the client asks for.
    WAVEFORMATEXTENSIBLE format = {};
    format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    format.Format.nChannels = 2;
    format.Format.nSamplesPerSec = rate;
    format.Format.wBitsPerSample = 32;
    format.Format.nBlockAlign = 2 * 4;
    format.Format.nAvgBytesPerSec = rate * format.Format.nBlockAlign;
    format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    format.Samples.wValidBitsPerSample = 32;
    format.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    format.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    channels_ = 2;
    rate_ = rate;

    event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event_) return L"couldn't be captured (no event)";
    constexpr REFERENCE_TIME buffer = 200'000; // 20 ms
    hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                 AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                             buffer, 0, &format.Format, nullptr);
    if (FAILED(hr)) return L"couldn't be captured (" + hresultText(hr) + L")";
    // Loopback delivers about every 10 ms, whatever the outputs run at.
    periodFrames_ = rate / 100;
    return finishOpen(true);
}

HRESULT Stream::start() {
    if (!client_) return E_UNEXPECTED;
    HRESULT hr = client_->Start();
    started_ = SUCCEEDED(hr);
    return hr;
}

void Stream::stop() {
    if (client_ && started_) client_->Stop();
    started_ = false;
}

} // namespace lavboard
