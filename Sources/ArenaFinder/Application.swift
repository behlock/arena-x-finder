import AppKit
import ArenaCore

@main
enum Application {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        installMenus()
        if CommandLine.arguments.contains("--finder-remove-demo") {
            Task {
                do { try await FinderBridge.removeDemo(); exit(0) }
                catch { fputs("Could not remove demo: \(error)\n", stderr); exit(1) }
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--finder-smoke") {
            Task {
                do { try await FinderBridge.smoke(); exit(0) }
                catch { fputs("Finder smoke test: \(error)\n", stderr); exit(1) }
            }
            app.run()
            return
        }
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

    @MainActor private static func installMenus() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: "Are.na x Finder")
        application.addItem(withTitle: "Quit Are.na x Finder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = application; menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @MainActor private static func handOverFromOtherCopies() throws {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !copies.isEmpty else { return }
        throw BridgeError.message("Are.na x Finder is already running. Open the existing app from Applications. Queued uploads are retained.")
    }
}
