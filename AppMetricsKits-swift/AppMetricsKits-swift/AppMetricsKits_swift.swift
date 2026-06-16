import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A primitive analytics payload value accepted by AppMetricsKit ingest.
///
/// Payloads are intentionally flat: strings, numbers, and booleans only. Nested
/// objects and arrays are rejected by the backend and are not represented here.
public enum AppMetricsValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}

extension AppMetricsValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AppMetricsValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension AppMetricsValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension AppMetricsValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

public typealias AppMetricsPayload = [String: AppMetricsValue]

/// Common first-party event names that power AppMetricsKit dashboards.
public enum AppMetricsEvent {
    public static let appLaunch = "App.launch"
    public static let onboardingStarted = "Onboarding.started"
    public static let onboardingStepViewed = "Onboarding.stepViewed"
    public static let onboardingCompleted = "Onboarding.completed"
    public static let paywallViewed = "Paywall.viewed"
    public static let paywallCTATapped = "Paywall.ctaTapped"
    public static let purchaseStarted = "Purchase.started"
    public static let purchaseCompleted = "Purchase.completed"
    public static let purchaseFailed = "Purchase.failed"
    public static let subscriptionTrialStarted = "Subscription.trialStarted"
    public static let subscriptionTrialConverted = "Subscription.trialConverted"
    public static let subscriptionRenewed = "Subscription.renewed"
    public static let subscriptionCancelled = "Subscription.cancelled"
    public static let subscriptionRefunded = "Subscription.refunded"
    public static let subscriptionBillingRetry = "Subscription.billingRetry"
    public static let subscriptionGracePeriod = "Subscription.gracePeriod"
    public static let featureUsed = "Feature.used"
    public static let errorOccurred = "Error.occurred"
}

/// Configuration for the AppMetricsKit SDK.
public struct AppMetricsConfiguration {
    public static let maxBackendBatchSize = 500
    public static let defaultBlockedPayloadKeys: Set<String> = [
        "adid",
        "advertisingid",
        "advertisingidentifier",
        "address",
        "deviceid",
        "devicetoken",
        "email",
        "firstname",
        "idfa",
        "ip",
        "ipaddress",
        "lastname",
        "latitude",
        "location",
        "longitude",
        "name",
        "phone",
    ]

    public var ingestURL: URL
    public var ingestKey: String
    public var testMode: Bool
    public var batchSize: Int
    public var flushInterval: TimeInterval
    public var maxQueueSize: Int
    public var allowedPayloadKeys: Set<String>?
    public var blockedPayloadKeys: Set<String>
    public var automaticAppLaunchTracking: Bool
    public var urlSession: URLSession
    public var queueDirectory: URL?

    public init(
        ingestURL: URL,
        ingestKey: String,
        testMode: Bool = false,
        batchSize: Int = 25,
        flushInterval: TimeInterval = 30,
        maxQueueSize: Int = 10_000,
        allowedPayloadKeys: Set<String>? = nil,
        blockedPayloadKeys: Set<String> = AppMetricsConfiguration.defaultBlockedPayloadKeys,
        automaticAppLaunchTracking: Bool = true,
        urlSession: URLSession = .shared,
        queueDirectory: URL? = nil
    ) {
        self.ingestURL = ingestURL
        self.ingestKey = ingestKey
        self.testMode = testMode
        self.batchSize = min(max(1, batchSize), Self.maxBackendBatchSize)
        self.flushInterval = max(0, flushInterval)
        self.maxQueueSize = max(1, maxQueueSize)
        self.allowedPayloadKeys = allowedPayloadKeys
        self.blockedPayloadKeys = blockedPayloadKeys
        self.automaticAppLaunchTracking = automaticAppLaunchTracking
        self.urlSession = urlSession
        self.queueDirectory = queueDirectory
    }
}

public struct AppMetricsFlushResult: Equatable, Sendable {
    public var attempted: Int
    public var delivered: Int
    public var dropped: Int
    public var willRetry: Bool
    public var statusCode: Int?

    public static let empty = AppMetricsFlushResult(
        attempted: 0,
        delivered: 0,
        dropped: 0,
        willRetry: false,
        statusCode: nil
    )
}

/// Instance-based client. Use this directly for advanced apps and tests, or use
/// the static `AppMetricsKit` facade for standard app integration.
public final class AppMetricsClient: @unchecked Sendable {
    private enum Constants {
        static let queueFileName = "appmetricskit-queue-v1.json"
        static let maxPayloadKeys = 64
        static let maxPayloadKeyLength = 64
        static let maxPayloadValueLength = 1_024
        static let maxEventNameLength = 80
        static let eventNamePattern = #"^[A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*$"#
        static let userAgent = "AppMetricsKit-Swift/1.0"
    }

    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var configuration: AppMetricsConfiguration?
    private var queue: [AppMetricsQueuedEvent] = []
    private var anonymousUserId: String?
    private var sessionId = UUID().uuidString
    private var isCollectionEnabled = true
    private var isFlushing = false
    private var timer: DispatchSourceTimer?

    public init() {}

    deinit {
        timer?.cancel()
    }

    public var pendingEventCount: Int {
        lock.withLock { queue.count }
    }

    public func configure(_ configuration: AppMetricsConfiguration) {
        lock.withLock {
            self.configuration = configuration
            self.queue = loadQueue(configuration: configuration)
            self.isCollectionEnabled = true
            self.sessionId = UUID().uuidString
            startFlushTimer(configuration: configuration)
        }

        if configuration.automaticAppLaunchTracking {
            trackAppLaunch()
        }
    }

    public func identify(userId: String?) {
        lock.withLock {
            anonymousUserId = userId.flatMap { $0.isEmpty ? nil : Self.sha256($0) }
        }
    }

    public func resetIdentity() {
        lock.withLock {
            anonymousUserId = nil
            sessionId = UUID().uuidString
        }
    }

    public func setCollectionEnabled(_ enabled: Bool) {
        lock.withLock {
            isCollectionEnabled = enabled
        }
    }

    @discardableResult
    public func track(
        _ eventName: String,
        payload: AppMetricsPayload = [:],
        floatValue: Double? = nil
    ) -> String? {
        let eventId = UUID().uuidString
        var queuedEventId: String?

        lock.withLock {
            guard let configuration else {
                Self.debugWarn("Call configure(_:) before tracking events.")
                return
            }

            guard isCollectionEnabled else {
                return
            }

            guard Self.isValidEventName(eventName) else {
                Self.debugWarn("Dropped event with invalid name '\(eventName)'. Use Namespace.action, for example Paywall.viewed.")
                return
            }

            let scrubbedPayload = Self.scrubPayload(payload, configuration: configuration)
            let event = AppMetricsQueuedEvent(
                eventName: eventName,
                anonymousUserId: anonymousUserId,
                sessionId: sessionId,
                eventTime: Self.nowMillis(),
                isTestMode: configuration.testMode,
                platform: Self.platform,
                appVersion: Self.bundleValue("CFBundleShortVersionString"),
                buildNumber: Self.bundleValue("CFBundleVersion"),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: Self.deviceModel(),
                locale: Locale.current.identifier,
                timezone: TimeZone.current.identifier,
                floatValue: floatValue,
                eventId: eventId,
                payload: scrubbedPayload.isEmpty ? nil : scrubbedPayload
            )

            queue.append(event)
            trimQueueIfNeeded(maxQueueSize: configuration.maxQueueSize)
            persistQueue(configuration: configuration)

            if queue.count >= configuration.batchSize {
                Task { _ = await self.flush() }
            }

            queuedEventId = eventId
        }

        return queuedEventId
    }

    public func trackAppLaunch() {
        track(AppMetricsEvent.appLaunch)
    }

    public func trackOnboardingStarted() {
        track(AppMetricsEvent.onboardingStarted)
    }

    public func trackOnboardingCompleted() {
        track(AppMetricsEvent.onboardingCompleted)
    }

    public func trackPaywallViewed(plan: String? = nil) {
        var payload: AppMetricsPayload = [:]
        if let plan {
            payload["plan"] = .string(plan)
        }
        track(AppMetricsEvent.paywallViewed, payload: payload)
    }

    public func trackPurchaseCompleted(plan: String? = nil, amount: Double? = nil) {
        var payload: AppMetricsPayload = [:]
        if let plan {
            payload["plan"] = .string(plan)
        }
        track(AppMetricsEvent.purchaseCompleted, payload: payload, floatValue: amount)
    }

    public func trackError(name: String, message: String? = nil) {
        var payload: AppMetricsPayload = ["name": .string(name)]
        if let message {
            payload["message"] = .string(message)
        }
        track(AppMetricsEvent.errorOccurred, payload: payload)
    }

    @discardableResult
    public func flush() async -> AppMetricsFlushResult {
        guard let prepared = prepareFlushBatch() else {
            return .empty
        }

        let (configuration, batch) = prepared
        let attempted = batch.count
        let request = makeRequest(configuration: configuration, batch: batch)

        var lastStatusCode: Int?
        for attempt in 0..<3 {
            do {
                let (_, response) = try await configuration.urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    continue
                }

                lastStatusCode = http.statusCode
                if 200..<300 ~= http.statusCode {
                    finishFlush(batch: batch, outcome: .delivered, configuration: configuration)
                    return AppMetricsFlushResult(
                        attempted: attempted,
                        delivered: attempted,
                        dropped: 0,
                        willRetry: false,
                        statusCode: http.statusCode
                    )
                }

                if Self.isNonRetryableStatus(http.statusCode) {
                    finishFlush(batch: batch, outcome: .dropped, configuration: configuration)
                    Self.debugWarn("Dropped \(attempted) event(s) after non-retryable ingest status \(http.statusCode).")
                    return AppMetricsFlushResult(
                        attempted: attempted,
                        delivered: 0,
                        dropped: attempted,
                        willRetry: false,
                        statusCode: http.statusCode
                    )
                }
            } catch {
                Self.debugWarn("Flush attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }

            if attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 500_000_000))
            }
        }

        finishFlush(batch: batch, outcome: .retryLater, configuration: configuration)
        return AppMetricsFlushResult(
            attempted: attempted,
            delivered: 0,
            dropped: 0,
            willRetry: true,
            statusCode: lastStatusCode
        )
    }

    private func prepareFlushBatch() -> (AppMetricsConfiguration, [AppMetricsQueuedEvent])? {
        lock.withLock {
            guard !isFlushing, let configuration, !queue.isEmpty else {
                return nil
            }
            isFlushing = true
            return (configuration, Array(queue.prefix(configuration.batchSize)))
        }
    }

    private enum FlushOutcome {
        case delivered
        case dropped
        case retryLater
    }

    private func finishFlush(
        batch: [AppMetricsQueuedEvent],
        outcome: FlushOutcome,
        configuration: AppMetricsConfiguration
    ) {
        lock.withLock {
            defer { isFlushing = false }

            switch outcome {
            case .delivered, .dropped:
                let ids = Set(batch.map(\.eventId))
                queue.removeAll { ids.contains($0.eventId) }
                persistQueue(configuration: configuration)
            case .retryLater:
                break
            }
        }
    }

    private func makeRequest(
        configuration: AppMetricsConfiguration,
        batch: [AppMetricsQueuedEvent]
    ) -> URLRequest {
        var request = URLRequest(url: configuration.ingestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.ingestKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? encoder.encode(AppMetricsIngestEnvelope(events: batch))
        return request
    }

    private func startFlushTimer(configuration: AppMetricsConfiguration) {
        timer?.cancel()
        timer = nil

        guard configuration.flushInterval > 0 else {
            return
        }

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + configuration.flushInterval, repeating: configuration.flushInterval)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { _ = await self.flush() }
        }
        source.resume()
        timer = source
    }

    private func trimQueueIfNeeded(maxQueueSize: Int) {
        guard queue.count > maxQueueSize else {
            return
        }
        queue.removeFirst(queue.count - maxQueueSize)
        Self.debugWarn("Offline queue exceeded \(maxQueueSize) events. Oldest events were dropped.")
    }

    private func persistQueue(configuration: AppMetricsConfiguration) {
        let fileURL = Self.queueFileURL(configuration: configuration)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(queue)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Self.debugWarn("Failed to persist offline queue: \(error.localizedDescription)")
        }
    }

    private func loadQueue(configuration: AppMetricsConfiguration) -> [AppMetricsQueuedEvent] {
        let fileURL = Self.queueFileURL(configuration: configuration)
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? decoder.decode([AppMetricsQueuedEvent].self, from: data)) ?? []
    }

    private static func queueFileURL(configuration: AppMetricsConfiguration) -> URL {
        let directory = configuration.queueDirectory ?? defaultQueueDirectory()
        return directory.appendingPathComponent(Constants.queueFileName)
    }

    private static func defaultQueueDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "AppMetricsKit"
        return base
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("AppMetricsKit", isDirectory: true)
    }

    private static func isValidEventName(_ eventName: String) -> Bool {
        guard !eventName.isEmpty, eventName.count <= Constants.maxEventNameLength else {
            return false
        }
        return eventName.range(of: Constants.eventNamePattern, options: .regularExpression) != nil
    }

    private static func scrubPayload(
        _ payload: AppMetricsPayload,
        configuration: AppMetricsConfiguration
    ) -> AppMetricsPayload {
        let blocked = Set(configuration.blockedPayloadKeys.map { $0.lowercased() })
        let allowed = configuration.allowedPayloadKeys.map { Set($0.map { $0.lowercased() }) }
        var output: AppMetricsPayload = [:]

        for (key, value) in payload {
            guard output.count < Constants.maxPayloadKeys else {
                debugWarn("Dropped payload key '\(key)' because payloads are limited to \(Constants.maxPayloadKeys) keys.")
                continue
            }

            let normalizedKey = key.lowercased()
            guard key.count <= Constants.maxPayloadKeyLength else {
                debugWarn("Dropped payload key '\(key)' because it exceeds \(Constants.maxPayloadKeyLength) characters.")
                continue
            }

            if blocked.contains(normalizedKey) {
                debugWarn("Dropped blocked payload key '\(key)'.")
                continue
            }

            if let allowed, !allowed.contains(normalizedKey) {
                continue
            }

            switch value {
            case .string(let string):
                guard !looksLikePII(string) else {
                    debugWarn("Dropped payload key '\(key)' because its value looks like personal data.")
                    continue
                }
                output[key] = .string(String(string.prefix(Constants.maxPayloadValueLength)))
            case .number(let number):
                guard number.isFinite else {
                    debugWarn("Dropped payload key '\(key)' because its number is not finite.")
                    continue
                }
                output[key] = .number(number)
            case .bool:
                output[key] = value
            }
        }

        return output
    }

    private static func looksLikePII(_ value: String) -> Bool {
        let emailPattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        let phonePattern = #"^\+?[0-9][0-9 .()\-]{7,}[0-9]$"#
        let creditCardPattern = #"^(?:\d[ -]*?){13,19}$"#
        return value.range(of: emailPattern, options: [.regularExpression, .caseInsensitive]) != nil
            || value.range(of: phonePattern, options: .regularExpression) != nil
            || value.range(of: creditCardPattern, options: .regularExpression) != nil
    }

    private static func isNonRetryableStatus(_ statusCode: Int) -> Bool {
        statusCode == 400 || statusCode == 401 || statusCode == 403 || statusCode == 413
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func nowMillis() -> Double {
        Date().timeIntervalSince1970 * 1_000
    }

    private static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "apple"
        #endif
    }

    private static func bundleValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static func deviceModel() -> String {
        #if canImport(Darwin)
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private static func debugWarn(_ message: String) {
        #if DEBUG
        print("AppMetricsKit warning: \(message)")
        #endif
    }
}

/// Static facade for app integrations.
public enum AppMetricsKit {
    private static let shared = AppMetricsClient()

    public static var pendingEventCount: Int {
        shared.pendingEventCount
    }

    public static func configure(_ configuration: AppMetricsConfiguration) {
        shared.configure(configuration)
    }

    public static func identify(userId: String?) {
        shared.identify(userId: userId)
    }

    public static func resetIdentity() {
        shared.resetIdentity()
    }

    public static func setCollectionEnabled(_ enabled: Bool) {
        shared.setCollectionEnabled(enabled)
    }

    @discardableResult
    public static func track(
        _ eventName: String,
        payload: AppMetricsPayload = [:],
        floatValue: Double? = nil
    ) -> String? {
        shared.track(eventName, payload: payload, floatValue: floatValue)
    }

    public static func trackAppLaunch() {
        shared.trackAppLaunch()
    }

    public static func trackOnboardingStarted() {
        shared.trackOnboardingStarted()
    }

    public static func trackOnboardingCompleted() {
        shared.trackOnboardingCompleted()
    }

    public static func trackPaywallViewed(plan: String? = nil) {
        shared.trackPaywallViewed(plan: plan)
    }

    public static func trackPurchaseCompleted(plan: String? = nil, amount: Double? = nil) {
        shared.trackPurchaseCompleted(plan: plan, amount: amount)
    }

    public static func trackError(name: String, message: String? = nil) {
        shared.trackError(name: name, message: message)
    }

    @discardableResult
    public static func flush() async -> AppMetricsFlushResult {
        await shared.flush()
    }
}

struct AppMetricsIngestEnvelope: Codable, Equatable {
    var events: [AppMetricsQueuedEvent]
}

struct AppMetricsQueuedEvent: Codable, Equatable {
    var eventName: String
    var anonymousUserId: String?
    var sessionId: String?
    var eventTime: Double
    var isTestMode: Bool
    var platform: String
    var appVersion: String?
    var buildNumber: String?
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var timezone: String?
    var floatValue: Double?
    var eventId: String
    var payload: AppMetricsPayload?
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
