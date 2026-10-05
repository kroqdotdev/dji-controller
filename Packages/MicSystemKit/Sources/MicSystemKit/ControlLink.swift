import Foundation

/// A byte pipe to a receiver's control channel. The link only moves bytes and reports when the
/// receiver comes and goes; the module encodes commands and decodes what comes back.
///
/// `USBBulkLink` is the macOS link. On iOS, control channels of MFi accessories go through
/// `ExternalAccessoryLink` in the separate `MicSystemAccessory` library. A module takes its link
/// from the app, so an app that can't use a link (an App Store build without the accessory
/// maker's approval, for example) runs the module audio-only by passing none.
///
/// Callbacks may arrive on any thread; modules hop to the main actor before touching state.
public protocol ControlLink: AnyObject {
    /// The receiver's control channel opened. `productID` is its USB product ID, or 0 when the
    /// link can't tell (External Accessory doesn't expose it).
    var onConnect: ((_ productID: Int) -> Void)? { get set }
    /// The receiver went away, for example unplugged or restarting after a mode change. The link
    /// reconnects by itself when it comes back.
    var onDisconnect: (() -> Void)? { get set }
    /// Bytes from the receiver, split and joined arbitrarily.
    var onBytes: (([UInt8]) -> Void)? { get set }

    /// Starts watching for the receiver. Call once, after setting the callbacks.
    func start()
    /// Queues bytes for the receiver. Dropped if the channel isn't open.
    func send(_ bytes: [UInt8])
}
