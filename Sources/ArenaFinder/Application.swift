import AppKit
import ArenaCore

@main
enum Application {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            try handOverFromOtherCopies()
            let override = ProcessInfo.processInfo.environment["ARENA_FINDER_DATA_DIR"]
            let directory = override.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Are.na x Finder", isDirectory: true)
            let delegate = AppDelegate(store: try Store(directory: directory))
            app.delegate = delegate
            app.servicesProvider = delegate
            NSUpdateDynamicServices()
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open Are.na x Finder"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @MainActor private static func handOverFromOtherCopies() throws {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !copies.isEmpty else { return }
        throw BridgeError.message("Are.na x Finder is already running. Open the existing app from Applications. Queued uploads are retained.")
    }
}
