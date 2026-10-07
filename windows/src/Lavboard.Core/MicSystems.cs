using System.ComponentModel;
using Lavboard.Core;

namespace Lavboard.Model;

// The Windows side of the mic-system contract in Packages/MicSystemKit: a module recognises its
// receiver, maps transmitters to channels and reports optional capabilities; the UI draws only what
// a module reports.

public sealed record TransmitterState(bool Connected = false, double? Battery = null, bool Charging = false,
                                      double? GainDb = null, double? PendingGainDb = null, bool Recording = false, string? Serial = null);

public sealed record GainCapability(double Min, double Max, double Step);

public sealed record ReceiverMode(string Id, string Name);

/// <summary>One choice of a choice setting.</summary>
public sealed record MicSettingOption(string Id, string Name);

/// <summary>
/// A receiver setting the module declares; the app draws a switch for toggles (null
/// <see cref="Choices"/>) and a segmented control for choices. A null value means not known yet,
/// which shows the control disabled.
/// </summary>
public sealed record MicSetting(string Id, string Title, IReadOnlyList<MicSettingOption>? Choices = null, bool? On = null, string? Choice = null)
{
    public bool IsToggle => Choices == null;
    public bool IsKnown => IsToggle ? On != null : Choice != null;
}

public sealed record MicNotice(string Message, string? ActionTitle = null, string? ModeId = null);

public interface IMicSystem : INotifyPropertyChanged
{
    /// <summary>Stable identifier saved with every track that uses the system.</summary>
    string Id { get; }
    string Name { get; }
    int TransmitterCount { get; }
    /// <summary>Whether an input endpoint is this system's receiver (usually by its USB IDs).</summary>
    bool IsReceiver(AudioDevice device);
    bool IsConnected { get; }
    IReadOnlyList<TransmitterState> Transmitters { get; }
    /// <summary>The receiver's input channel carrying a transmitter slot, or null when it has none in this mode.</summary>
    int? AudioChannel(int slot);

    GainCapability? Gain { get; }
    void SetGain(double db, int slot);

    bool CanRecordOnTransmitters { get; }
    void SetTransmitterRecording(bool on);

    IReadOnlyList<ReceiverMode> Modes { get; }
    string? CurrentModeId { get; }
    bool IsSwitchingMode { get; }
    void SetMode(string id);
    string? ModeSwitchWarning(string id);

    MicNotice? Notice { get; }

    IReadOnlyList<MicSetting> Settings { get; }
    /// <summary>A line under the settings, such as what they change.</summary>
    string? SettingsNote { get; }
    void SetToggle(string settingId, bool on);
    void SetChoice(string settingId, string choiceId);
}
