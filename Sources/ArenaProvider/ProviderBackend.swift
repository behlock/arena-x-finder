import Foundation
import UniformTypeIdentifiers
import ArenaCore

public struct ProviderPage: Sendable {
    public let records: [ProviderRecord]
    public let nextPage: Int?
    public init(records: [ProviderRecord], nextPage: Int?) { self.records = records; self.nextPage = nextPage }
}

public protocol ProviderBackend {
    func list(channel: FinderChannel, page: Int, parent: String) async throws -> ProviderPage
    func contents(_ record: ProviderRecord) async throws -> Data
    func thumbnail(_ record: ProviderRecord) async throws -> Data?
    func upload(_ file: URL, filename: String) async throws -> URL
    func create(source: URL, filename: String, channelID: Int) async throws -> Int
    func record(blockID: Int, channelID: Int, parent: String) async throws -> ProviderRecord
}

// Serial request scheduling keeps Finder's concurrent callbacks within a modest
// budget. Content bytes never receive the API bearer token.
public actor LiveProviderBackend: ProviderBackend {
    private let client: () throws -> ArenaClient
    private var nextRequest = Date.distantPast
    private var counters: [String: Int] = [:]
    private let metricsURL: URL
    public init(credentials: @escaping () throws -> String, metricsURL: URL) {
        client = { ArenaClient(token: try credentials()) }; self.metricsURL = metricsURL
    }
    private func pace(_ category: String) async throws {
        if category == "thumbnail_downloads" || category == "file_downloads" {
            // CDN transfers do not consume the API's request budget. In
            // particular, a foreground file open must not queue behind icons.
            counters[category, default: 0] += 1
            try? JSONEncoder().encode(counters).write(to: metricsURL, options: .atomic)
            return
        }
        let now = Date()
        let scheduled = max(now, nextRequest)
        nextRequest = scheduled.addingTimeInterval(2.1)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        counters[category, default: 0] += 1
        // Counts only: no tokens, file names, channel titles, or signed URLs.
        try? JSONEncoder().encode(counters).write(to: metricsURL, options: .atomic)
    }
    public func list(channel: FinderChannel, page: Int, parent: String) async throws -> ProviderPage {
        try await pace("metadata_pages")
        let response = try await client().contents(channelID: channel.id, page: page)
        return ProviderPage(records: try response.data.map { try ProviderRecord.block($0, channelID: channel.id, parent: parent) }, nextPage: response.meta.next_page)
    }
    public func contents(_ record: ProviderRecord) async throws -> Data {
        if let data = record.inlineData { return data }
        guard let url = record.source else { throw BridgeError.message("This block has no downloadable file.") }
        try await pace("file_downloads")
        return try await download(url, maximum: 512 * 1024 * 1024)
    }
    public func thumbnail(_ record: ProviderRecord) async throws -> Data? {
        guard let url = record.thumbnail else { return nil }
        try await pace("thumbnail_downloads")
        return try await download(url, maximum: 10 * 1024 * 1024)
    }
    private func download(_ url: URL, maximum: Int) async throws -> Data {
        guard url.scheme == "https" else { throw BridgeError.message("Unsupported download URL.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.message("Are.na’s file could not be downloaded.")
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximum else { throw BridgeError.message("This file exceeds the prototype’s download limit.") }
        return try Data(contentsOf: temporary)
    }
    public func upload(_ file: URL, filename: String) async throws -> URL {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= 100 * 1024 * 1024 else {
            throw BridgeError.message("Drop individual files up to 100 MB into a channel.")
        }
        let mime = UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        try await pace("upload_requests")
        return try await client().upload(Data(contentsOf: file), filename: filename, contentType: mime)
    }
    public func create(source: URL, filename: String, channelID: Int) async throws -> Int {
        try await pace("block_creations")
        return try await client().createBlock(source: source, title: filename, channelID: channelID).id
    }
    public func record(blockID: Int, channelID: Int, parent: String) async throws -> ProviderRecord {
        try await pace("block_status")
        let block = try await client().fullBlock(blockID)
        if block.state == "processing" { throw ProviderFailure.processing }
        guard block.state == "available" else { throw BridgeError.message("Are.na could not process this block. Review it in Are.na; the file will not be uploaded again automatically.") }
        return try ProviderRecord.block(block, channelID: channelID, parent: parent)
    }
}
