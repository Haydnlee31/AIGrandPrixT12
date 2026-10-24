import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import CommonThreadKit

final class SharedSyncTests: XCTestCase {
    private let origin = URL(string: "https://api.example.org")!
    private var directory: URL!
    private let request = CaptureRequest(url: "https://example.org/lamp", title: "Lamp", note: "Brass", client: .iosShareExtension)
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory); MockURLProtocol.handler = nil }
    private func client() throws -> CommonThreadClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        return try CommonThreadClient(baseURL: origin, session: URLSession(configuration: configuration)) { "test-token" }
    }
    private func account(_ user: String = "alice") -> Data {
        Data("{\"user_id\":\"\(user)\",\"demo_mode\":true,\"inference_provider\":\"test\"}".utf8)
    }
    private var receipt: Data { Data(#"{"id":"remote-lamp","status":"pending","duplicate":false}"#.utf8) }

    func testLostResponseReplaysExactPayloadAndKeyAfterRestart() async throws {
        let outbox = CaptureOutbox(directory: directory)
        let draft = PendingCapture(request: request, accountId: "alice", baseURL: origin, sourceId: "local-photo")
        try await outbox.enqueue(draft)
        var attempts: [URLRequest] = []
        let account = account(), receipt = receipt
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/me" { return (200, account, [:]) }
            attempts.append(request)
            if attempts.count == 1 { throw URLError(.networkConnectionLost) }
            return (201, receipt, [:])
        }
        let api = try client()
        let failed = try await outbox.sync(using: api, accountId: "alice", baseURL: origin)
        XCTAssertEqual(failed.errors.count, 1)
        let reopened = CaptureOutbox(directory: directory)
        let succeeded = try await reopened.sync(using: api, accountId: "alice", baseURL: origin)
        XCTAssertTrue(succeeded.errors.isEmpty)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].httpBody, attempts[1].httpBody)
        XCTAssertEqual(attempts[0].value(forHTTPHeaderField: "Idempotency-Key"), attempts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        let pending = try await reopened.pending(accountId: "alice", baseURL: origin)
        XCTAssertTrue(pending.isEmpty)
        // A late inbox acknowledgement or later manual reimport cannot resurrect it.
        try await reopened.enqueue(draft)
        let reimported = try await reopened.enqueueImport(request: request, sourceId: "local-photo", accountId: "alice", baseURL: origin)
        XCTAssertFalse(reimported)
        let after = try await reopened.pending(accountId: "alice", baseURL: origin)
        XCTAssertTrue(after.isEmpty)
    }
    func testImportsAndReceiptsAreScopedToAccountAndOrigin() async throws {
        let outbox = CaptureOutbox(directory: directory)
        let first = try await outbox.enqueueImport(request: request, sourceId: "photo", accountId: "alice", baseURL: origin)
        let again = try await outbox.enqueueImport(request: CaptureRequest(title: "Changed"), sourceId: "photo", accountId: "alice", baseURL: origin)
        XCTAssertTrue(first); XCTAssertFalse(again)
        let queued = try await outbox.pending(accountId: "alice", baseURL: origin)
        XCTAssertEqual(queued.first?.request, request)
        let second = try await outbox.enqueueImport(request: request, sourceId: "photo", accountId: "bob", baseURL: origin)
        let otherServer = try await outbox.enqueueImport(request: request, sourceId: "photo", accountId: "alice", baseURL: URL(string: "https://other.example.org")!)
        XCTAssertTrue(second); XCTAssertTrue(otherServer)
        try await outbox.complete(queued[0], receipt: CommonThreadClient.decoder().decode(CaptureReceipt.self, from: receipt))
        let bob = try await outbox.pending(accountId: "bob", baseURL: origin)
        XCTAssertEqual(bob.count, 1)
    }
    func testPermanentRejectionsWaitForExplicitRetryAcrossRestart() async throws {
        let outbox = CaptureOutbox(directory: directory)
        let draft = PendingCapture(request: request, accountId: "alice", baseURL: origin)
        try await outbox.enqueue(draft)
        let account = account(), receipt = receipt
        var captures = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/me" { return (200, account, [:]) }
            captures += 1
            if captures == 1 { return (422, Data(#"{"error":{"code":"bad_capture","message":"Edit this request","retryable":false}}"#.utf8), [:]) }
            return (201, receipt, [:])
        }
        let api = try client()
        _ = try await outbox.sync(using: api, accountId: "alice", baseURL: origin)
        let reopened = CaptureOutbox(directory: directory)
        let paused = try await reopened.sync(using: api, accountId: "alice", baseURL: origin)
        XCTAssertEqual(captures, 1); XCTAssertEqual(paused.errors[draft.id], "Edit this request")
        _ = try await reopened.sync(using: api, accountId: "alice", baseURL: origin, retryRejected: true)
        XCTAssertEqual(captures, 2)
        let pending = try await reopened.pending(accountId: "alice", baseURL: origin)
        XCTAssertTrue(pending.isEmpty)
    }
    func testWrongAccountNeverUploadsAndUnauthorizedNeverDropsDraft() async throws {
        let outbox = CaptureOutbox(directory: directory)
        let draft = PendingCapture(request: request, accountId: "alice", baseURL: origin)
        try await outbox.enqueue(draft)
        let wrongAccount = account("bob")
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/me")
            return (200, wrongAccount, [:])
        }
        let api = try client()
        do { _ = try await outbox.sync(using: api, accountId: "alice", baseURL: origin); XCTFail("Wrong account must stop") }
        catch CaptureOutbox.SyncError.accountChanged {}
        let account = account()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/me" { return (200, account, [:]) }
            return (401, Data(#"{"error":{"code":"unauthorized","message":"Reconnect","retryable":false}}"#.utf8), [:])
        }
        _ = try await outbox.sync(using: api, accountId: "alice", baseURL: origin)
        let pending = try await outbox.pending(accountId: "alice", baseURL: origin)
        let rejection = try await outbox.rejection(draft)
        XCTAssertEqual(pending.count, 1); XCTAssertNil(rejection)
    }
    func testLegacyDraftWithoutProvenanceDecodes() throws {
        let draft = PendingCapture(request: request, accountId: "alice", baseURL: origin)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
        object.removeValue(forKey: "sourceId")
        let decoded = try JSONDecoder().decode(PendingCapture.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sourceId); XCTAssertEqual(decoded.key, draft.key)
    }
    func testUnsupportedAndOversizedNotesNeverSilentlyDropContent() throws {
        XCTAssertThrowsError(try SharedCaptureRequest.prepare(url: nil, title: "Text", text: "Keep me", note: "", client: .iosApp))
        XCTAssertThrowsError(try SharedCaptureRequest.prepare(url: "https://example.org", title: "File", text: "", note: "", client: .iosApp,
            attachments: [.init(data: Data([1]), isImage: false)]))
        XCTAssertThrowsError(try SharedCaptureRequest.prepare(url: nil, title: "Photos", text: "", note: "", client: .iosApp,
            attachments: [.init(data: Data([1]), isImage: true), .init(data: Data([2]), isImage: true)]))
        XCTAssertThrowsError(try SharedCaptureRequest.prepare(url: "https://example.org", title: "Notes", text: "", note: String(repeating: "x", count: 1999), intents: ["keep this intent"], client: .iosApp))
        let prepared = try SharedCaptureRequest.prepare(url: "https://example.org", title: "Lamp", text: "Details", note: "Brass", intents: ["Warm light"], client: .iosShareExtension)
        XCTAssertEqual(prepared.note, "Brass\nWarm light"); XCTAssertEqual(prepared.selectedText, "Details")
    }
    func testPhotoRespectsServerLimitAndLeavesOriginalUntouched() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1800, height: 1800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1800))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = data as Data, copy = original
        let url = try SharedCaptureRequest.imageDataURL(original, maximumBytes: 6000)
        let encoded = try XCTUnwrap(Data(base64Encoded: String(url.split(separator: ",", maxSplits: 1)[1])))
        XCTAssertLessThanOrEqual(encoded.count, 6000); XCTAssertEqual(original, copy)
        XCTAssertNotNil(CGImageSourceCreateWithData(encoded as CFData, nil))
        XCTAssertThrowsError(try SharedCaptureRequest.imageDataURL(original, maximumBytes: 1))
        XCTAssertThrowsError(try SharedCaptureRequest.imageDataURL(Data([1, 2]), maximumBytes: 6000))
    }
}
