using Lavboard.Core;
using Lavboard.Model;

namespace Lavboard.MicSystems;

/// <summary>
/// The DJI Mic Mini 2S receiver, audio only for now: recognised by its USB IDs, with TX1 to TX4 on
/// channels 1 to 4 in 4-track mode. The control channel (gain, battery, modes) needs the
/// receiver's vendor interface over WinUSB, which comes later; until then the module offers no
/// controls, like the macOS module without a control link.
/// </summary>
public sealed class DjiMicMini2S : ObservableObject, IMicSystem
{
    /// <summary>Saved with every track that uses the system; the same ID as on the Mac.</summary>
    public const string SystemId = Track.LegacySystemId;
    private const int VendorId = 0x2CA3;
    /// <summary>0x4015 in mono and stereo mode, 0x4115 in 4-track mode.</summary>
    private static readonly int[] ProductIds = [0x4015, 0x4115];

    private static readonly TransmitterState[] Unknown = [new(), new(), new(), new()];

    public string Id => SystemId;
    public string Name => "DJI Mic Mini 2S";
    public int TransmitterCount => 4;
    public bool IsReceiver(AudioDevice device) => device.IsUsb(VendorId, ProductIds);

    /// <summary>No control link yet, so the app doesn't claim to know which mics are on.</summary>
    public bool IsConnected => false;
    public IReadOnlyList<TransmitterState> Transmitters => Unknown;
    public int? AudioChannel(int slot) => slot is >= 0 and < 4 ? slot : null;

    public GainCapability? Gain => null;
    public void SetGain(double db, int slot) { }
    public bool CanRecordOnTransmitters => false;
    public void SetTransmitterRecording(bool on) { }
    public IReadOnlyList<ReceiverMode> Modes => [];
    public string? CurrentModeId => null;
    public bool IsSwitchingMode => false;
    public void SetMode(string id) { }
    public string? ModeSwitchWarning(string id) => null;
    public MicNotice? Notice => null;
    public IReadOnlyList<MicSetting> Settings => [];
    public string? SettingsNote => null;
    public void SetToggle(string settingId, bool on) { }
    public void SetChoice(string settingId, string choiceId) { }
}
