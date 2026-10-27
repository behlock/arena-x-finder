import Foundation
import UniformTypeIdentifiers
import ArenaCore

public actor DemoProviderBackend: ProviderBackend {
    public static let channel = FinderChannel(id: 1, title: "Demo channel", slug: "demo", writable: true)
    private let directory: URL
    private var records: [ProviderRecord]
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = directory.appendingPathComponent("demo-records.json")
        if let data = try? Data(contentsOf: state) { records = try JSONDecoder().decode([ProviderRecord].self, from: data) }
        else {
            let data = Data("This is a local Finder integration test. No Are.na content was accessed.\n".utf8)
            records = [ProviderRecord(id: "block-1-1", parent: "channel-1", filename: "Welcome.txt", typeIdentifier: UTType.plainText.identifier,
                                      channelID: 1, blockID: 1, inlineData: data, size: Int64(data.count))]
            try JSONEncoder().encode(records).write(to: state, options: .atomic)
        }
    }
    public func list(channel: FinderChannel, page: Int, parent: String) async throws -> ProviderPage {
        ProviderPage(records: records, nextPage: nil)
    }
    public func contents(_ record: ProviderRecord) async throws -> Data {
        let result: [String: String]
        do {
            let value = try CredentialVault.read(service: "com.behlock.arena-x-finder.smoke", interactive: false)
            result = ["sharedKeychainReadable": value == "local-smoke-value" ? "true" : "false"]
        } catch { result = ["sharedKeychainReadable": "false", "error": error.localizedDescription] }
        try JSONEncoder().encode(result).write(to: directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("provider-smoke.json"), options: .atomic)
        if let data = record.inlineData { return data }
        guard let source = record.source else { throw ProviderFailure.missing }
        return try Data(contentsOf: source)
    }
    public func thumbnail(_ record: ProviderRecord) async throws -> Data? { nil }
    public func upload(_ file: URL, filename: String) async throws -> URL {
        let target = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }
    public func create(source: URL, filename: String, channelID: Int) async throws -> Int {
        let id = (records.compactMap(\.blockID).max() ?? 1) + 1
        let record = ProviderRecord(id: "block-1-\(id)", parent: "channel-1", filename: ProviderRecord.cleanName(filename),
                                    typeIdentifier: UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier ?? UTType.data.identifier,
                                    channelID: 1, blockID: id, source: source, size: Int64(try Data(contentsOf: source).count))
        records.append(record)
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("demo-records.json"), options: .atomic)
        return id
    }
    public func record(blockID: Int, channelID: Int, parent: String) async throws -> ProviderRecord {
        guard let record = records.first(where: { $0.blockID == blockID }) else { throw ProviderFailure.missing }
        return record
    }
}
