import AppKit
import SwiftUI

/// The strip's name on a piece of console tape. Click to rename or recolour; right-click for colours.
struct TapeLabel: View {
    @Environment(AppModel.self) private var app
    let index: Int
    @State private var editing = false

    var body: some View {
        @Bindable var app = app
        let strip = app.strips[index]
        Button { editing = true } label: {
            Text(strip.name.isEmpty ? "TX\(index + 1)" : strip.name)
                .font(.tape)
                .foregroundStyle(Console.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Console.Radius.tape).fill(strip.color.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename or recolour TX\(index + 1)")
        .accessibilityLabel("\(strip.name), TX\(index + 1)")
        .accessibilityHint("Opens the label editor")
        .contextMenu {
            Button("Rename…") { editing = true }
            Picker("Tape colour", selection: $app.strips[index].color) {
                ForEach(TapeColor.allCases) { Text($0.label).tag($0) }
            }
        }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            LabelEditor(index: index) { editing = false }
        }
    }
}

private struct LabelEditor: View {
    @Environment(AppModel.self) private var app
    let index: Int
    let done: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var app = app
        let identity = app.receiver.transmitters[index]?.identity
        VStack(alignment: .leading, spacing: 14) {
            Text("TX\(index + 1) label")
                .font(.headline)
            TextField("Name", text: $app.strips[index].name, prompt: Text("Who is wearing it"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(done)
            VStack(alignment: .leading, spacing: 8) {
                Text("Tape colour")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(TapeColor.allCases) { color in
                        let selected = app.strips[index].color == color
                        Button { app.strips[index].color = color } label: {
                            RoundedRectangle(cornerRadius: Console.Radius.tape)
                                .fill(color.fill)
                                .frame(width: 30, height: 22)
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Console.ink)
                                    }
                                }
                                .padding(2)
                                .overlay(RoundedRectangle(cornerRadius: Console.Radius.tape + 2)
                                    .strokeBorder(selected ? Console.silk : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(color.label)
                        .accessibilityLabel(color.label)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if let identity {
                Text("Serial \(identity.serial). Tap this mic and its meter will move.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear { nameFocused = true }
    }
}

struct ChannelStrip: View {
    @Environment(AppModel.self) private var app
    let index: Int
    let meter: MeterBallistics.Channel

    var body: some View {
        @Bindable var app = app
        let info = app.receiver.transmitters[index]
        let connected = info?.status != nil
        let muted = app.muted[index]
        let name = app.strips[index].name

        VStack(spacing: 12) {
            TapeLabel(index: index)

            HStack {
                Text("TX\(index + 1)")
                    .font(.stripLabel)
                    .foregroundStyle(Console.engraving)
                Spacer()
                BatteryView(status: info?.status)
            }

            ZStack {
                HStack(spacing: 6) {
                    MeterScale()
                    LEDMeter(channel: meter, dimmed: muted)
                        .frame(width: 12)
                    FaderView(value: $app.strips[index].faderDB, label: "\(name) level")
                }
                .opacity(connected ? 1 : 0.35)
                if app.receiver.connected && !connected {
                    Text("Switch on TX\(index + 1)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Console.silk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Console.Radius.key).fill(Console.well))
                }
            }
            .frame(maxHeight: .infinity)

            Text(app.strips[index].faderDB.dbLabel)
                .font(.value)
                .foregroundStyle(Console.silk)

            Button { app.toggleMute(index) } label: {
                Text(muted ? "Muted" : "Mute")
            }
            .buttonStyle(KeyStyle(lit: muted, litColor: Console.red, litText: .white, legend: "\(index + 1)"))
            .help("Mute \(name). Shortcut: \(index + 1)")

            HardwareGain(index: index)

            HStack {
                Text("Venue")
                    .font(.stripLabel)
                    .foregroundStyle(Console.engraving)
                Spacer()
                let on = app.strips[index].sendToVenue
                Button(on ? "On" : "Off") { app.strips[index].sendToVenue.toggle() }
                    .buttonStyle(KeyStyle(lit: on, litColor: Console.engraving, litText: Console.ink, compact: true))
                    .frame(width: 58)
                    .help("Send \(name) to the venue output")
                    .accessibilityLabel("Venue send")
                    .accessibilityValue(on ? "On" : "Off")
            }
        }
        .padding(12)
        .frame(minWidth: 158, maxWidth: 196)
        .background(RoundedRectangle(cornerRadius: Console.Radius.container).fill(Console.panel))
    }
}

/// The transmitter's own preamp gain (-12...+12 dB), set over USB and confirmed by the receiver.
struct HardwareGain: View {
    @Environment(AppModel.self) private var app
    let index: Int

    var body: some View {
        let status = app.receiver.transmitters[index]?.status
        let pending = app.receiver.pendingGain[index]
        let value = pending ?? status?.gainDB ?? 0
        HStack(spacing: 0) {
            Text("Mic gain")
                .font(.stripLabel)
                .foregroundStyle(Console.engraving)
            Spacer(minLength: 4)
            stepButton("minus", enabled: status != nil && value > -12) { app.receiver.setGain(slot: index, dB: value - 1) }
            Text(value == 0 ? "0 dB" : String(format: "%+d dB", value))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Console.silk.opacity(pending != nil ? 0.5 : 1))
                .frame(width: 50)
            stepButton("plus", enabled: status != nil && value < 12) { app.receiver.setGain(slot: index, dB: value + 1) }
        }
        .help("Gain on the transmitter itself. It changes the signal everywhere, including recordings and the receiver's analog output.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mic gain")
        .accessibilityValue("\(value) dB")
        .accessibilityAdjustableAction { direction in
            guard status != nil else { return }
            app.receiver.setGain(slot: index, dB: value + (direction == .increment ? 1 : -1))
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: Console.Radius.key).fill(Console.well))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Console.silk.opacity(enabled ? 1 : 0.3))
        .disabled(!enabled)
    }
}

struct BatteryView: View {
    let status: TransmitterStatus?

    var body: some View {
        if let status {
            let percent = status.batteryLevel.batteryPercent
            let low = percent <= 20 && !status.charging
            let symbol = status.charging ? "battery.100percent.bolt"
                : percent > 80 ? "battery.100percent" : percent > 55 ? "battery.75percent"
                : percent > 30 ? "battery.50percent" : percent > 10 ? "battery.25percent" : "battery.0percent"
            Image(systemName: symbol)
                .foregroundStyle(low ? Console.red : Console.engraving)
                .help(status.charging ? "Charging" : "Battery about \(percent)%")
                .accessibilityLabel(status.charging ? "Charging" : "Battery about \(percent) percent")
        }
    }
}

/// Output strip: picks its device and sets its level.
struct MasterStrip: View {
    @Environment(AppModel.self) private var app
    let title: String
    let meter: MeterBallistics.Channel
    @Binding var device: String?
    @Binding var level: Double
    var note: String?
    /// A device that must not be offered here.
    var excluding: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        let engine = app.engine
        let choices = engine.outputs.filter { $0.uid != excluding }
        let current = choices.first { $0.uid == device }
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Console.silk)
                .padding(.vertical, 6)

            Menu {
                Picker(title, selection: $device) {
                    Text("Off").tag(String?.none)
                    ForEach(choices) { output in
                        Text(output.name).tag(Optional(output.uid))
                    }
                    if let device, current == nil {
                        Text("Unavailable device").tag(Optional(device))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(current?.name ?? (device == nil ? "Off" : "Unavailable"))
                    .font(.stripLabel)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(Console.engraving)
            .help("Choose where the \(title.lowercased()) mix goes")

            HStack(spacing: 6) {
                LEDMeter(channel: meter, dimmed: current == nil)
                    .frame(width: 12)
                FaderView(value: $level, label: "\(title) level")
            }
            .frame(maxHeight: .infinity)

            Text(level.dbLabel)
                .font(.value)
                .foregroundStyle(Console.silk)

            VStack(spacing: 8) {
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Console.engraving)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(KeyStyle(lit: true, compact: true))
                }
            }
            .frame(height: 62, alignment: .top)
        }
        .padding(12)
        .frame(width: 128)
        .background(RoundedRectangle(cornerRadius: Console.Radius.container).fill(Console.panel))
    }
}
