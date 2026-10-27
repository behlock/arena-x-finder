import AppKit
import ArenaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    private var picker: PickerController?
    private var idleTimer: Timer?

    init(store: Store) { self.store = store; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in
                guard !NSApp.windows.contains(where: \.isVisible) else { return }
                NSApp.terminate(nil)
            }
        }
        showLibrary()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }
    private func showLibrary() {
        if picker == nil { picker = PickerController(store: store) }
        picker?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
