import AppKit
import FileProvider
import ArenaCore
import ArenaProvider

@MainActor
enum FinderBridge {
    static let liveDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("arena-live"), displayName: "Are.na")
    static let demoDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("arena-demo"), displayName: "Are.na Demo")
    static func validateAccount(_ accountID: Int) throws {
        if let config = try? ProviderPaths.configuration(), config.accountID != accountID, !config.channels.isEmpty {
            throw BridgeError.message("The Finder library is connected to another account. Keep using that account for this prototype.")
        }
    }
    static func addChannel(_ channel: Channel, accountID: Int) async throws {
        try validateAccount(accountID)
        var config = (try? ProviderPaths.configuration()) ?? FinderConfiguration(accountID: accountID)
        let chosen = FinderChannel(id: channel.id, title: channel.title, slug: channel.slug, writable: channel.can?.add_to == true)
        if let index = config.channels.firstIndex(where: { $0.id == channel.id }) { config.channels[index] = chosen }
        else { config.channels.append(chosen) }
        config.refreshGeneration += 1
        try ProviderPaths.saveConfiguration(config)
        try await NSFileProviderManager.add(liveDomain)
        try await signal(liveDomain, channels: config.channels)
        try await reveal(liveDomain)
    }
    static func refresh() async throws {
        var config = try ProviderPaths.configuration()
        config.refreshGeneration += 1
        try ProviderPaths.saveConfiguration(config)
        try await signal(liveDomain, channels: config.channels)
    }
    static func reveal(_ domain: NSFileProviderDomain) async throws {
        guard let manager = NSFileProviderManager(for: domain) else { throw BridgeError.message("The Finder extension is not installed.") }
        let url = try await manager.getUserVisibleURL(for: .rootContainer)
        NSWorkspace.shared.open(url)
    }
    static func signal(_ domain: NSFileProviderDomain, channels: [FinderChannel]) async throws {
        guard let manager = NSFileProviderManager(for: domain) else { throw BridgeError.message("The Finder extension is not installed.") }
        try await manager.signalEnumerator(for: .rootContainer)
        for channel in channels { try await manager.signalEnumerator(for: NSFileProviderItemIdentifier("channel-\(channel.id)")) }
        try await manager.signalEnumerator(for: .workingSet)
        try await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
    }
    static func reviewUploads(window: NSWindow) throws {
        let directory = try ProviderPaths.groupDirectory().appendingPathComponent("provider-live")
        guard let attempt = try ProviderEngine.interruptedUploads(in: directory).first else {
            let alert = NSAlert(); alert.messageText = "No interrupted Finder uploads need review."; alert.beginSheetModal(for: window); return
        }
        let config = try ProviderPaths.configuration()
        if let channel = config.channels.first(where: { $0.id == attempt.channelID }) {
            NSWorkspace.shared.open(URL(string: "https://www.are.na/channel/\(channel.slug)")!)
        }
        let alert = NSAlert()
        alert.messageText = "Review \(attempt.filename)"
        alert.informativeText = "Check the channel first. If the file was added, paste its Are.na block URL below. Only choose ‘Missing — retry’ if it is absent; retrying an existing block would add a duplicate."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        field.placeholderString = "https://www.are.na/block/123456"
        alert.accessoryView = field
        alert.addButton(withTitle: "Link existing block"); alert.addButton(withTitle: "Missing — retry"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let resolution: ImportResolution
            if response == .alertSecondButtonReturn { resolution = ImportResolution(retry: true) }
            else if response == .alertFirstButtonReturn,
                    let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                    url.scheme == "https", ["are.na", "www.are.na"].contains(url.host ?? ""), url.pathComponents.count == 3,
                    url.pathComponents[1] == "block", let blockID = Int(url.lastPathComponent), blockID > 0 {
                resolution = ImportResolution(blockID: blockID)
            } else { return }
            do {
                try JSONEncoder().encode(resolution).write(to: directory.appendingPathComponent("resolution-" + ProviderEngine.key(attempt.requestID) + ".json"), options: .atomic)
                Task { try? await NSFileProviderManager(for: liveDomain)?.signalErrorResolved(NSFileProviderError(.cannotSynchronize)) }
            } catch {
                let errorAlert = NSAlert(error: error); errorAlert.beginSheetModal(for: window)
            }
        }
    }

    static func removeDemo() async throws {
        let preserved = try await NSFileProviderManager.remove(demoDomain, mode: .preserveDirtyUserData)
        if let preserved { print("Preserved unsynced demo files at \(preserved.path)") }
        CredentialVault.removeSmokeCredential()
    }

    // Runs inside the signed host app so macOS attributes domain registration
    // to its embedded extension. Only the synthetic demo backend is exercised.
    static func smoke() async throws {
        try CredentialVault.save("local-smoke-value", trustedPaths: TokenStore.trustedPaths, service: "com.behlock.arena-x-finder.smoke")
        defer { CredentialVault.removeSmokeCredential() }
        try await NSFileProviderManager.add(demoDomain)
        guard let manager = NSFileProviderManager(for: demoDomain) else { throw ProviderFailure.missing }
        let root = try await manager.getUserVisibleURL(for: .rootContainer)
        print("DEMO_ROOT=\(root.path)")
        print("GROUP=\(try ProviderPaths.groupDirectory().path)")
        fflush(stdout)
        try? await manager.evictItem(identifier: NSFileProviderItemIdentifier("block-1-1"))
        // File coordination invokes the actual system provider; this is not a
        // direct call to the backend or a hand-built local mirror.
        try await Task.detached {
            func coordinated<T>(_ url: URL, writing: Bool = false, _ body: @escaping (URL) throws -> T) throws -> T {
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var result: Result<T, Error>?
                let accessor: (URL) -> Void = { coordinatedURL in result = Result { try body(coordinatedURL) } }
                if writing { coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
                else { coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
                if let coordinationError { throw coordinationError }
                guard let result else { throw ProviderFailure.missing }
                return try result.get()
            }
            let children = try coordinated(root) { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            print("ROOT_ITEMS=\(children.map(\.lastPathComponent))")
            guard let channel = children.first(where: { $0.lastPathComponent == "Demo channel [1]" }) else { throw ProviderFailure.missing }
            let files = try coordinated(channel) { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            print("CHANNEL_ITEMS=\(files.map(\.lastPathComponent))")
            let text = try coordinated(channel.appendingPathComponent("Welcome.txt")) { try String(contentsOf: $0) }
            print("DOWNLOADED=\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            let destination = channel.appendingPathComponent("Finder import test.txt")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try coordinated(destination, writing: true) { try Data("Imported through the macOS File Provider system.\n".utf8).write(to: $0) }
            }
            print("IMPORT_SUBMITTED=Finder import test.txt")
        }.value
    }
}
