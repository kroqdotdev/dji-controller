import AppKit
import SwiftUI

// MARK: Tape label and editor

/// The track's name on a piece of console tape. Click to rename, recolour, change the source
/// or remove the track; right-click for colours.
struct TapeLabel: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    @State private var editing = false

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
            .contextMenu {
                Button("Edit…") { editing = true }
                Picker("Tape colour", selection: app.binding(id, \.color, fallback: .white)) {
                    ForEach(TapeColor.allCases) { Text($0.label).tag($0) }
                }
            }
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
                    if let identity = track.source.transmitterSlot.flatMap({ app.receiver.transmitters[$0]?.identity }) {
                        Text("Serial \(identity.serial). Tap this mic and its meter will move.")
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
        if !choices.transmitters.isEmpty {
            Section("DJI receiver") {
                ForEach(choices.transmitters, id: \.source) { choice in
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
                    if !choices.transmitters.isEmpty {
                        group("DJI receiver", choices.transmitters)
                    }
                    ForEach(choices.devices, id: \.uid) { device in
                        group(device.name, device.options)
                    }
                    if choices.transmitters.isEmpty && choices.devices.isEmpty {
                        Text("Plug in a mic, an audio interface or the DJI receiver to add it here.")
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

    private func group(_ title: String, _ options: [SourceChoice]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

    var body: some View {
        @Bindable var app = app
        if let i = app.tracks.firstIndex(where: { $0.id == id }) {
            let track = app.tracks[i]
            let available = app.engine.trackAvailable.indices.contains(i) && app.engine.trackAvailable[i]
            let muted = app.isMuted(track)

            VStack(spacing: 12) {
                TapeLabel(id: id)

                HStack(spacing: 4) {
                    Text(sourceCaption(track))
                        .font(.stripLabel)
                        .foregroundStyle(Console.engraving)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let slot = track.source.transmitterSlot {
                        BatteryView(status: app.receiver.transmitters[slot]?.status)
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
        }
    }

    private func sourceCaption(_ track: Track) -> String {
        switch track.source {
        case .transmitter: track.source.channelLabel
        case .device(_, let name, _, _): compact ? track.source.channelLabel : "\(name), \(track.source.channelLabel)"
        }
    }

    private func missingMessage(_ track: Track) -> String {
        switch track.source {
        case .transmitter(let slot):
            app.receiver.connected ? "Switch on TX\(slot + 1)" : "Receiver not connected"
        case .device(_, let name, _, _):
            "Plug in \(name)"
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
        if let slot = track.source.transmitterSlot {
            let status = app.receiver.transmitters[slot]?.status
            let pending = app.receiver.pendingGain[slot]
            let value = pending ?? status?.gainDB ?? 0
            LabeledRow("Mic gain", compact: compact) {
                GainStepper(label: "\(value == 0 ? "0" : String(format: "%+d", value)) dB",
                            enabled: status != nil, faded: pending != nil,
                            canDecrease: value > -12, canIncrease: value < 12) { step in
                    app.receiver.setGain(slot: slot, dB: value + step)
                }
            }
            .help("Gain on the transmitter itself. It changes the signal everywhere, including recordings and the receiver's analog output.")
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
    }
}
