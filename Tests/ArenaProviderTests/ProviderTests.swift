import XCTest
import FileProvider
import ArenaCore
@testable import ArenaProvider

final class ProviderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func engine(_ backend: any ProviderBackend) throws -> ProviderEngine {
        try ProviderEngine(directory: directory.appendingPathComponent("state"), backend: backend) {
            FinderConfiguration(accountID: 1, channels: [DemoProviderBackend.channel])
        }
    }
    func testListingFolderDoesNotDownloadContentOrFollowNextPage() async throws {
        let backend = TestBackend()
        let engine = try engine(backend)
        let root = try await engine.list("root")
        XCTAssertEqual(root.count, 1)
        let items = try await engine.list(root[0].id)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.filename == "More items (page 2)" })
        _ = try await engine.list(root[0].id)
        _ = try await engine.list("working")
        let counts = await backend.counts()
        XCTAssertEqual(counts.0, [1]); XCTAssertEqual(counts.1, 0)
        _ = try await engine.list("page-1-2")
        let nextCounts = await backend.counts()
        XCTAssertEqual(nextCounts.0, [1, 2])
    }
    func testReadMaterializesOnlyRequestedFile() async throws {
        let backend = TestBackend()
        let engine = try engine(backend)
        _ = try await engine.list("channel-1")
        let (_, data) = try await engine.contents("block-1-1")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
        let counts = await backend.counts()
        XCTAssertEqual(counts.1, 1)
    }
    func testPageSizeUpgradeMovesCachedChildrenBeforeRemovingOldPageFolder() async throws {
        let backend = TestBackend()
        let first = try engine(backend)
        _ = try await first.list("channel-1")
        _ = try await first.list("page-1-2")
        let anchor = await first.revision()
        // Simulate the pre-upgrade snapshot, which had no page-size field.
        let stateURL = directory.appendingPathComponent("state/provider-state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        state.removeValue(forKey: "listingPageSize")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        await backend.flattenListing()
        let upgraded = try engine(backend)
        try await upgraded.refreshLoadedPages()
        let records = try await upgraded.list("channel-1")
        XCTAssertEqual(Set(records.map(\.id)), Set(["block-1-1", "block-1-2"]))
        XCTAssertTrue(records.allSatisfy { $0.parent == "channel-1" })
        let changes = try await upgraded.changes(after: anchor)
        XCTAssertEqual(changes.deleted, ["page-1-2"])
        let working = try await upgraded.list("working")
        XCTAssertFalse(working.contains { $0.id == "page-1-2" || $0.parent == "page-1-2" })
        let counts = await backend.counts()
        XCTAssertEqual(counts.0, [1, 2, 1])
        XCTAssertEqual(counts.1, 0)
    }
    func testWorkingSetRefreshRevisitsOnlyPreviouslyOpenedPages() async throws {
        let backend = TestBackend()
        let configURL = directory.appendingPathComponent("config.json")
        var config = FinderConfiguration(accountID: 1, channels: [DemoProviderBackend.channel])
        try JSONEncoder().encode(config).write(to: configURL)
        let engine = try ProviderEngine(directory: directory.appendingPathComponent("state"), backend: backend) {
            try JSONDecoder().decode(FinderConfiguration.self, from: Data(contentsOf: configURL))
        }
        _ = try await engine.list("channel-1")
        try await engine.refreshLoadedPages()
        var counts = await backend.counts()
        XCTAssertEqual(counts.0, [1])
        config.refreshGeneration += 1
        try JSONEncoder().encode(config).write(to: configURL)
        try await engine.refreshLoadedPages()
        counts = await backend.counts()
        XCTAssertEqual(counts.0, [1, 1])
        XCTAssertEqual(counts.1, 0)
    }
    func testImportReplayAcrossRestartCreatesOnlyOneRemoteBlock() async throws {
        let backend = try DemoProviderBackend(directory: directory.appendingPathComponent("remote"))
        let firstEngine = try engine(backend)
        let input = directory.appendingPathComponent("Dropped file.txt")
        try Data("dropped through Finder".utf8).write(to: input)
        let first = try await firstEngine.importFile(requestID: "request-1", parent: "channel-1", filename: "Dropped file.txt", file: input)
        let restarted = try engine(backend)
        let replay = try await restarted.importFile(requestID: "request-1", parent: "channel-1", filename: "Dropped file.txt", file: nil)
        XCTAssertEqual(first.id, replay.id)
        let items = try await restarted.list("channel-1")
        XCTAssertEqual(items.count, 2)
        let (_, bytes) = try await restarted.contents(first.id)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "dropped through Finder")
    }
    func testAmbiguousCreateSurvivesRestartAndDoesNotRepeat() async throws {
        let backend = TestBackend(); await backend.failCreate()
        let first = try engine(backend)
        let input = directory.appendingPathComponent("image.png"); try Data([1]).write(to: input)
        do { _ = try await first.importFile(requestID: "abc", parent: "channel-1", filename: "image.png", file: input); XCTFail() }
        catch {}
        let reopened = try engine(backend)
        do { _ = try await reopened.importFile(requestID: "abc", parent: "channel-1", filename: "image.png", file: input); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("unknown")) }
        let creates = await backend.creates
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(try ProviderEngine.interruptedUploads(in: directory.appendingPathComponent("state")).count, 1)
    }
    func testPrivateChannelCapabilitiesPermitAddingButNotDeleting() {
        let channel = FileProviderItem(.channel(DemoProviderBackend.channel))
        XCTAssertTrue(channel.capabilities.contains(.allowsAddingSubItems))
        XCTAssertFalse(channel.capabilities.contains(.allowsDeleting))
        let file = FileProviderItem(ProviderRecord(id: "file", parent: "channel-1", filename: "a.png", typeIdentifier: "public.png"))
        XCTAssertTrue(file.capabilities.contains(.allowsReading))
        XCTAssertFalse(file.capabilities.contains(.allowsWriting))
    }
    func testExplicitResolutionLinksExistingBlockWithoutRepeatingCreate() async throws {
        let backend = TestBackend(); await backend.failCreate()
        let first = try engine(backend)
        let input = directory.appendingPathComponent("image.png"); try Data([1]).write(to: input)
        do { _ = try await first.importFile(requestID: "resolve-me", parent: "channel-1", filename: "image.png", file: input); XCTFail() }
        catch {}
        let state = directory.appendingPathComponent("state")
        try JSONEncoder().encode(ImportResolution(blockID: 42)).write(to: state.appendingPathComponent("resolution-" + ProviderEngine.key("resolve-me") + ".json"))
        let reopened = try engine(backend)
        let record = try await reopened.importFile(requestID: "resolve-me", parent: "channel-1", filename: "image.png", file: nil)
        XCTAssertEqual(record.blockID, 42)
        let creates = await backend.creates
        XCTAssertEqual(creates, 1)
        XCTAssertTrue(try ProviderEngine.interruptedUploads(in: state).isEmpty)
    }
    func testRefreshRemovesStaleItemsAndScopesDeletionToTheirFolder() async throws {
        let backend = TestBackend()
        let configURL = directory.appendingPathComponent("config.json")
        var config = FinderConfiguration(accountID: 1, channels: [DemoProviderBackend.channel])
        try JSONEncoder().encode(config).write(to: configURL)
        let engine = try ProviderEngine(directory: directory.appendingPathComponent("state"), backend: backend) {
            try JSONDecoder().decode(FinderConfiguration.self, from: Data(contentsOf: configURL))
        }
        _ = try await engine.list("channel-1")
        let anchor = await engine.revision()
        await backend.emptyListing()
        config.refreshGeneration += 1
        try JSONEncoder().encode(config).write(to: configURL)
        let refreshed = try await engine.list("channel-1")
        XCTAssertTrue(refreshed.isEmpty)
        let changes = try await engine.changes(after: anchor, parent: "channel-1")
        XCTAssertEqual(Set(changes.deleted), Set(["block-1-1", "page-1-2"]))
        let otherFolder = try await engine.changes(after: anchor, parent: "channel-2")
        XCTAssertTrue(otherFolder.deleted.isEmpty)
    }
    func testNamesRemainSafeAndDuplicateTitlesGetStableIDs() throws {
        let json = #"{"id":123,"type":"Image","title":"../../same:image","updated_at":"v1","image":{"src":"https://example.com/image.png","content_type":"image/png","filename":"image.png"}}"#
        let block = try JSONDecoder().decode(RemoteBlock.self, from: Data(json.utf8))
        let record = try ProviderRecord.block(block, channelID: 1, parent: "channel-1")
        XCTAssertFalse(record.filename.contains("/"))
        XCTAssertFalse(record.filename.contains(":"))
        XCTAssertFalse(record.filename.hasPrefix("."))
        XCTAssertTrue(record.filename.hasSuffix("[123].png"))
        XCTAssertEqual(record.id, "block-1-123")
    }
    func testNestedChannelsBecomeLinksInsteadOfRecursiveFolders() throws {
        let block = try JSONDecoder().decode(RemoteBlock.self, from: Data(#"{"id":99,"type":"Channel","title":"Nested","slug":"nested"}"#.utf8))
        let record = try ProviderRecord.block(block, channelID: 1, parent: "channel-1")
        XCTAssertFalse(record.isFolder)
        XCTAssertTrue(record.filename.hasSuffix(".webloc"))
    }
}

private actor TestBackend: ProviderBackend {
    var pages: [Int] = []
    var downloads = 0
    var creates = 0
    var fail = false
    var empty = false
    var flattened = false
    func flattenListing() { flattened = true }
    func failCreate() { fail = true }
    func emptyListing() { empty = true }
    func counts() -> ([Int], Int) { (pages, downloads) }
    func list(channel: FinderChannel, page: Int, parent: String) async throws -> ProviderPage {
        pages.append(page)
        if empty { return ProviderPage(records: [], nextPage: nil) }
        if flattened {
            return ProviderPage(records: (1...2).map { (id: Int) in
                ProviderRecord(id: "block-1-\(id)", parent: parent, filename: "Example \(id).txt", typeIdentifier: "public.plain-text", channelID: 1, blockID: id)
            }, nextPage: nil)
        }
        return ProviderPage(records: [ProviderRecord(id: "block-1-\(page)", parent: parent, filename: "Example.txt", typeIdentifier: "public.plain-text", channelID: 1, blockID: page)], nextPage: page == 1 ? 2 : nil)
    }
    func contents(_ record: ProviderRecord) async throws -> Data { downloads += 1; return Data("hello".utf8) }
    func thumbnail(_ record: ProviderRecord) async throws -> Data? { nil }
    func upload(_ file: URL, filename: String) async throws -> URL { URL(string: "https://example.com/file")! }
    func create(source: URL, filename: String, channelID: Int) async throws -> Int {
        creates += 1
        if fail { throw URLError(.timedOut) }
        return 10
    }
    func record(blockID: Int, channelID: Int, parent: String) async throws -> ProviderRecord {
        ProviderRecord(id: "block-1-\(blockID)", parent: parent, filename: "New.txt", typeIdentifier: "public.plain-text", channelID: 1, blockID: blockID)
    }
}
