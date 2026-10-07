#include "Engine.h"
#include "Wasapi.h"

#include <devicetopology.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>

#include <atomic>
#include <cwchar>
#include <cwctype>
#include <mutex>
#include <string>

using Microsoft::WRL::ComPtr;
using namespace lavboard;

namespace {

void copyString(wchar_t *dest, size_t capacity, const wchar_t *source) {
    wcsncpy_s(dest, capacity, source ? source : L"", _TRUNCATE);
}

std::wstring defaultEndpointId(IMMDeviceEnumerator *enumerator, EDataFlow flow) {
    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(flow, eConsole, &device))) return {};
    LPWSTR id = nullptr;
    if (FAILED(device->GetId(&id))) return {};
    std::wstring result(id);
    CoTaskMemFree(id);
    return result;
}

/// The kernel streaming path of the adapter behind an endpoint, lowercased, e.g.
/// "{2}.\\?\usb#vid_2ca3&pid_4011&mi_00#...". USB and Bluetooth devices name themselves there.
std::wstring adapterPath(IMMDevice *device) {
    ComPtr<IDeviceTopology> topology;
    if (FAILED(device->Activate(__uuidof(IDeviceTopology), CLSCTX_ALL, nullptr, &topology))) return {};
    ComPtr<IConnector> connector;
    if (FAILED(topology->GetConnector(0, &connector))) return {};
    LPWSTR id = nullptr;
    if (FAILED(connector->GetDeviceIdConnectedTo(&id))) return {};
    std::wstring path(id);
    CoTaskMemFree(id);
    for (auto &c : path) c = static_cast<wchar_t>(std::towlower(c));
    return path;
}

int32_t hexAfter(const std::wstring &path, const wchar_t *key) {
    size_t at = path.find(key);
    if (at == std::wstring::npos) return 0;
    return static_cast<int32_t>(wcstol(path.c_str() + at + wcslen(key), nullptr, 16));
}

/// PKEY_AudioEngine_DeviceFormat, which no import library defines.
constexpr PROPERTYKEY kDeviceFormatKey = {{0xf19f064d, 0x082c, 0x4e27, {0xbc, 0x73, 0x68, 0x82, 0xa1, 0xbb, 0x8e, 0x4c}}, 0};

/// Forwards endpoint changes to the app's callback.
class DeviceWatcher final : public IMMNotificationClient {
public:
    void set(LbDeviceCallback callback, void *context) {
        std::lock_guard lock(mutex_);
        callback_ = callback;
        context_ = context;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override { return --refs_; } // a static instance
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) {
            *out = static_cast<IMMNotificationClient *>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return notify(); }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return notify(); }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return notify(); }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow, ERole role, LPCWSTR) override {
        return role == eConsole ? notify() : S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY key) override {
        // A new shared-mode format (rate or channels) changes how the engine must open the device.
        return key.fmtid == kDeviceFormatKey.fmtid && key.pid == kDeviceFormatKey.pid ? notify() : S_OK;
    }

    HRESULT notify() {
        std::lock_guard lock(mutex_);
        if (callback_) callback_(context_);
        return S_OK;
    }

private:
    std::mutex mutex_;
    LbDeviceCallback callback_ = nullptr;
    void *context_ = nullptr;
    std::atomic<ULONG> refs_{1};
};

DeviceWatcher watcher;
ComPtr<IMMDeviceEnumerator> watchedEnumerator;
std::mutex watchMutex;

} // namespace

/// The engine calls this when a running stream fails, e.g. its device was unplugged.
void lbNotifyDeviceChange() { watcher.notify(); }

extern "C" int32_t LbEngineVersion(void) { return 2; }

extern "C" int32_t LbListDevices(LbDevice *devices, int32_t capacity) {
    ComScope com;
    if (!com.ok()) return -1;

    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return -2;

    int32_t count = 0;
    for (EDataFlow flow : {eCapture, eRender}) {
        const std::wstring defaultId = defaultEndpointId(enumerator.Get(), flow);
        ComPtr<IMMDeviceCollection> collection;
        if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &collection))) continue;
        UINT n = 0;
        collection->GetCount(&n);
        for (UINT i = 0; i < n; i++, count++) {
            if (count >= capacity || !devices) continue; // keep counting so the caller can size its buffer
            LbDevice &out = devices[count];
            out = {};
            out.isInput = flow == eCapture;

            ComPtr<IMMDevice> device;
            if (FAILED(collection->Item(i, &device))) continue;
            LPWSTR id = nullptr;
            if (SUCCEEDED(device->GetId(&id))) {
                copyString(out.id, LB_ID_LENGTH, id);
                out.isDefault = defaultId == id;
                CoTaskMemFree(id);
            }

            ComPtr<IPropertyStore> properties;
            if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &properties))) {
                PROPVARIANT name;
                PropVariantInit(&name);
                if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &name)) && name.vt == VT_LPWSTR) {
                    copyString(out.name, LB_NAME_LENGTH, name.pwszVal);
                }
                PropVariantClear(&name);
            }

            ComPtr<IAudioClient> client;
            if (SUCCEEDED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client))) {
                WAVEFORMATEX *format = nullptr;
                if (SUCCEEDED(client->GetMixFormat(&format)) && format) {
                    out.channels = format->nChannels;
                    out.sampleRate = static_cast<int32_t>(format->nSamplesPerSec);
                    CoTaskMemFree(format);
                }
            }

            const std::wstring path = adapterPath(device.Get());
            if (path.find(L"usb#vid_") != std::wstring::npos) {
                out.usbVendor = hexAfter(path, L"vid_");
                out.usbProduct = hexAfter(path, L"pid_");
            }
            out.isBluetooth = path.find(L"bth") != std::wstring::npos;
        }
    }
    return count;
}

namespace {

ComPtr<IAudioEndpointVolume> endpointVolume(const wchar_t *id) {
    ComPtr<IMMDeviceEnumerator> enumerator;
    if (!id || FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return nullptr;
    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDevice(id, &device))) return nullptr;
    ComPtr<IAudioEndpointVolume> volume;
    if (FAILED(device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, &volume))) return nullptr;
    return volume;
}

} // namespace

extern "C" int32_t LbGetInputGain(const wchar_t *id, float *db, float *minimumDb, float *maximumDb) {
    ComScope com;
    auto volume = endpointVolume(id);
    if (!volume || !db || !minimumDb || !maximumDb) return -1;
    float increment = 0;
    if (FAILED(volume->GetVolumeRange(minimumDb, maximumDb, &increment)) || *maximumDb <= *minimumDb) return -2;
    return SUCCEEDED(volume->GetMasterVolumeLevel(db)) ? 0 : -3;
}

extern "C" int32_t LbSetInputGain(const wchar_t *id, float db) {
    ComScope com;
    auto volume = endpointVolume(id);
    if (!volume) return -1;
    return SUCCEEDED(volume->SetMasterVolumeLevel(db, nullptr)) ? 0 : -2;
}

extern "C" int32_t LbWatchDevices(LbDeviceCallback callback, void *context) {
    std::lock_guard lock(watchMutex);
    watcher.set(callback, context);
    if (callback && !watchedEnumerator) {
        // The enumerator lives on as long as the watch; the process's COM stays initialised for it.
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&watchedEnumerator)))) return -2;
        if (FAILED(watchedEnumerator->RegisterEndpointNotificationCallback(&watcher))) {
            watchedEnumerator.Reset();
            return -3;
        }
    } else if (!callback && watchedEnumerator) {
        watchedEnumerator->UnregisterEndpointNotificationCallback(&watcher);
        watchedEnumerator.Reset();
    }
    return 0;
}
