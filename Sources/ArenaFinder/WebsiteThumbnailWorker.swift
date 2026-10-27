import AppKit
import WebKit
import ArenaProvider
import ThumbnailCore
import ThumbnailCapture

@MainActor
enum WebsiteThumbnailWorker {
    static func run() async throws {
        let group = try ProviderPaths.groupDirectory()
        let store = WebsiteThumbnailStore(directory: group.appendingPathComponent("website-thumbnails"))
        let images = IconWorker(cacheDirectory: group.appendingPathComponent("website-render-cache"))
        let capture = PageCapture(dataStore: .nonPersistent())
        while !Task.isCancelled {
            let pending = try store.pending()
            for request in pending {
                try Task.checkCancellation()
                do {
                    let screenshot = try await capture.capture(request.url, timeout: 20)
                    let icon = try await images.prepare(screenshot: screenshot, websiteURL: request.url)
                    let png = try await Task.detached { try IconRenderer.pngData(icon.image) }.value
                    try store.complete(request.url, png: png)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // No raw URLs, site content, credentials, or errors in logs.
                    try store.complete(request.url, png: nil)
                }
                // Signal from the containing app's identity, which owns the File
                // Provider domain. The helper has its own identity to avoid taking
                // over normal app launches while it runs without a window.
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
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
