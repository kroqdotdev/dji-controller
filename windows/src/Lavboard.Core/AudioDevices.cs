using Lavboard.Core.Interop;

namespace Lavboard.Core;

/// <summary>An active Windows audio endpoint, as seen in its shared-mode mix format.</summary>
public sealed record AudioDevice(string Id, string Name, bool IsInput, int Channels, int SampleRate, bool IsDefault,
                                 int UsbVendor = 0, int UsbProduct = 0, bool IsBluetooth = false)
{
    public bool IsUsb(int vendor, params int[] products) => UsbVendor == vendor && products.Contains(UsbProduct);
}

public static class AudioDevices
{
    /// <summary>A capture endpoint's own gain and range in dB, or null when its driver offers none.</summary>
    public static unsafe (double Db, double Min, double Max)? InputGain(string id)
    {
        float db, min, max;
        return Native.LbGetInputGain(id, &db, &min, &max) == 0 ? (db, min, max) : null;
    }

    public static void SetInputGain(string id, double db) => Native.LbSetInputGain(id, (float)db);

    /// <summary>Every active input and output endpoint.</summary>
    public static unsafe IReadOnlyList<AudioDevice> List()
    {
        int count = Native.LbListDevices(null, 0);
        if (count <= 0) return [];
        var raw = new LbDevice[count + 4]; // room for a device that appears between the two calls
        fixed (LbDevice* p = raw)
        {
            count = Math.Min(Native.LbListDevices(p, raw.Length), raw.Length);
            var devices = new List<AudioDevice>(count);
            for (int i = 0; i < count; i++)
            {
                LbDevice* d = &p[i];
                devices.Add(new AudioDevice(new string(d->Id), new string(d->Name), d->IsInput != 0, d->Channels, d->SampleRate, d->IsDefault != 0,
                                            d->UsbVendor, d->UsbProduct, d->IsBluetooth != 0));
            }
            return devices;
        }
    }
}
