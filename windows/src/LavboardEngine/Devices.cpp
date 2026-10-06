#include "Engine.h"

#include <windows.h>
#include <mmdeviceapi.h> // before the property keys: it brings in DEFINE_PROPERTYKEY
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <wrl/client.h>

#include <cwchar>
#include <string>

using Microsoft::WRL::ComPtr;

namespace {

/// Initialises COM for the calling thread if it isn't already, and undoes only what it did.
class ComScope {
public:
    ComScope() : hr_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ComScope() {
        if (SUCCEEDED(hr_)) CoUninitialize();
    }
    /// RPC_E_CHANGED_MODE means the thread already runs COM in another apartment, which is fine.
    bool ok() const { return SUCCEEDED(hr_) || hr_ == RPC_E_CHANGED_MODE; }

private:
    HRESULT hr_;
};

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

} // namespace

extern "C" int32_t LbEngineVersion(void) { return 1; }

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
        }
    }
    return count;
}
