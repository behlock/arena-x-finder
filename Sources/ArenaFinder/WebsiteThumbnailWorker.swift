import AppKit
import WebKit
import ArenaProvider

@MainActor
enum WebsiteThumbnailWorker {
    static func run() async throws {
        let group = try ProviderPaths.groupDirectory()
        let store = WebsiteThumbnailStore(directory: group.appendingPathComponent("website-thumbnails"))
        let dataStore = WKWebsiteDataStore.nonPersistent()
        while !Task.isCancelled {
            let pending = try store.pending()
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                var requests = pending.makeIterator()
                func schedule(_ request: WebsiteThumbnailStore.Request) {
                    tasks.addTask { @MainActor in
                        let capture = PageCapture(dataStore: dataStore)
                        do {
                            let screenshot = try await capture.capture(request.url, timeout: 20)
                            let png = try await Task.detached {
                                let image = try IconRenderer.render(screenshot: screenshot.image, websiteURL: request.url)
                                return try IconRenderer.pngData(image)
                            }.value
                            try Task.checkCancellation()
                            try store.complete(request.url, png: png)
                        } catch is CancellationError { throw CancellationError() }
                        catch { try store.complete(request.url, png: nil) }
                    }
                }
                for _ in 0..<2 { if let request = requests.next() { schedule(request) } }
                var changed = false
                var lastSignal = Date.distantPast
                while let _ = try await tasks.next() {
                    try Task.checkCancellation()
                    changed = true
                    if let request = requests.next() { schedule(request) }
                    if Date().timeIntervalSince(lastSignal) >= 1 {
                        await signalChanges()
                        lastSignal = Date()
                        changed = false
                    }
                }
                if changed { await signalChanges() }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func signalChanges() async {
        // Signal using the containing app's identity, which owns the provider domain.
        let executable = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacOS/Are.na x Finder")
        try? await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--thumbnail-changed"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }.value
    }
}
