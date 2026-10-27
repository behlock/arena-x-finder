import XCTest
@testable import ArenaCore

final class StoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCatalogPersistsUpdatesAndSelectionWithoutDuplicates() throws {
        let store = try Store(directory: directory)
        try store.setAccount(42)
        try store.save(Destination(channelID: 99, name: "Original", slug: "reference"))
        try store.save(Destination(channelID: 99, name: "Renamed", slug: "reference"))
        try store.select("99")
        let reopened = try Store(directory: directory)
        XCTAssertEqual(reopened.destinations.count, 1)
        XCTAssertEqual(reopened.destinations[0].name, "Renamed")
        XCTAssertEqual(reopened.lastDestinationID, "99")
        try reopened.setAccount(42)
        XCTAssertEqual(reopened.destinations.count, 1)
        try reopened.setAccount(43)
        XCTAssertTrue(reopened.destinations.isEmpty)
        XCTAssertNil(reopened.lastDestinationID)
    }

    func testMigrationPreservesRetiredQueueAndUsesNewCatalogAfterwards() throws {
        let legacy = directory.appendingPathComponent("state.json")
        let bytes = Data(#"{"accountID":42,"destinations":[{"channelID":99,"name":"Reference","slug":"reference"}],"lastDestinationID":"99","jobs":[{"legacy":"keep untouched"}]}"#.utf8)
        try bytes.write(to: legacy)
        let queued = directory.appendingPathComponent("queue")
        try FileManager.default.createDirectory(at: queued, withIntermediateDirectories: true)
        let original = queued.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: original)
        let store = try Store(directory: directory)
        XCTAssertEqual(store.destinations.count, 1)
        XCTAssertEqual(store.lastDestinationID, "99")
        try store.save(Destination(channelID: 100, name: "New", slug: "new"))
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
        XCTAssertEqual(try Store(directory: directory).destinations.count, 2)
        let catalog = try String(contentsOf: directory.appendingPathComponent("channels.json"))
        XCTAssertFalse(catalog.contains("jobs"))
    }

    func testInvalidChannelDoesNotChangeCatalog() throws {
        let store = try Store(directory: directory)
        for destination in [Destination(channelID: 0, name: "Test", slug: "test"),
                            Destination(channelID: 1, name: "", slug: "test"),
                            Destination(channelID: 1, name: "Test", slug: "../bad")] {
            XCTAssertThrowsError(try store.save(destination))
        }
        XCTAssertTrue(store.destinations.isEmpty)
    }
}
