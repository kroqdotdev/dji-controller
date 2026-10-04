import Foundation
import IOKit
import IOUSBHost
import os

/// Owns the receiver's `com.dji.mic` vendor interface (4): selects alt setting 1 and
/// streams bytes from bulk 0x84 while accepting writes on bulk 0x04. Reconnects
/// automatically when the receiver re-enumerates (e.g. after a channel mode change).
final class USBLink {
    static let vendorID = 0x2CA3
    static let productIDs = [0x4015, 0x4115]

    var onConnect: ((Int) -> Void)?
    var onDisconnect: (() -> Void)?
    var onBytes: (([UInt8]) -> Void)?

    private let log = Logger(subsystem: "com.sauerdev.djicontroller", category: "usb")
    private let queue = DispatchQueue(label: "com.sauerdev.djicontroller.usb")
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var interface: IOUSBHostInterface?
    private var pipeIn: IOUSBHostPipe?
    private var pipeOut: IOUSBHostPipe?

    func start() {
        queue.async { self.installNotifications() }
    }

    func send(_ bytes: [UInt8]) {
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
            withVendorID: NSNumber(value: Self.vendorID), productID: nil, bcdDevice: nil,
            interfaceNumber: 4, configurationValue: 1, interfaceClass: nil, interfaceSubclass: nil,
            interfaceProtocol: nil, speed: nil,
            productIDArray: Self.productIDs.map { NSNumber(value: $0) }
        ).takeRetainedValue()
    }

    private func installNotifications() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingDictionary(), { refcon, iterator in
            Unmanaged<USBLink>.fromOpaque(refcon!).takeUnretainedValue().servicesAdded(iterator)
        }, refcon, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingDictionary(), { refcon, iterator in
            Unmanaged<USBLink>.fromOpaque(refcon!).takeUnretainedValue().servicesRemoved(iterator)
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
            try iface.selectAlternateSetting(1)
            pipeIn = try iface.copyPipe(withAddress: 0x84)
            pipeOut = try iface.copyPipe(withAddress: 0x04)
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
