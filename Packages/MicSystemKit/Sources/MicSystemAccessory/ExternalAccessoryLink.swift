#if os(iOS)
import ExternalAccessory
import Foundation
import MicSystemKit
import os

/// Talks to an MFi accessory's control channel through Apple's External Accessory framework, the
/// way iPhone and iPad apps reach a receiver plugged into the device.
///
/// The app must list `protocolString` under `UISupportedExternalAccessoryProtocols` in its
/// Info.plist, and `external-accessory` under `UIBackgroundModes` to keep the channel open in the
/// background. App Review only accepts apps that declare an accessory protocol when the accessory
/// maker has approved them, so App Store builds should leave this library out and run their
/// modules audio-only.
///
/// Streams run on the main run loop; the traffic is a few small status frames a second.
public final class ExternalAccessoryLink: NSObject, ControlLink, StreamDelegate, @unchecked Sendable {
    public var onConnect: ((_ productID: Int) -> Void)?
    public var onDisconnect: (() -> Void)?
    public var onBytes: (([UInt8]) -> Void)?

    public let protocolString: String
    private let log: Logger
    private var session: EASession?
    private var connectionID: Int?
    private var outgoing: [UInt8] = []
    private var started = false
    /// Reopen attempts after a stream error while the accessory stays attached.
    private var retries = 0

    /// `label` names the log category, e.g. "dji-mic-mini-2s".
    public init(protocolString: String, label: String) {
        self.protocolString = protocolString
        log = Logger(subsystem: "com.sauerdev.lavboard", category: "accessory.\(label)")
        super.init()
    }

    public func start() {
        DispatchQueue.main.async { [self] in
            guard !started else { return }
            started = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(accessoryConnected(_:)), name: .EAAccessoryDidConnect, object: nil)
            center.addObserver(self, selector: #selector(accessoryDisconnected(_:)), name: .EAAccessoryDidDisconnect, object: nil)
            EAAccessoryManager.shared().registerForLocalNotifications()
            openAttachedAccessory()
        }
    }

    public func send(_ bytes: [UInt8]) {
        DispatchQueue.main.async { [self] in
            guard session != nil else { return }
            outgoing += bytes
            flush()
        }
    }

    // MARK: Accessories

    private func openAttachedAccessory() {
        guard session == nil,
              let accessory = EAAccessoryManager.shared().connectedAccessories
                .first(where: { $0.protocolStrings.contains(protocolString) })
        else { return }
        open(accessory)
    }

    private func open(_ accessory: EAAccessory) {
        guard let session = EASession(accessory: accessory, forProtocol: protocolString),
              let input = session.inputStream, let output = session.outputStream else {
            log.error("couldn't open \(self.protocolString, privacy: .public) on \(accessory.name, privacy: .public)")
            return
        }
        for stream in [input, output] as [Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        self.session = session
        connectionID = accessory.connectionID
        log.info("opened \(accessory.name, privacy: .public) model \(accessory.modelNumber, privacy: .public) firmware \(accessory.firmwareRevision, privacy: .public)")
        onConnect?(0)
    }

    private func close() {
        guard let session else { return }
        for stream in [session.inputStream, session.outputStream].compactMap({ $0 }) as [Stream] {
            stream.close()
            stream.remove(from: .main, forMode: .default)
            stream.delegate = nil
        }
        self.session = nil
        connectionID = nil
        outgoing.removeAll()
        onDisconnect?()
    }

    @objc private func accessoryConnected(_ note: Notification) {
        guard session == nil,
              let accessory = note.userInfo?[EAAccessoryKey] as? EAAccessory,
              accessory.protocolStrings.contains(protocolString) else { return }
        retries = 0
        open(accessory)
    }

    @objc private func accessoryDisconnected(_ note: Notification) {
        guard let accessory = note.userInfo?[EAAccessoryKey] as? EAAccessory,
              accessory.connectionID == connectionID else { return }
        log.info("receiver disconnected")
        close()
    }

    // MARK: Streams

    public func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            guard let input = stream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 512)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                retries = 0
                onBytes?(Array(buffer[0..<count]))
            }
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred, .endEncountered:
            log.error("stream closed: \(stream.streamError?.localizedDescription ?? "end of stream", privacy: .public)")
            close()
            // The accessory may still be attached; try again a few times before waiting for it to reconnect.
            guard retries < 5 else { return }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openAttachedAccessory() }
        default:
            break
        }
    }

    private func flush() {
        guard let output = session?.outputStream, output.hasSpaceAvailable, !outgoing.isEmpty else { return }
        let written = outgoing.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
        if written > 0 {
            outgoing.removeFirst(written)
        } else if written < 0 {
            log.error("write failed: \(output.streamError?.localizedDescription ?? "unknown error", privacy: .public)")
        }
    }
}
#endif
