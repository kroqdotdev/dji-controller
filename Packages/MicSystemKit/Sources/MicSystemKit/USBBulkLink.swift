import Foundation
import IOKit
import IOUSBHost
import os

/// Where a receiver's control channel lives: a vendor interface with one bulk endpoint each way.
public struct USBBulkInterface: Sendable {
    public var vendorID: Int
    public var productIDs: [Int]
    public var interfaceNumber: Int
    public var configuration: Int
    /// Selected after opening, when the endpoints only exist in an alternate setting.
    public var alternateSetting: Int?
    public var inEndpoint: UInt8
    public var outEndpoint: UInt8

    public init(vendorID: Int, productIDs: [Int], interfaceNumber: Int, configuration: Int = 1,
                alternateSetting: Int? = nil, inEndpoint: UInt8, outEndpoint: UInt8) {
        self.vendorID = vendorID
        self.productIDs = productIDs
        self.interfaceNumber = interfaceNumber
        self.configuration = configuration
        self.alternateSetting = alternateSetting
        self.inEndpoint = inEndpoint
        self.outEndpoint = outEndpoint
    }
}

/// Opens a USB vendor interface with IOUSBHost, streams bytes from its bulk IN endpoint and writes
/// to its bulk OUT endpoint. Reconnects by itself when the device re-enumerates (some receivers
/// restart after a mode change). Callbacks arrive on a private queue; hop to the main actor.
public final class USBBulkLink: @unchecked Sendable {
    public var onConnect: ((_ productID: Int) -> Void)?
    public var onDisconnect: (() -> Void)?
    public var onBytes: (([UInt8]) -> Void)?

    private let spec: USBBulkInterface
    private let log: Logger
    private let queue: DispatchQueue
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var interface: IOUSBHostInterface?
    private var pipeIn: IOUSBHostPipe?
    private var pipeOut: IOUSBHostPipe?

    /// `label` names the log category and queue, e.g. "dji-mic-mini-2s".
    public init(_ spec: USBBulkInterface, label: String) {
        self.spec = spec
        log = Logger(subsystem: "com.sauerdev.lavboard", category: "usb.\(label)")
        queue = DispatchQueue(label: "com.sauerdev.lavboard.usb.\(label)")
    }

    public func start() {
        queue.async { self.installNotifications() }
    }

    public func send(_ bytes: [UInt8]) {
        queue.async {
            guard let pipe = self.pipeOut else { return }
            let data = NSMutableData(bytes: bytes, length: bytes.count)
            do {
                try pipe.enqueueIORequest(with: data, completionTimeout: 1.0) { status, _ in
                    _ = data
                    if status != kIOReturnSuccess {
                        self.log.error("write failed: \(String(format: "0x%08x", status), privacy: .public)")
                    }
                }
            } catch {
                self.log.error("write enqueue failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func matchingDictionary() -> CFMutableDictionary {
        IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: NSNumber(value: spec.vendorID), productID: nil, bcdDevice: nil,
            interfaceNumber: NSNumber(value: spec.interfaceNumber), configurationValue: NSNumber(value: spec.configuration),
            interfaceClass: nil, interfaceSubclass: nil, interfaceProtocol: nil, speed: nil,
            productIDArray: spec.productIDs.map { NSNumber(value: $0) }
        ).takeRetainedValue()
    }

    private func installNotifications() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingDictionary(), { refcon, iterator in
            Unmanaged<USBBulkLink>.fromOpaque(refcon!).takeUnretainedValue().servicesAdded(iterator)
        }, refcon, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingDictionary(), { refcon, iterator in
            Unmanaged<USBBulkLink>.fromOpaque(refcon!).takeUnretainedValue().servicesRemoved(iterator)
        }, refcon, &removedIterator)

        servicesAdded(addedIterator)
        servicesRemoved(removedIterator)
    }

    private func servicesAdded(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if interface == nil {
                open(service, attempt: 1)
            } else {
                IOObjectRelease(service)
            }
        }
    }

    private func servicesRemoved(_ iterator: io_iterator_t) {
        var removed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            removed = true
            IOObjectRelease(service)
        }
        if removed, interface != nil {
            log.info("receiver removed")
            close()
            onDisconnect?()
        }
    }

    private func open(_ service: io_service_t, attempt: Int) {
        do {
            let iface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil)
            if let alternate = spec.alternateSetting { try iface.selectAlternateSetting(alternate) }
            pipeIn = try iface.copyPipe(withAddress: Int(spec.inEndpoint))
            pipeOut = try iface.copyPipe(withAddress: Int(spec.outEndpoint))
            interface = iface
            let productID = productID(of: service)
            IOObjectRelease(service)
            log.info("receiver opened, product 0x\(String(productID, radix: 16), privacy: .public)")
            onConnect?(productID)
            enqueueRead()
        } catch {
            log.error("open attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
            if attempt < 6 {
                queue.asyncAfter(deadline: .now() + 0.5) { self.open(service, attempt: attempt + 1) }
            } else {
                IOObjectRelease(service)
            }
        }
    }

    private func productID(of service: io_service_t) -> Int {
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idProduct" as CFString, kCFAllocatorDefault,
                                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return (value as? NSNumber)?.intValue ?? 0
    }

    private func enqueueRead() {
        guard let pipe = pipeIn else { return }
        let data = NSMutableData(length: 512)!
        do {
            try pipe.enqueueIORequest(with: data, completionTimeout: 0) { [weak self] status, transferred in
                guard let self, self.pipeIn === pipe else { return }
                if status == kIOReturnSuccess {
                    if transferred > 0 {
                        self.onBytes?([UInt8](data.prefix(transferred)))
                    }
                    self.enqueueRead()
                } else if status != kIOReturnAborted {
                    self.log.error("read failed: \(String(format: "0x%08x", status), privacy: .public)")
                    self.queue.asyncAfter(deadline: .now() + 0.2) { self.enqueueRead() }
                }
            }
        } catch {
            log.error("read enqueue failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func close() {
        pipeIn = nil
        pipeOut = nil
        interface?.destroy()
        interface = nil
    }
}
