import SwiftUI

@main
struct LavboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Lavboard", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1060, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `-snapshot /path.png` renders the window to a PNG after a few seconds (design review aid).
        if let path = UserDefaults.standard.string(forKey: "snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Self.snapshot(to: path) }
        }
        #endif
    }

    #if DEBUG
    static func snapshot(to path: String) {
        let window = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.max { $0.frame.width < $1.frame.width }
        guard let view = window?.contentView?.superview ?? window?.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
