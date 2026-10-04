import AppKit
import MicSystemKit
import SwiftUI

// MARK: Tape label and editor

/// The track's name on a piece of console tape. Click to rename, recolour, change the source
/// or remove the track. The strip owns `editing` so its right-click menu can open the editor too.
struct TapeLabel: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    @Binding var editing: Bool

    var body: some View {
        @Bindable var app = app
        if let i = app.tracks.firstIndex(where: { $0.id == id }) {
            let track = app.tracks[i]
            Button { editing = true } label: {
                Text(track.name.isEmpty ? "Track \(i + 1)" : track.name)
                    .font(.tape)
                    .foregroundStyle(Console.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: Console.tapeHeight)
                    .background(RoundedRectangle(cornerRadius: Console.Radius.tape).fill(track.color.fill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename, recolour or change the source of \(track.name)")
            .accessibilityLabel("\(track.name), \(track.source.channelLabel)")
            .accessibilityHint("Opens the track editor")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                TrackEditor(id: id) { editing = false }
            }
        }
    }
}

private struct TrackEditor: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    let done: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var app = app
        if let i = app.tracks.firstIndex(where: { $0.id == id }) {
            let track = app.tracks[i]
            VStack(alignment: .leading, spacing: 14) {
                Text("Track \(i + 1)")
                    .font(.headline)
                TextField("Name", text: app.binding(id, \.name, fallback: ""), prompt: Text("Who or what is on it"))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(done)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tape colour").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(TapeColor.allCases) { color in
                            let selected = track.color == color
                            Button { app.binding(id, \.color, fallback: .white).wrappedValue = color } label: {
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Source").font(.subheadline).foregroundStyle(.secondary)
                    Menu {
                        SourceMenu(current: track.source) { app.setSource($0, for: id) }
                    } label: {
                        Text(app.sourceDescription(track.source))
                    }
                    .disabled(!app.canEditTracks)
                    if let serial = app.transmitter(for: track.source)?.serial, !serial.isEmpty {
                        Text("Serial \(serial). Tap this mic and its meter will move.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Button("Remove track") {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        done()
                        DispatchQueue.main.async { app.removeTrack(id) }
                    }
                    .disabled(!app.canEditTracks)
                    .help(app.canEditTracks ? "Remove this track from the mixer" : "Stop recording to change tracks.")
                    Spacer()
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 330)
            .onAppear { nameFocused = true }
        }
    }
}

// MARK: Sources

/// Menu items for every source a track can use; used to change an existing track's source.
private struct SourceMenu: View {
    @Environment(AppModel.self) private var app
    let current: TrackSource
    let pick: (TrackSource) -> Void

    var body: some View {
        let choices = app.sourceChoices()
        ForEach(choices.systems, id: \.id) { system in
            Section(system.name) {
                ForEach(system.options, id: \.source) { choice in
                    Button(choice.title) { pick(choice.source) }
                        .disabled(choice.inUse && choice.source != current)
                }
            }
        }
        ForEach(choices.devices, id: \.uid) { device in
            Section(device.name) {
                ForEach(device.options, id: \.source) { choice in
                    Button(choice.title) { pick(choice.source) }
                        .disabled(choice.inUse && choice.source != current)
                }
            }
        }
    }
}

/// Picker shown from the "Add track" slot.
private struct SourcePicker: View {
    @Environment(AppModel.self) private var app
    let done: () -> Void

    var body: some View {
        let choices = app.sourceChoices()
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a track")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(choices.systems, id: \.id) { system in
                        group(system.name, system.options)
                    }
                    ForEach(choices.devices, id: \.uid) { device in
                        group(device.name, device.options, note: device.note)
                    }
                    if choices.systems.isEmpty && choices.devices.isEmpty {
                        Text("Plug in a mic, an audio interface or a wireless receiver to add it here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: 440)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func group(_ title: String, _ options: [SourceChoice], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            ForEach(options, id: \.source) { choice in
                Button {
                    app.addTrack(choice.source, name: choice.defaultName)
                    done()
                } label: {
                    HStack {
                        Text(choice.title)
                        Spacer()
                        if choice.inUse {
                            Text("In use").foregroundStyle(.secondary)
                        } else if let note = choice.note {
                            Text(note).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PickerRowStyle())
                .disabled(choice.inUse)
            }
        }
    }
}

private struct PickerRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .background(RoundedRectangle(cornerRadius: Console.Radius.key)
                .fill(Console.silk.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.09 : 0))))
            .onHover { hovering = $0 }
    }
}

// MARK: Strips

/// One mixer channel. `compact` drops row labels when the desk is crowded; `balanceRow`
/// reserves the balance slot on every strip whenever any track is stereo, so mute keys line up.
struct TrackStrip: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    let compact: Bool
    let balanceRow: Bool
    @State private var editing = false

    var body: some View {
        @Bindable var app = app
        if let i = app.tracks.firstIndex(where: { $0.id == id }) {
            let track = app.tracks[i]
            let available = app.engine.trackAvailable.indices.contains(i) && app.engine.trackAvailable[i]
            let muted = app.isMuted(track)

            VStack(spacing: 12) {
                TapeLabel(id: id, editing: $editing)

                HStack(spacing: 4) {
                    Text(sourceCaption(track))
                        .font(.stripLabel)
                        .foregroundStyle(Console.engraving)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(sourceHelp(track) ?? "")
                    Spacer(minLength: 2)
                    if track.source.transmitter != nil {
                        BatteryView(state: app.transmitter(for: track.source))
                    } else if let ms = latency(i), !isBluetooth(track) {
                        Text("+\(Int(ms.rounded())) ms")
                            .font(.stripLabel.monospacedDigit())
                            .foregroundStyle(Console.engraving)
                            .help("Runs about \(Int(ms.rounded())) ms behind the other inputs: this device has its own clock, so its audio is converted to 48 kHz.")
                    }
                }
                .frame(height: 18)

                ZStack {
                    HStack(spacing: 6) {
                        MeterScale()
                        TrackMeters(index: i, stereo: track.source.isStereo, dimmed: muted)
                        FaderView(value: app.binding(id, \.faderDB, fallback: 0), label: "\(track.name) level")
                    }
                    .opacity(available ? 1 : 0.35)
                    if !available {
                        Text(missingMessage(track))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Console.silk)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Console.Radius.key).fill(Console.well))
                    }
                }
                .frame(maxHeight: .infinity)

                Text(track.faderDB.dbLabel)
                    .font(.value)
                    .foregroundStyle(Console.silk)

                Button { app.toggleMute(i) } label: {
                    Text(muted ? "Muted" : "Mute")
                }
                .buttonStyle(KeyStyle(lit: muted, litColor: Console.red, litText: .white, legend: compact ? nil : "\(i + 1)"))
                .help("Mute \(track.name). Shortcut: \(i + 1)")

                GainRow(track: track, compact: compact)

                if balanceRow {
                    if track.source.isStereo {
                        LabeledRow("Balance", compact: compact) {
                            HStack(spacing: 5) {
                                Text("L").accessibilityHidden(true)
                                BalanceControl(value: app.binding(id, \.balance, fallback: 0), label: "\(track.name) balance")
                                Text("R").accessibilityHidden(true)
                            }
                            .font(.scale)
                            .foregroundStyle(Console.engraving)
                        }
                    } else {
                        Color.clear.frame(height: 22)
                    }
                }

                LabeledRow("Venue", compact: compact) {
                    let on = track.sendToVenue
                    Button(compact ? "Venue" : (on ? "On" : "Off")) { app.binding(id, \.sendToVenue, fallback: true).wrappedValue.toggle() }
                        .buttonStyle(KeyStyle(lit: on, litColor: Console.engraving, litText: Console.ink, compact: true))
                        .frame(width: compact ? nil : 58)
                        .help("Send \(track.name) to the venue output")
                        .accessibilityLabel("Venue send")
                        .accessibilityValue(on ? "On" : "Off")
                }
            }
            .padding(compact ? 10 : 12)
            .background(RoundedRectangle(cornerRadius: Console.Radius.container).fill(Console.panel))
            .contentShape(RoundedRectangle(cornerRadius: Console.Radius.container))
            .contextMenu { TrackMenu(id: id) { editing = true } }
        }
    }

    private func sourceCaption(_ track: Track) -> String {
        switch track.source {
        case .transmitter: track.source.channelLabel
        case .device(_, let name, _, _):
            if isBluetooth(track) {
                "Bluetooth"
            } else {
                compact ? track.source.channelLabel : "\(Track.shortDeviceName(name)), \(track.source.channelLabel)"
            }
        }
    }

    private func sourceHelp(_ track: Track) -> String? {
        isBluetooth(track) ? "Bluetooth mics run behind the other inputs, often by 100 ms or more. Keep them off the venue output." : nil
    }

    private func isBluetooth(_ track: Track) -> Bool {
        app.engine.device(for: track.source)?.isBluetooth ?? false
    }

    private func latency(_ index: Int) -> Double? {
        app.engine.trackLatencyMs.indices.contains(index) ? app.engine.trackLatencyMs[index] : nil
    }

    private func missingMessage(_ track: Track) -> String {
        switch track.source {
        case .transmitter(let system, let slot):
            app.engine.receivers[system] == nil ? "Receiver not connected" : "No channel for TX\(slot + 1) in this mode"
        case .device(_, let name, _, _):
            "Plug in \(name)"
        }
    }
}

/// Right-click menu for a track strip.
private struct TrackMenu: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    let rename: () -> Void

    var body: some View {
        if let i = app.tracks.firstIndex(where: { $0.id == id }) {
            let track = app.tracks[i]
            let editable = app.canEditTracks
            Button("Rename…", action: rename)
            Picker("Colour", selection: app.binding(id, \.color, fallback: .white)) {
                ForEach(TapeColor.allCases) { Text($0.label).tag($0) }
            }
            Menu("Source") {
                SourceMenu(current: track.source) { app.setSource($0, for: id) }
            }
            .disabled(!editable)

            Divider()
            Button(app.isMuted(track) ? "Unmute" : "Mute") { app.toggleMute(i) }
            Toggle("Send to venue", isOn: app.binding(id, \.sendToVenue, fallback: true))
            Button("Reset fader to 0 dB") { app.binding(id, \.faderDB, fallback: 0).wrappedValue = 0 }
                .disabled(track.faderDB == 0)

            Divider()
            Button("Move left") { app.moveTrack(id, by: -1) }
                .disabled(!editable || i == 0)
            Button("Move right") { app.moveTrack(id, by: 1) }
                .disabled(!editable || i == app.tracks.count - 1)

            Divider()
            Button("Remove track", role: .destructive) {
                // A focused name field must let go first; see TrackEditor.
                NSApp.keyWindow?.makeFirstResponder(nil)
                DispatchQueue.main.async { app.removeTrack(id) }
            }
            .disabled(!editable)
        }
    }
}

/// A strip row with its label on the left, or just the control when the desk is crowded.
private struct LabeledRow<Content: View>: View {
    let title: String
    let compact: Bool
    @ViewBuilder let content: Content

    init(_ title: String, compact: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if !compact {
                Text(title)
                    .font(.stripLabel)
                    .foregroundStyle(Console.engraving)
                Spacer(minLength: 4)
            }
            content
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
    }
}

private struct TrackMeters: View {
    @Environment(AppModel.self) private var app
    let index: Int
    let stereo: Bool
    let dimmed: Bool

    var body: some View {
        let levels = app.meters.tracks[index]
        HStack(spacing: 2) {
            LEDMeter(channel: levels.left, dimmed: dimmed)
                .frame(width: stereo ? 7 : 12)
            if stereo {
                LEDMeter(channel: levels.right, dimmed: dimmed)
                    .frame(width: 7)
            }
        }
    }
}

/// Gain on the source itself: the DJI transmitter's preamp, a device's own input gain when the
/// system allows it, or a hint to set it on the device.
private struct GainRow: View {
    @Environment(AppModel.self) private var app
    let track: Track
    let compact: Bool

    var body: some View {
        if let t = track.source.transmitter, let system = app.micSystem(id: t.system), let gain = system.gain {
            let state = app.transmitter(for: track.source)
            let value = state?.pendingGainDB ?? state?.gainDB ?? 0
            LabeledRow("Mic gain", compact: compact) {
                GainStepper(label: Self.label(value, step: gain.step),
                            enabled: state?.connected ?? false, faded: state?.pendingGainDB != nil,
                            canDecrease: value > gain.range.lowerBound, canIncrease: value < gain.range.upperBound) { direction in
                    system.setGain(min(max(value + Double(direction) * gain.step, gain.range.lowerBound), gain.range.upperBound),
                                   slot: t.slot)
                }
            }
            .help("Gain on the transmitter itself. It changes the signal everywhere, including recordings and the receiver's own outputs.")
        } else if track.source.transmitter != nil {
            Text(compact ? "Gain on mic" : "Set gain on the mic")
                .font(.system(size: 11))
                .foregroundStyle(Console.engraving)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 22)
                .help("Lavboard can't change this transmitter's gain")
        } else if let gain = app.deviceGain(for: track) {
            LabeledRow("Input gain", compact: compact) {
                GainStepper(label: String(format: "%.0f dB", gain.value), enabled: true, faded: false,
                            canDecrease: gain.value > gain.range.lowerBound,
                            canIncrease: gain.value < gain.range.upperBound) { step in
                    app.setDeviceGain(gain.value + Double(step), for: track)
                }
            }
            .help("The device's own input gain")
        } else {
            Text(compact ? "Gain on device" : "Set gain on the device")
                .font(.system(size: 11))
                .foregroundStyle(Console.engraving)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 22)
                .help("This device doesn't let apps change its gain")
        }
    }
}

extension GainRow {
    static func label(_ dB: Double, step: Double) -> String {
        let whole = step == step.rounded()
        if dB == 0 { return "0 dB" }
        return whole ? String(format: "%+.0f dB", dB) : String(format: "%+.1f dB", dB)
    }
}

private struct GainStepper: View {
    let label: String
    let enabled: Bool
    let faded: Bool
    let canDecrease: Bool
    let canIncrease: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            stepButton("minus", enabled: enabled && canDecrease) { step(-1) }
            Text(label)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Console.silk.opacity(faded ? 0.5 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 40)
            stepButton("plus", enabled: enabled && canIncrease) { step(1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(label)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            step(direction == .increment ? 1 : -1)
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

/// Left/right balance for stereo tracks. Drag the cap; double-click to centre.
private struct BalanceControl: View {
    @Binding var value: Double
    let label: String
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - 14, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Console.well).frame(height: 4)
                Rectangle().fill(Console.engraving).frame(width: 1, height: 10)
                    .offset(x: geo.size.width / 2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Console.engraving)
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat((value + 1) / 2) * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = dragStart ?? value
                        dragStart = start
                        let delta = Double(g.translation.width) / Double(travel) * 2
                        value = min(max(start + delta, -1), 1)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(minWidth: 56, maxWidth: 96)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(value == 0 ? "Centre" : String(format: "%.0f%% %@", abs(value) * 100, value < 0 ? "left" : "right"))
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 0.1 : -0.1), -1), 1)
        }
    }
}

/// The empty channel at the end of the desk: click to add a track.
struct AddTrackSlot: View {
    @Environment(AppModel.self) private var app
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                Text("Add track")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Console.engraving)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Console.Radius.container)
                .strokeBorder(Console.engraving.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!app.canAddTrack)
        .help(app.recorder.isRecording ? "Stop recording to add tracks." : "Add a mic or input (up to \(Track.maximum) tracks)")
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            SourcePicker { picking = false }
        }
    }
}

struct BatteryView: View {
    let state: TransmitterState?

    var body: some View {
        if let state, state.connected, let battery = state.battery {
            let percent = Int((battery * 100).rounded())
            let low = percent <= 20 && !state.charging
            let symbol = state.charging ? "battery.100percent.bolt"
                : percent > 80 ? "battery.100percent" : percent > 55 ? "battery.75percent"
                : percent > 30 ? "battery.50percent" : percent > 10 ? "battery.25percent" : "battery.0percent"
            Image(systemName: symbol)
                .foregroundStyle(low ? Console.red : Console.engraving)
                .help(state.charging ? "Charging" : "Battery about \(percent)%")
                .accessibilityLabel(state.charging ? "Charging" : "Battery about \(percent) percent")
        }
    }
}

// MARK: Outputs

/// Output strip: picks its device and sets its level.
struct MasterStrip: View {
    @Environment(AppModel.self) private var app
    let title: String
    let meter: MeterStore.Level
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
        .contentShape(RoundedRectangle(cornerRadius: Console.Radius.container))
        .contextMenu {
            Button("Reset level to 0 dB") { level = 0 }
                .disabled(level == 0)
        }
    }
}
