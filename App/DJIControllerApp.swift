import SwiftUI

@main
struct DJIControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("DJI Controller", id: "main") {
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
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
