import XCTest
@testable import ArenaCore

final class ArenaCoreTests: XCTestCase {
    func testChannelInputOnlyAcceptsArenaURLsOrSlugs() throws {
        XCTAssertEqual(try ArenaClient.channelSlug("https://www.are.na/walidbehlock/references?sort=desc"), "references")
        XCTAssertEqual(try ArenaClient.channelSlug(" references "), "references")
        for invalid in ["https://evil.example/walid/references", "../me", "https://www.are.na/walidbehlock/channels", "a?token=b", "http://are.na/user/channel"] {
            XCTAssertThrowsError(try ArenaClient.channelSlug(invalid))
        }
    }

    func testContentsRequestsOneHundredItemsWithoutFollowingNextPage() async throws {
        var requests: [URLRequest] = []
        let client = ArenaClient(token: "test", transport: { request in
            requests.append(request)
            let data = Data(#"{"data":[],"meta":{"current_page":1,"next_page":2,"has_more_pages":true}}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let page = try await client.contents(channelID: 99, page: 1)
        XCTAssertEqual(requests.count, 1)
        let url = try XCTUnwrap(requests.first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "per" }?.value, "100")
        XCTAssertEqual(query.first { $0.name == "page" }?.value, "1")
        XCTAssertEqual(page.meta.next_page, 2)
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

    func testUploadPreservesBytesAndKeepsCredentialsOffStorageRequests() async throws {
        var requests: [URLRequest] = []
        let client = ArenaClient(token: "test-secret") { request in
            requests.append(request)
            let json: String
            switch request.url!.path {
            case "/v3/uploads/presign":
                json = #"{"files":[{"upload_url":"https://s3.amazonaws.com/arena_images-temp/uploads/test/file.bin?signature=test","key":"uploads/test/file.bin","content_type":"application/octet-stream"}]}"#
            case "/v3/blocks": json = #"{"id":123,"state":"processing"}"#
            default:
                XCTAssertEqual(request.httpMethod, "PUT")
                json = "{}"
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        let bytes = Data([0, 1, 255, 2])
        let source = try await client.upload(bytes, filename: "file.bin", contentType: "application/octet-stream")
        let block = try await client.createBlock(source: source, title: "file.bin", channelID: 99)
        XCTAssertEqual(block.id, 123)
        XCTAssertEqual(requests.count, 3)
        let upload = requests[1]
        XCTAssertNil(upload.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(upload.httpBody, bytes)
        let create = requests[2]
        XCTAssertEqual(create.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(create.httpBody)) as? [String: Any])
        XCTAssertEqual(body["value"] as? String, "https://s3.amazonaws.com/arena_images-temp/uploads/test/file.bin")
        XCTAssertEqual((body["channels"] as? [[String: Int]])?.first?["id"], 99)
    }

    func testRateLimitRetainsRetryIntervalAndDefiniteRejection() async throws {
        let client = ArenaClient(token: "test") { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "90"])!)
        }
        do { _ = try await client.me(); XCTFail("Expected a rate limit error") }
        catch let error as APIError {
            XCTAssertEqual(error.retryAfter, 90)
            XCTAssertTrue(error.definiteRejection)
        }
    }
}
