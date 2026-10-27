import Foundation
import ArenaCore

public enum ProviderFailure: LocalizedError {
    case missing, readOnly, interrupted(String), busy, processing
    public var errorDescription: String? {
        switch self {
        case .missing: return "This item is unavailable. Refresh the channel in Are.na x Finder."
        case .readOnly: return "This operation isn’t supported. Drop files into a writable channel to upload."
        case .interrupted(let name): return "The result of uploading \(name) is unknown. Open Are.na x Finder and review the interrupted upload before retrying."
        case .busy: return "This upload is already running."
        case .processing: return "Are.na is still processing the file. Retry shortly; it will not be uploaded again."
        }
    }
}

public struct ImportAttempt: Codable, Sendable {
    public let requestID: String
    public let channelID: Int
    public let parent: String
    public let filename: String
    public var creating: Bool = false
    public var blockID: Int?
    public var record: ProviderRecord?
}

public struct ImportResolution: Codable {
    public let blockID: Int?
    public let retry: Bool
    public init(blockID: Int? = nil, retry: Bool = false) { self.blockID = blockID; self.retry = retry }
}

public actor ProviderEngine {
    struct Snapshot: Codable {
        var records: [String: ProviderRecord] = [:]
        var loadedPages: [String: [String]] = [:]
        var pageGenerations: [String: Int] = [:]
        var generation: Int = -1
        var listingPageSize: Int?
        var imports: [String: ImportAttempt] = [:]
        var revision: Int = 0
        var changes: [Change] = []
    }
    struct Change: Codable { let revision: Int; let id: String; let deleted: Bool; var parent: String? }
    private var snapshot: Snapshot
    private let backend: any ProviderBackend
    private let directory: URL
    private let configuration: () throws -> FinderConfiguration
    private let websiteThumbnails: WebsiteThumbnailStore?
    private var runningImports: Set<String> = []
    private var pageTasks: [String: Task<[ProviderRecord], Error>] = [:]
    public init(directory: URL, backend: any ProviderBackend, websiteThumbnails: WebsiteThumbnailStore? = nil, configuration: @escaping () throws -> FinderConfiguration) throws {
        self.websiteThumbnails = websiteThumbnails
        self.directory = directory; self.backend = backend; self.configuration = configuration
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("provider-state.json")
        snapshot = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)) : Snapshot()
        if snapshot.listingPageSize != ArenaClient.channelContentsPageSize {
            // Keep records and upload recovery intact until a fresh listing arrives.
            snapshot.pageGenerations.removeAll()
            snapshot.listingPageSize = ArenaClient.channelContentsPageSize
            try persist()
        }
    }
    private func persist() throws {
        let url = directory.appendingPathComponent("provider-state.json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func remember(_ record: ProviderRecord) {
        guard snapshot.records[record.id] != record else { return }
        snapshot.records[record.id] = record
        snapshot.revision += 1
        snapshot.changes.append(Change(revision: snapshot.revision, id: record.id, deleted: false, parent: record.parent))
    }
    private func forgetTree(_ id: String) {
        guard let record = snapshot.records[id] else { return }
        let children = snapshot.records.values.filter { $0.parent == id }.map(\.id)
        for child in children { forgetTree(child) }
        snapshot.records.removeValue(forKey: id)
        snapshot.loadedPages.removeValue(forKey: id)
        snapshot.pageGenerations.removeValue(forKey: id)
        snapshot.revision += 1
        snapshot.changes.append(Change(revision: snapshot.revision, id: id, deleted: true, parent: record.parent))
    }
    private func loadConfiguration() throws -> FinderConfiguration {
        let config = try configuration()
        if config.refreshGeneration != snapshot.generation {
            snapshot.generation = config.refreshGeneration
        }
        for channel in config.channels { remember(.channel(channel)) }
        updateWebsiteThumbnails()
        try persist()
        return config
    }
    private func updateWebsiteThumbnails() {
        guard let websiteThumbnails else { return }
        for var record in Array(snapshot.records.values) {
            guard let url = record.websiteURL else { continue }
            if record.thumbnail == nil { try? websiteThumbnails.enqueue(url) }
            if let result = websiteThumbnails.result(for: url), let revision = result.revision {
                record.websiteThumbnailRevision = revision
                record.websiteThumbnailDate = result.completedAt
                remember(record)
            }
        }
    }
    public func item(_ id: String) throws -> ProviderRecord {
        _ = try loadConfiguration()
        if id == "root" { return ProviderRecord(id: "root", parent: "root", filename: "Are.na", typeIdentifier: "public.folder") }
        guard let item = snapshot.records[id] else { throw ProviderFailure.missing }
        return item
    }
    public func list(_ parent: String) async throws -> [ProviderRecord] {
        let config = try loadConfiguration()
        if parent == "root" { return config.channels.map(ProviderRecord.channel) }
        if parent == "working" { return Array(snapshot.records.values) }
        guard let folder = snapshot.records[parent], folder.isFolder, let channelID = folder.channelID,
              let channel = config.channels.first(where: { $0.id == channelID }), let page = folder.page else { throw ProviderFailure.missing }
        if snapshot.pageGenerations[parent] == config.refreshGeneration, let ids = snapshot.loadedPages[parent] { return ids.compactMap { snapshot.records[$0] } }
        if let task = pageTasks[parent] { return try await task.value }
        let backend = backend
        let task = Task { () throws -> [ProviderRecord] in
            let result = try await backend.list(channel: channel, page: page, parent: parent)
            var records = result.records
            if let next = result.nextPage, next > page {
                records.append(.more(channelID: channelID, page: next, parent: parent, writable: channel.writable))
            }
            return records
        }
        pageTasks[parent] = task
        defer { pageTasks[parent] = nil }
        let records = try await task.value
        // One explicit folder contains one API page. Finder otherwise eagerly
        // follows every continuation page, even when its window is not scrolling.
        let fresh = Set(records.map(\.id))
        // Move surviving items to their new parent before removing obsolete page
        // folders, so a page-size upgrade doesn't delete their stable identifiers.
        records.forEach { remember($0) }
        for id in snapshot.loadedPages[parent] ?? [] where !fresh.contains(id) && snapshot.records[id]?.parent == parent {
            forgetTree(id)
        }
        snapshot.loadedPages[parent] = records.map(\.id)
        snapshot.pageGenerations[parent] = config.refreshGeneration
        updateWebsiteThumbnails()
        try persist()
        return records.compactMap { snapshot.records[$0.id] }
    }
    public func contents(_ id: String) async throws -> (ProviderRecord, Data) {
        let record = try item(id)
        guard !record.isFolder else { throw ProviderFailure.readOnly }
        return (record, try await backend.contents(record))
    }
    public func thumbnail(_ id: String) async throws -> Data? {
        let record = try item(id)
        if let url = record.websiteURL, let data = websiteThumbnails?.image(for: url) { return data }
        let cache = directory.appendingPathComponent("thumbnail-" + record.fingerprint)
        if let data = try? Data(contentsOf: cache) { return data }
        let data: Data?
        do { data = try await backend.thumbnail(record) }
        catch {
            guard let url = record.websiteURL, let websiteThumbnails else { throw error }
            try websiteThumbnails.enqueue(url)
            return nil
        }
        guard let data else {
            if let url = record.websiteURL { try websiteThumbnails?.enqueue(url) }
            return nil
        }
        try data.write(to: cache, options: .atomic)
        return data
    }
    public func revision() -> Int { snapshot.revision }
    public func refreshLoadedPages() async throws {
        // macOS applies remote changes through the working-set enumerator. Only
        // revisit pages the user previously opened, and only list()'s stale pages
        // issue requests. Visit parents first in case they remove old page folders.
        let parents = snapshot.loadedPages.keys.sorted {
            (snapshot.records[$0]?.page ?? 0) < (snapshot.records[$1]?.page ?? 0)
        }
        for parent in parents where snapshot.records[parent]?.isFolder == true {
            _ = try await list(parent)
        }
    }
    public func changes(after revision: Int, parent: String? = nil) throws -> (updated: [ProviderRecord], deleted: [String], revision: Int) {
        _ = try loadConfiguration()
        let ids = Set(snapshot.changes.filter { $0.revision > revision && (parent == nil || $0.parent == parent) }.map(\.id))
        return (ids.compactMap { snapshot.records[$0] }, ids.filter { snapshot.records[$0] == nil }, snapshot.revision)
    }
    public func importFile(requestID: String, parent: String, filename: String, file: URL?) async throws -> ProviderRecord {
        guard !runningImports.contains(requestID) else { throw ProviderFailure.busy }
        runningImports.insert(requestID)
        defer { runningImports.remove(requestID) }
        let folder = try item(parent)
        guard folder.isFolder, folder.writable, let channelID = folder.channelID else { throw ProviderFailure.readOnly }
        var attempt = snapshot.imports[requestID] ?? ImportAttempt(requestID: requestID, channelID: channelID, parent: parent, filename: filename)
        guard attempt.channelID == channelID else { throw ProviderFailure.readOnly }
        if let record = attempt.record { return record }
        if attempt.creating && attempt.blockID == nil {
            // Human resolutions arrive in separate files so the host never edits
            // the extension's database while it is running.
            let resolution = directory.appendingPathComponent("resolution-" + Self.key(requestID) + ".json")
            if let data = try? Data(contentsOf: resolution), let decision = try? JSONDecoder().decode(ImportResolution.self, from: data),
               decision.retry || (decision.blockID ?? 0) > 0 {
                attempt.blockID = decision.blockID; attempt.creating = false
                snapshot.imports[requestID] = attempt; try persist()
                try? FileManager.default.removeItem(at: resolution)
            } else { throw ProviderFailure.interrupted(filename) }
        }
        if attempt.blockID == nil {
            guard let file else { throw ProviderFailure.missing }
            let source = try await backend.upload(file, filename: filename)
            try Task.checkCancellation()
            attempt.creating = true
            snapshot.imports[requestID] = attempt; try persist()
            do { attempt.blockID = try await backend.create(source: source, filename: filename, channelID: channelID) }
            catch {
                if let error = error as? APIError, error.definiteRejection {
                    attempt.creating = false; snapshot.imports[requestID] = attempt; try persist()
                }
                throw error
            }
            attempt.creating = false
            snapshot.imports[requestID] = attempt; try persist()
        }
        var processed: ProviderRecord?
        for poll in 0..<6 {
            do { processed = try await backend.record(blockID: attempt.blockID!, channelID: channelID, parent: parent); break }
            catch ProviderFailure.processing {
                if poll == 5 { throw ProviderFailure.processing }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        guard let record = processed else { throw ProviderFailure.processing }
        attempt.record = record; snapshot.imports[requestID] = attempt
        remember(record)
        if snapshot.loadedPages[parent] != nil, !snapshot.loadedPages[parent]!.contains(record.id) { snapshot.loadedPages[parent]!.append(record.id) }
        try persist()
        return record
    }
    public static func key(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }
    public static func interruptedUploads(in directory: URL) throws -> [ImportAttempt] {
        let url = directory.appendingPathComponent("provider-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)).imports.values.filter { $0.creating && $0.blockID == nil }
    }
}
