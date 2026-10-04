import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmMode: ChannelMode?
    @State private var showSettings = false

    var body: some View {
        let receiver = app.receiver
        VStack(spacing: 0) {
            if receiver.connected, let mode = receiver.mode, mode != .quad, !receiver.switchingMode {
                ModeBanner(mode: mode)
            }
            Desk()
            TransportBar()
        }
        .background(Console.background)
        .foregroundStyle(Console.silk)
        .preferredColorScheme(.dark)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if receiver.connected, let mode = receiver.mode, !receiver.switchingMode {
                    Menu {
                        ForEach(ChannelMode.allCases, id: \.self) { m in
                            Button { confirmMode = m } label: {
                                if m == mode { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                            }
                            .disabled(m == mode)
                        }
                    } label: {
                        Text(mode.label)
                    }
                    .help("Receiver channel mode")
                    .disabled(app.recorder.isRecording)
                }
                Button("Settings") { showSettings.toggle() }
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { MicSettings().padding(18) }
            }
        }
        .toolbarBackground(Console.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .confirmationDialog("Switch the receiver to \(confirmMode?.label ?? "")?",
                            isPresented: Binding(get: { confirmMode != nil }, set: { if !$0 { confirmMode = nil } })) {
            Button("Switch") {
                if let m = confirmMode { app.receiver.setMode(m) }
                confirmMode = nil
            }
        } message: {
            Text("Switching to or from 4-track restarts the receiver. Audio drops out for a few seconds.")
        }
        .onAppear {
            // Start with nothing focused so the 1-4 mute keys work immediately.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private var title: String {
        let receiver = app.receiver
        if receiver.switchingMode { return "Receiver restarting" }
        return receiver.connected ? "Receiver connected" : "Receiver not found"
    }

    /// The engine only takes over the subtitle when it needs attention.
    private var subtitle: String {
        if case .failed(let message) = app.engine.state { return message }
        if let warning = app.engine.warning { return warning }
        return app.receiver.connected ? "\(app.receiver.connectedCount) of 4 mics on" : ""
    }
}

private struct MicSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var engine = app.engine
        let first = app.receiver.transmitters.compactMap { $0?.status }.first
        Form {
            Section {
                Picker("Noise cancellation", selection: Binding(
                    get: { first?.noise ?? .off },
                    set: { app.receiver.setNoiseCancellation($0) })) {
                    ForEach(NoiseCancellation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Low cut", isOn: Binding(get: { first?.lowCut ?? false }, set: { app.receiver.setLowCut($0) }))
            } footer: {
                Text(first == nil ? "Switch on a mic to change these." : "Applies to every connected mic.")
                    .foregroundStyle(.secondary)
            }
            .disabled(first == nil)

            Section {
                LabeledContent("Stream device") {
                    switch app.streamDevice.state {
                    case .installed:
                        Button("Remove") { app.streamDevice.remove() }
                    case .notInstalled, .failed:
                        Button("Set up") { app.streamDevice.install() }
                    case .outdated:
                        Button("Update") { app.streamDevice.install() }
                    case .working:
                        ProgressView().controlSize(.small)
                    }
                }
            } footer: {
                Text("A virtual mic called Lavboard that carries the stream mix to Streamlabs. Setting it up or removing it asks for your password and restarts the Mac's audio for a moment.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Audio buffer", selection: $engine.bufferFrames) {
                    ForEach([32, 64, 128, 256] as [UInt32], id: \.self) { frames in
                        Text("\(frames) samples").tag(frames)
                    }
                }
            } footer: {
                Text("Smaller buffers lower the delay but use more CPU.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ModeBanner: View {
    @Environment(AppModel.self) private var app
    let mode: ChannelMode

    var body: some View {
        HStack(spacing: 14) {
            Text("The receiver is in \(mode.label) mode, so all mics arrive mixed together. Switch to 4-track to control each mic.")
                .font(.system(size: 13))
            Spacer()
            Button("Switch to 4-track") { app.receiver.setMode(.quad) }
                .disabled(app.recorder.isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Console.panel)
    }
}

// MARK: Desk

private struct Desk: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var engine = app.engine
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let meters = app.meters
            let _ = meters.update(app.engine.readMeters(), now: context.date)
            HStack(alignment: .top, spacing: 10) {
                // Built directly rather than in a ForEach: a ForEach closure that only captures the
                // (unchanging) meters reference is treated as unchanged and the strips never redraw.
                ChannelStrip(index: 0, meter: meters.channels[0])
                ChannelStrip(index: 1, meter: meters.channels[1])
                ChannelStrip(index: 2, meter: meters.channels[2])
                ChannelStrip(index: 3, meter: meters.channels[3])
                Spacer(minLength: 14)
                MasterStrip(title: "Stream", meter: meters.channels[4], device: $engine.streamOutputUID,
                            level: $app.streamLevelDB, note: streamNote,
                            actionTitle: streamActionTitle, action: { app.streamDevice.install() })
                MasterStrip(title: "Venue", meter: meters.channels[5], device: $engine.venueOutputUID,
                            level: $app.venueLevelDB, note: venueNote, excluding: StreamDevice.deviceUID)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .opacity(app.receiver.connected ? 1 : 0.25)
            .disabled(!app.receiver.connected)
            .overlay {
                if !app.receiver.connected {
                    NoReceiver()
                }
            }
        }
    }

    private var streamNote: String? {
        switch app.streamDevice.state {
        case .notInstalled:
            return "Adds a mic called Lavboard for Streamlabs"
        case .outdated:
            return "A newer stream device is ready"
        case .working:
            return "Setting up"
        case .failed(let message):
            return message
        case .installed:
            return app.engine.streamOutputUID == StreamDevice.deviceUID ? "In Streamlabs, pick Lavboard as the mic" : nil
        }
    }

    private var streamActionTitle: String? {
        switch app.streamDevice.state {
        case .notInstalled: "Set up"
        case .outdated: "Update"
        case .failed: "Try again"
        default: nil
        }
    }

    private var venueNote: String? {
        guard app.engine.venueOutputUID != nil, let ms = app.engine.venueLatencyMs else { return nil }
        return String(format: "Adds %.1f ms", ms)
    }
}

private struct NoReceiver: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Plug in the DJI receiver")
                .font(.system(size: 22, weight: .semibold))
            Text("The mixer starts as soon as it's connected.")
                .font(.system(size: 13))
                .foregroundStyle(Console.engraving)
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: Console.Radius.container).fill(Console.panel))
    }
}

// MARK: Transport

private struct TransportBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var recorder = app.recorder
        HStack(spacing: 18) {
            Button { app.toggleRecording() } label: {
                HStack(spacing: 8) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "circle.fill")
                        .foregroundStyle(recorder.isRecording ? Color.white : Console.red)
                    Text(recorder.isRecording ? "Stop" : "Record")
                }
            }
            .buttonStyle(KeyStyle(lit: recorder.isRecording, litColor: Console.red, litText: .white))
            .frame(width: 120)
            .disabled(!app.canRecord && !recorder.isRecording)
            .keyboardShortcut("r", modifiers: .command)
            .help("Record every mic to its own file, plus the stream mix (Command-R)")

            if let started = recorder.startedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(started)).formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.timer)
                        .foregroundStyle(Console.red)
                }
            } else {
                Text(destination)
                    .font(.system(size: 12))
                    .foregroundStyle(Console.engraving)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { chooseFolder() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                if recorder.lastFolder != nil {
                    Button("Show in Finder") {
                        if let last = recorder.lastFolder { NSWorkspace.shared.activateFileViewerSelecting([last]) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }

            if let error = recorder.error {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Console.amber)
                    .lineLimit(2)
            }

            Spacer()

            Picker("Format", selection: $recorder.format) {
                ForEach(Recorder.Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(recorder.isRecording)
            .help("File format for the recordings")

            Toggle("Backup on mics", isOn: $app.backupOnTransmitters)
                .disabled(recorder.isRecording)
                .help("Also start each transmitter's own 32-bit float recording")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Console.panel)
    }

    private var destination: String {
        "Saving to " + app.recorder.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        panel.directoryURL = app.recorder.folder
        if panel.runModal() == .OK, let url = panel.url { app.recorder.folder = url }
    }
}
