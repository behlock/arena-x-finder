import AppKit
import ArenaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    let uploader: Uploader
    private var picker: PickerController?
    private var receivedFiles = false
    private var idleTimer: Timer?

    init(store: Store) {
        self.store = store
        uploader = Uploader(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.store.isPreparingImages, !self.uploader.isRunning,
                      !NSApp.windows.contains(where: \.isVisible) else { return }
                NSApp.terminate(nil)
            }
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--send" { showPicker(arguments.dropFirst().map { URL(fileURLWithPath: $0) }) }
        else if !receivedFiles { showPicker([]) }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedFiles = true
        showPicker(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPicker([]) }
        return true
    }

    @objc func sendToArena(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty else { error.pointee = "Select image files in Finder first."; return }
        receivedFiles = true
        showPicker(urls)
    }

    private func showPicker(_ urls: [URL]) {
        guard urls.count <= Store.maximumImagesPerBatch else {
            let alert = NSAlert()
            alert.messageText = "Send up to 100 images at a time."
            alert.runModal(); return
        }
        // Keep a preparation/upload attached to its existing window.
        if store.isPreparingImages || uploader.isRunning {
            picker?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "A batch is already being sent."
            alert.informativeText = "Send this new selection again after the current batch finishes."
            alert.runModal(); return
        }
        picker?.close()
        picker = PickerController(store: store, uploader: uploader, urls: urls)
        picker?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
