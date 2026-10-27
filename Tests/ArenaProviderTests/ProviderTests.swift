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
    func testNestedChannelsBecomeFoldersWithTheirOwnPermissions() throws {
        let block = try JSONDecoder().decode(RemoteBlock.self, from: Data(#"{"id":99,"type":"Channel","title":"Nested","slug":"nested"}"#.utf8))
        let record = try ProviderRecord.block(block, channelID: 1, parent: "channel-1")
        XCTAssertTrue(record.isFolder)
        XCTAssertEqual(record.channelID, 99)
        XCTAssertEqual(record.nestedChannel?.slug, "nested")
        XCTAssertFalse(record.writable)
        XCTAssertNil(record.websiteURL)
        XCTAssertEqual(record.filename, "Nested [99]")
    }
    func testNestedBrowsingIsLazyScopesRepeatedChannelsAndStopsCycles() async throws {
        let backend = GraphBackend()
        let engine = try engine(backend)
        let top = try await engine.list("channel-1")
        let requested1 = await backend.requestedChannels()
        XCTAssertEqual(requested1, [1])
        let second = try XCTUnwrap(top.first { $0.channelID == 2 })
        let directThird = try XCTUnwrap(top.first { $0.channelID == 3 })
        XCTAssertTrue(second.writable)
        XCTAssertFalse(directThird.writable)
        let children = try await engine.list(second.id)
        let cycle = try XCTUnwrap(children.first { $0.channelID == 1 })
        XCTAssertFalse(cycle.isFolder)
        XCTAssertNotNil(cycle.websiteURL)
        let nestedThird = try XCTUnwrap(children.first { $0.isFolder && $0.channelID == 3 })
        XCTAssertNotEqual(nestedThird.id, directThird.id)
        let a = try await engine.list(directThird.id)
        let b = try await engine.list(nestedThird.id)
        XCTAssertTrue(Set(a.map(\.id)).isDisjoint(with: Set(b.map(\.id))))
        XCTAssertTrue(a.allSatisfy { $0.parent == directThird.id })
        XCTAssertTrue(b.allSatisfy { $0.parent == nestedThird.id })
        let pageA = try XCTUnwrap(a.first { $0.isFolder })
        let pageB = try XCTUnwrap(b.first { $0.isFolder })
        let nextA = try await engine.list(pageA.id)
        let nextB = try await engine.list(pageB.id)
        XCTAssertNotEqual(nextA[0].id, nextB[0].id)
        XCTAssertEqual(nextA[0].parent, pageA.id)
        let downloads1 = await backend.downloadCount()
        XCTAssertEqual(downloads1, 0)
    }
    func testRemovingNestedOccurrencePreservesAnotherOccurrenceAndRefreshesParentsFirst() async throws {
        let backend = GraphBackend()
        let configURL = directory.appendingPathComponent("config.json")
        var config = FinderConfiguration(accountID: 1, channels: [DemoProviderBackend.channel])
        try JSONEncoder().encode(config).write(to: configURL)
        let engine = try ProviderEngine(directory: directory.appendingPathComponent("state"), backend: backend) {
            try JSONDecoder().decode(FinderConfiguration.self, from: Data(contentsOf: configURL))
        }
        let top = try await engine.list("channel-1")
        let second = try XCTUnwrap(top.first { $0.channelID == 2 })
        let directThird = try XCTUnwrap(top.first { $0.channelID == 3 })
        let children = try await engine.list(second.id)
        let nestedThird = try XCTUnwrap(children.first { $0.isFolder && $0.channelID == 3 })
        let removed = try await engine.list(nestedThird.id)
        let retained = try await engine.list(directThird.id)
        let anchor = await engine.revision()
        await backend.removeSecond()
        config.refreshGeneration += 1
        try JSONEncoder().encode(config).write(to: configURL)
        try await engine.refreshLoadedPages()
        let changes = try await engine.changes(after: anchor)
        XCTAssertTrue(changes.deleted.contains(second.id))
        XCTAssertTrue(removed.allSatisfy { changes.deleted.contains($0.id) })
        XCTAssertTrue(retained.allSatisfy { !changes.deleted.contains($0.id) })
        let requested2 = await backend.requestedChannels()
        XCTAssertEqual(requested2, [1, 2, 3, 3, 1, 3])
    }
    func testNestedUploadUsesChildChannelAndStableOccurrenceID() async throws {
        let backend = GraphBackend()
        let engine = try engine(backend)
        let top = try await engine.list("channel-1")
        let writable = try XCTUnwrap(top.first { $0.channelID == 2 })
        let readOnly = try XCTUnwrap(top.first { $0.channelID == 3 })
        let input = directory.appendingPathComponent("input.txt")
        try Data("test".utf8).write(to: input)
        let record = try await engine.importFile(requestID: "nested-upload", parent: writable.id, filename: "input.txt", file: input)
        XCTAssertEqual(record.channelID, 2)
        XCTAssertEqual(record.parent, writable.id)
        XCTAssertEqual(record.id, ProviderRecord.scopedID("block-2-101", namespace: writable.namespace))
        do {
            _ = try await engine.importFile(requestID: "read-only", parent: readOnly.id, filename: "input.txt", file: input)
            XCTFail("A parent channel's write permission must not grant access to a nested channel")
        } catch ProviderFailure.readOnly {}
        let created1 = await backend.createdChannels()
        XCTAssertEqual(created1, [2])
    }
    func testUpgradeReplacesLegacyChannelShortcutWithFolder() async throws {
        let state = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let shortcut = ProviderRecord(id: "block-1-2", parent: "channel-1", filename: "Channel 2 [2].webloc", typeIdentifier: "com.apple.web-internet-location", channelID: 1, blockID: 2)
        var snapshot = ProviderEngine.Snapshot()
        snapshot.records = ["channel-1": .channel(DemoProviderBackend.channel), shortcut.id: shortcut]
        snapshot.loadedPages = ["channel-1": [shortcut.id]]
        snapshot.pageGenerations = ["channel-1": 0]
        snapshot.generation = 0
        snapshot.listingPageSize = ArenaClient.channelContentsPageSize
        try JSONEncoder().encode(snapshot).write(to: state.appendingPathComponent("provider-state.json"))
        let engine = try engine(GraphBackend())
        let records = try await engine.list("channel-1")
        XCTAssertTrue(records.allSatisfy(\.isFolder))
        XCTAssertTrue(records.contains { $0.channelID == 2 && $0.id != shortcut.id })
        let changes = try await engine.changes(after: 0)
        XCTAssertTrue(changes.deleted.contains(shortcut.id))
    }
    func testWebsitePreviewQueueDeduplicatesAndPublishesVersionedImages() throws {
        let store = WebsiteThumbnailStore(directory: directory.appendingPathComponent("websites"))
        let url = URL(string: "https://example.com/reference")!
        try store.enqueue(url)
        try store.enqueue(url)
        XCTAssertEqual(try store.pending().count, 1)
        let bytes = Data([1, 2, 3])
        try store.complete(url, png: bytes)
        XCTAssertEqual(store.image(for: url), bytes)
        XCTAssertNotNil(store.result(for: url)?.revision)
        XCTAssertTrue(try store.pending().isEmpty)
        try store.enqueue(url)
        XCTAssertTrue(try store.pending().isEmpty)
        try store.enqueue(url, now: Date().addingTimeInterval(8 * 24 * 3600))
        XCTAssertEqual(try store.pending().count, 1)
    }
    func testWebsitePreviewFailuresBackOffAndRejectCredentials() throws {
        let store = WebsiteThumbnailStore(directory: directory.appendingPathComponent("websites"))
        let url = URL(string: "https://example.com/missing")!
        try store.enqueue(url)
        try store.complete(url, png: nil)
        try store.enqueue(url)
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertNil(store.image(for: url))
        for invalid in ["file:///etc/passwd", "https://user:password@example.com", "javascript:alert(1)"] {
            try store.enqueue(URL(string: invalid)!)
        }
        XCTAssertTrue(try store.pending().isEmpty)
        try store.enqueue(url, now: Date().addingTimeInterval(25 * 3600))
        XCTAssertEqual(try store.pending().count, 1)
    }
    func testLinkPreviewUsesArenaImageAndGeneratedRevisionInvalidatesFinderCache() throws {
        let block = try JSONDecoder().decode(RemoteBlock.self, from: Data(#"{"id":123,"type":"Link","title":"Reference","source":{"url":"https://example.com"},"image":{"small":{"src":"https://images.are.na/preview.jpg"}}}"#.utf8))
        var record = try ProviderRecord.block(block, channelID: 1, parent: "channel-1")
        XCTAssertEqual(record.websiteURL?.absoluteString, "https://example.com")
        XCTAssertEqual(record.thumbnail?.absoluteString, "https://images.are.na/preview.jpg")
        let originalContents = record.inlineData
        let oldVersion = FileProviderItem(record).itemVersion.contentVersion
        record.websiteThumbnailRevision = "generated-image-hash"
        record.websiteThumbnailDate = Date(timeIntervalSince1970: 1234567890)
        XCTAssertNotEqual(FileProviderItem(record).itemVersion.contentVersion, oldVersion)
        XCTAssertEqual(FileProviderItem(record).contentModificationDate, record.websiteThumbnailDate)
        XCTAssertEqual(record.inlineData, originalContents)
        XCTAssertLessThanOrEqual(record.contentVersion.count, 128)
    }
    func testBackgroundPreviewPublishesChangeWithoutDownloadingOriginalOrRefetchingPage() async throws {
        let block = try JSONDecoder().decode(RemoteBlock.self, from: Data(#"{"id":123,"type":"Link","title":"Reference","source":{"url":"https://example.com"}}"#.utf8))
        let record = try ProviderRecord.block(block, channelID: 1, parent: "channel-1")
        let backend = TestBackend()
        await backend.setListedRecord(record)
        let previews = WebsiteThumbnailStore(directory: directory.appendingPathComponent("websites"))
        let engine = try ProviderEngine(directory: directory.appendingPathComponent("state"), backend: backend, websiteThumbnails: previews) {
            FinderConfiguration(accountID: 1, channels: [DemoProviderBackend.channel])
        }
        let listed = try await engine.list("channel-1")
        let anchor = await engine.revision()
        XCTAssertEqual(try previews.pending().count, 1)
        let url = try XCTUnwrap(record.websiteURL)
        let image = Data([1, 2, 3])
        try previews.complete(url, png: image)
        let changes = try await engine.changes(after: anchor)
        let updated = try XCTUnwrap(changes.updated.first { $0.id == record.id })
        XCTAssertNotEqual(updated.contentVersion, listed[0].contentVersion)
        XCTAssertEqual(FileProviderItem(updated).contentModificationDate, previews.result(for: url)?.completedAt)
        let thumbnail = try await engine.thumbnail(record.id)
        XCTAssertEqual(thumbnail, image)
        let counts = await backend.counts()
        XCTAssertEqual(counts.0, [1])
        XCTAssertEqual(counts.1, 0)
        XCTAssertTrue(try previews.pending().isEmpty)
    }
}

private actor TestBackend: ProviderBackend {
    var listedRecord: ProviderRecord?
    func setListedRecord(_ record: ProviderRecord) { listedRecord = record }
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
        if let listedRecord { return ProviderPage(records: [listedRecord], nextPage: nil) }
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

private actor GraphBackend: ProviderBackend {
    var requests: [Int] = []
    var downloads = 0
    var creates: [Int] = []
    var omitSecond = false
    func requestedChannels() -> [Int] { requests }
    func downloadCount() -> Int { downloads }
    func createdChannels() -> [Int] { creates }
    func removeSecond() { omitSecond = true }
    func list(channel: FinderChannel, page: Int, parent: String) async throws -> ProviderPage {
        requests.append(channel.id)
        let children = channel.id == 1 ? (omitSecond ? [3] : [2, 3]) : (channel.id == 2 ? [1, 3] : [])
        let records: [ProviderRecord]
        if children.isEmpty {
            records = [ProviderRecord(id: "block-\(channel.id)-\(page == 1 ? 99 : 100)", parent: parent, filename: "Example.txt", typeIdentifier: "public.plain-text", channelID: channel.id, blockID: page == 1 ? 99 : 100)]
        } else {
            records = try children.map { id in
                let bytes = try JSONSerialization.data(withJSONObject: ["id": id, "type": "Channel", "title": "Channel \(id)", "slug": "channel-\(id)", "can": ["add_to": id == 2]])
                let block = try JSONDecoder().decode(RemoteBlock.self, from: bytes)
                return try ProviderRecord.block(block, channelID: channel.id, parent: parent)
            }
        }
        return ProviderPage(records: records, nextPage: channel.id == 3 && page == 1 ? 2 : nil)
    }
    func contents(_ record: ProviderRecord) async throws -> Data { downloads += 1; return Data() }
    func thumbnail(_ record: ProviderRecord) async throws -> Data? { nil }
    func upload(_ file: URL, filename: String) async throws -> URL { URL(string: "https://example.com/file")! }
    func create(source: URL, filename: String, channelID: Int) async throws -> Int { creates.append(channelID); return 101 }
    func record(blockID: Int, channelID: Int, parent: String) async throws -> ProviderRecord {
        ProviderRecord(id: "block-\(channelID)-\(blockID)", parent: parent, filename: "input.txt", typeIdentifier: "public.plain-text", channelID: channelID, blockID: blockID)
    }
}
