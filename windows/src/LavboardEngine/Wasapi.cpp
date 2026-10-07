#include "Wasapi.h"

#include <ksmedia.h>

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

    hr = client_->SetEventHandle(event_);
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
