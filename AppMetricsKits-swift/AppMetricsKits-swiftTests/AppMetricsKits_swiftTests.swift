import CryptoKit
import Foundation
import XCTest

#if canImport(AppMetricsKit)
@testable import AppMetricsKit
#elseif canImport(AppMetricsKits_swift)
@testable import AppMetricsKits_swift
#endif

final class AppMetricsKitTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testEncodesBackendIngestEnvelopeAndHeaders() async throws {
        let client = AppMetricsClient()
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [200])

        client.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                testMode: true,
                batchSize: 10,
                flushInterval: 0,
                allowedPayloadKeys: ["plan", "source", "trial"],
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )

        let eventId = client.track(
            AppMetricsEvent.paywallViewed,
            payload: ["plan": "annual", "source": "onboarding", "trial": true]
        )
        XCTAssertNotNil(eventId)

        let result = await client.flush()
        XCTAssertEqual(result.delivered, 1)

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer amk_live_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let event = try firstEventJSON()
        XCTAssertEqual(event["eventName"] as? String, AppMetricsEvent.paywallViewed)
        XCTAssertEqual(event["isTestMode"] as? Bool, true)
        XCTAssertEqual(event["platform"] as? String, "macos")
        XCTAssertNotNil(event["sessionId"] as? String)
        XCTAssertNotNil(event["eventId"] as? String)

        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["plan"] as? String, "annual")
        XCTAssertEqual(payload["source"] as? String, "onboarding")
        XCTAssertEqual(payload["trial"] as? Bool, true)
    }

    func testFiltersBlockedUnallowedAndPIIPayloadValues() async throws {
        let client = AppMetricsClient()
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [200])

        client.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                allowedPayloadKeys: ["plan", "email", "phone", "debug"],
                blockedPayloadKeys: ["phone"],
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )

        client.track(
            AppMetricsEvent.purchaseCompleted,
            payload: [
                "plan": "annual",
                "email": "marwan@example.com",
                "phone": "+32 470 12 34 56",
                "debug": true,
                "ignored": "not-allowed",
            ],
            floatValue: 59.99
        )

        let result = await client.flush()
        XCTAssertEqual(result.delivered, 1)

        let event = try firstEventJSON()
        XCTAssertEqual(event["floatValue"] as? Double, 59.99)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["plan"] as? String, "annual")
        XCTAssertEqual(payload["debug"] as? Bool, true)
        XCTAssertNil(payload["email"])
        XCTAssertNil(payload["phone"])
        XCTAssertNil(payload["ignored"])
    }

    func testHashesUserIdOnDevice() async throws {
        let client = AppMetricsClient()
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [200])

        client.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )

        client.identify(userId: "user-123")
        client.track(AppMetricsEvent.featureUsed, payload: ["feature": "export"])
        _ = await client.flush()

        let event = try firstEventJSON()
        XCTAssertEqual(event["anonymousUserId"] as? String, sha256("user-123"))
        XCTAssertNotEqual(event["anonymousUserId"] as? String, "user-123")
    }

    func testRejectsInvalidEventNamesBeforeQueueing() throws {
        let client = AppMetricsClient()
        try client.configureForTests(directory: makeTemporaryDirectory())

        let eventId = client.track("bad event name", payload: ["plan": "annual"])

        XCTAssertNil(eventId)
        XCTAssertEqual(client.pendingEventCount, 0)
    }

    func testPersistsOfflineQueueToDisk() throws {
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [500])

        let firstClient = AppMetricsClient()
        firstClient.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )
        firstClient.track(AppMetricsEvent.paywallViewed, payload: ["plan": "monthly"])
        // Persistence is now coalesced onto a background queue; force it to disk
        // deterministically before reading from a second client.
        firstClient.persistPendingEvents()

        let secondClient = AppMetricsClient()
        secondClient.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )

        XCTAssertEqual(secondClient.pendingEventCount, 1)
    }

    func testPersistPendingEventsIsDurableForMultipleEvents() throws {
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [500])

        let firstClient = AppMetricsClient()
        firstClient.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )
        for index in 0..<5 {
            firstClient.track(AppMetricsEvent.featureUsed, payload: ["screen": .string("s\(index)")])
        }
        firstClient.persistPendingEvents()

        let secondClient = AppMetricsClient()
        secondClient.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )

        XCTAssertEqual(secondClient.pendingEventCount, 5)
    }

    func testBackgroundDebouncedPersistenceWritesToDisk() async throws {
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [500])

        let firstClient = AppMetricsClient()
        firstClient.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )
        firstClient.track(AppMetricsEvent.paywallViewed, payload: ["plan": "monthly"])

        // No explicit persist call: the coalesced background write should land
        // on disk on its own within the debounce window.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let secondClient = AppMetricsClient()
        secondClient.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )

        XCTAssertEqual(secondClient.pendingEventCount, 1)
    }

    func testRetriesRetryableStatusAndKeepsQueueAfterFailures() async throws {
        let client = AppMetricsClient()
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [500, 500, 500])

        client.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )
        client.track(AppMetricsEvent.paywallViewed)

        let result = await client.flush()

        XCTAssertEqual(result.attempted, 1)
        XCTAssertEqual(result.delivered, 0)
        XCTAssertEqual(result.dropped, 0)
        XCTAssertTrue(result.willRetry)
        XCTAssertEqual(client.pendingEventCount, 1)
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
    }

    func testDropsBatchOnNonRetryableStatus() async throws {
        let client = AppMetricsClient()
        let directory = try makeTemporaryDirectory()
        let session = MockURLProtocol.makeSession(statuses: [401])

        client.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: session,
                queueDirectory: directory
            )
        )
        client.track(AppMetricsEvent.paywallViewed)

        let result = await client.flush()

        XCTAssertEqual(result.attempted, 1)
        XCTAssertEqual(result.delivered, 0)
        XCTAssertEqual(result.dropped, 1)
        XCTAssertFalse(result.willRetry)
        XCTAssertEqual(client.pendingEventCount, 0)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmetricskit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func firstEventJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first ?? nil)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        return try XCTUnwrap(events.first)
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension AppMetricsClient {
    func configureForTests(directory: URL) {
        configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://example.com/api/ingest")!,
                ingestKey: "amk_live_test",
                flushInterval: 0,
                automaticAppLaunchTracking: false,
                urlSession: MockURLProtocol.makeSession(statuses: [200]),
                queueDirectory: directory
            )
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statuses: [Int] = []
    private(set) static var requests: [URLRequest] = []
    private(set) static var requestBodies: [Data?] = []

    static func reset() {
        lock.withLock {
            statuses = []
            requests = []
            requestBodies = []
        }
    }

    static func makeSession(statuses: [Int]) -> URLSession {
        lock.withLock {
            Self.statuses = statuses
            Self.requests = []
            Self.requestBodies = []
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let status = Self.lock.withLock { () -> Int in
            Self.requests.append(request)
            Self.requestBodies.append(Self.bodyData(from: request))
            if Self.statuses.isEmpty {
                return 200
            }
            return Self.statuses.removeFirst()
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
