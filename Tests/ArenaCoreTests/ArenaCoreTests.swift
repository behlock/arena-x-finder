import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ArenaCore

final class ArenaCoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func image() throws -> URL {
        let url = directory.appendingPathComponent("reference 日本.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return url
    }
    @MainActor private func queued() async throws -> (Store, Job) {
        let store = try Store(directory: directory.appendingPathComponent("data"))
        try store.setAccount(42)
        let destination = Destination(channelID: 99, name: "References", slug: "references")
        try store.save(destination)
        let result = try await store.enqueue([image()], destination: destination)
        return (store, result.job)
    }

    func testChannelInputOnlyAcceptsArenaURLsOrSlugs() throws {
        XCTAssertEqual(try ArenaClient.channelSlug("https://www.are.na/walidbehlock/references?sort=desc"), "references")
        XCTAssertEqual(try ArenaClient.channelSlug(" references "), "references")
        for invalid in ["https://evil.example/walid/references", "../me", "https://www.are.na/walidbehlock/channels", "a?token=b", "http://are.na/user/channel"] {
            XCTAssertThrowsError(try ArenaClient.channelSlug(invalid))
        }
    }

    @MainActor func testQueueSurvivesRestartAndDeletingOriginal() async throws {
        let (store, job) = try await queued()
        let original = directory.appendingPathComponent("reference 日本.png")
        let bytes = try Data(contentsOf: original)
        try FileManager.default.removeItem(at: original)
        let reopened = try Store(directory: store.directory)
        XCTAssertEqual(reopened.jobs.first?.accountID, 42)
        XCTAssertEqual(reopened.lastDestinationID, "99")
        XCTAssertEqual(try reopened.imageData(jobID: job.id, image: job.images[0]), bytes)
        XCTAssertThrowsError(try reopened.setAccount(100))
        let state = try String(contentsOf: store.directory.appendingPathComponent("state.json"))
        XCTAssertFalse(state.contains("token"))
    }

    @MainActor func testUploadSendsBytesWithoutLeakingTokenAndUsesStructuredChannel() async throws {
        let (store, job) = try await queued()
        let mock = MockAPI()
        let client = ArenaClient(token: "test-secret", transport: mock.send)
        let uploader = Uploader(store: store)
        await uploader.run(client: client, accountID: 42)
        XCTAssertTrue(store.jobs.isEmpty, uploader.status)
        XCTAssertEqual(mock.requests.count, 4)
        let upload = try XCTUnwrap(mock.requests.first { $0.httpMethod == "PUT" })
        XCTAssertNil(upload.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(upload.httpBody, try Data(contentsOf: directory.appendingPathComponent("reference 日本.png")))
        let create = try XCTUnwrap(mock.requests.first { $0.url?.path == "/v3/blocks" })
        XCTAssertEqual(create.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(create.httpBody)) as? [String: Any])
        XCTAssertEqual(body["value"] as? String, "https://s3.amazonaws.com/arena_images-temp/uploads/test/image.png")
        XCTAssertEqual((body["channels"] as? [[String: Int]])?.first?["id"], 99)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("queue/" + job.id).path))
    }

    @MainActor func testLostCreateResponseRequiresReviewAndNeverAutomaticallyReposts() async throws {
        let (store, job) = try await queued()
        let mock = MockAPI(); mock.loseCreateResponse = true
        let client = ArenaClient(token: "test", transport: mock.send)
        await Uploader(store: store).run(client: client, accountID: 42)
        let reopened = try Store(directory: store.directory)
        XCTAssertTrue(try XCTUnwrap(reopened.jobs.first).creating.contains(job.images[0].id))
        let before = mock.requests.count
        await Uploader(store: reopened).run(client: client, accountID: 42)
        XCTAssertEqual(mock.requests.count, before)
        XCTAssertEqual(mock.requests.filter { $0.url?.path == "/v3/blocks" }.count, 1)
    }

    @MainActor func testRateLimitAllowsExplicitRetryWithoutAmbiguousFlag() async throws {
        let (store, job) = try await queued()
        let mock = MockAPI(); mock.createStatus = 429
        let uploader = Uploader(store: store)
        await uploader.run(client: ArenaClient(token: "test", transport: mock.send), accountID: 42)
        XCTAssertFalse(try XCTUnwrap(store.jobs.first).creating.contains(job.images[0].id))
        XCTAssertTrue(uploader.status.contains("90 seconds"))
        XCTAssertEqual(mock.requests.filter { $0.url?.path == "/v3/blocks" }.count, 1)
    }

    @MainActor func testKnownBlockResumesWithoutUploadingAgain() async throws {
        let (store, job) = try await queued()
        try store.updateJob(job.id) { $0.blockIDs[job.images[0].id] = 123 }
        let reopened = try Store(directory: store.directory)
        let mock = MockAPI()
        await Uploader(store: reopened).run(client: ArenaClient(token: "test", transport: mock.send), accountID: 42)
        XCTAssertTrue(reopened.jobs.isEmpty)
        XCTAssertEqual(mock.requests.map { $0.url!.path }, ["/v3/blocks/123"])
    }

    @MainActor func testWrongAccountCannotSendQueuedImages() async throws {
        let (store, _) = try await queued()
        let mock = MockAPI()
        await Uploader(store: store).run(client: ArenaClient(token: "test", transport: mock.send), accountID: 43)
        XCTAssertTrue(mock.requests.isEmpty)
        XCTAssertEqual(store.jobs.count, 1)
    }

    @MainActor func testPartialBatchResumesOnlyUnfinishedImages() async throws {
        let (store, firstJob) = try await queued()
        try store.discard(jobID: firstJob.id)
        let original = try image()
        let job = try await store.enqueue([original, original], destination: store.destinations[0]).job
        try store.acknowledge(jobID: job.id, imageID: job.images[0].id)
        let mock = MockAPI()
        await Uploader(store: store).run(client: ArenaClient(token: "test", transport: mock.send), accountID: 42)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(mock.requests.filter { $0.url?.path == "/v3/blocks" }.count, 1)
    }

    func testChannelPaginationUsesOnePageAndDecodesPermissions() async throws {
        var requests: [URLRequest] = []
        let client = ArenaClient(token: "test") { request in
            requests.append(request)
            let json = #"{"data":[{"id":99,"title":"Private references","slug":"references","can":{"add_to":true}}],"meta":{"next_page":3}}"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let page = try await client.channels(userID: 42, page: 2)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("page=2"))
        XCTAssertEqual(page.meta.next_page, 3)
        XCTAssertEqual(page.data[0].can?.add_to, true)
    }

    func testUnexpectedUploadHostIsRejectedBeforeSendingBytes() async throws {
        var count = 0
        let client = ArenaClient(token: "test") { request in
            count += 1
            return (Data(#"{"files":[{"upload_url":"https://evil.example/upload","key":"uploads/test.png","content_type":"image/png"}]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await client.upload(Data([1, 2, 3]), filename: "image.png", contentType: "image/png")
            XCTFail("Unexpected destination should fail")
        } catch { XCTAssertEqual(count, 1) }
    }
}

private final class MockAPI {
    var requests: [URLRequest] = []
    var loseCreateResponse = false
    var createStatus = 201
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        var json = "{}"
        var status = 200
        if path == "/v3/uploads/presign" {
            json = #"{"files":[{"upload_url":"https://s3.amazonaws.com/arena_images-temp/uploads/test/image.png?signature=test","key":"uploads/test/image.png","content_type":"image/png"}],"expires_in":3600}"#
            status = 201
        } else if path == "/v3/blocks" {
            if loseCreateResponse { throw URLError(.timedOut) }
            status = createStatus; json = #"{"id":123,"state":"processing"}"#
        } else if path == "/v3/blocks/123" { json = #"{"id":123,"state":"available"}"# }
        else if request.httpMethod != "PUT" { XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)") }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "90"])!)
    }
}
