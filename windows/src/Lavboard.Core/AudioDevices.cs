using Lavboard.Core.Interop;

namespace Lavboard.Core;

/// <summary>An active Windows audio endpoint, as seen in its shared-mode mix format.</summary>
public sealed record AudioDevice(string Id, string Name, bool IsInput, int Channels, int SampleRate, bool IsDefault);

public static class AudioDevices
{
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
                devices.Add(new AudioDevice(new string(d->Id), new string(d->Name), d->IsInput != 0, d->Channels, d->SampleRate, d->IsDefault != 0));
            }
            return devices;
        }
    }
}
