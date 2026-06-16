# AppMetricsKit Swift SDK

Privacy-first mobile analytics for iOS apps. The SDK batches events, retries
safely, works offline, hashes user IDs on device, and sends only flat primitive
payloads to your AppMetricsKit ingest endpoint.

## Installation

In Xcode:

1. Open **File > Add Package Dependencies**.
2. Add this repository URL:

   ```text
   https://github.com/appmetricskit/appmetrikskit-ios-swift.git
   ```

3. Select the `AppMetricsKit` package product.

Or add it to `Package.swift`:

```swift
.package(url: "https://github.com/appmetricskit/appmetrikskit-ios-swift.git", from: "0.1.0")
```

```swift
.product(name: "AppMetricsKit", package: "appmetrikskit-ios-swift")
```

## Quickstart

Create an app and ingest key inside AppMetricsKit, then configure the SDK when
your app starts:

```swift
import AppMetricsKit
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        AppMetricsKit.configure(
            AppMetricsConfiguration(
                ingestURL: URL(string: "https://appmetricskit.com/api/ingest")!,
                ingestKey: "amk_live_...",
                testMode: false
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Track events:

```swift
AppMetricsKit.track("Paywall.viewed", payload: ["plan": "annual"])
AppMetricsKit.track("Purchase.completed", payload: ["plan": "annual"], floatValue: 59.99)
```

Identify a user without sending the raw user ID:

```swift
AppMetricsKit.identify(userId: user.id)
```

`identify(userId:)` hashes the value with SHA-256 on device and sends it as
`anonymousUserId`.

## Backend contract

The SDK sends batches to:

```text
POST /api/ingest
Authorization: Bearer amk_live_...
Content-Type: application/json
```

Body:

```json
{
  "events": [
    {
      "eventName": "Paywall.viewed",
      "anonymousUserId": "hashed-user-id",
      "sessionId": "uuid",
      "eventTime": 1781640000000,
      "isTestMode": false,
      "platform": "ios",
      "appVersion": "1.0",
      "buildNumber": "42",
      "osVersion": "Version 26.0",
      "deviceModel": "iPhone17,1",
      "locale": "en_US",
      "timezone": "Europe/Brussels",
      "eventId": "uuid",
      "payload": {
        "plan": "annual"
      }
    }
  ]
}
```

## Event naming

Event names must use `Namespace.action` format:

```swift
AppMetricsKit.track("Onboarding.started")
AppMetricsKit.track("Onboarding.completed")
AppMetricsKit.track("Paywall.viewed")
AppMetricsKit.track("Purchase.completed")
AppMetricsKit.track("Feature.used", payload: ["feature": "export"])
AppMetricsKit.track("Error.occurred", payload: ["name": "network_timeout"])
```

Convenience helpers are included:

```swift
AppMetricsKit.trackAppLaunch()
AppMetricsKit.trackOnboardingStarted()
AppMetricsKit.trackOnboardingCompleted()
AppMetricsKit.trackPaywallViewed(plan: "annual")
AppMetricsKit.trackPurchaseCompleted(plan: "annual", amount: 59.99)
AppMetricsKit.trackError(name: "network_timeout", message: "Request timed out")
```

## Payload rules

Payloads are flat dictionaries containing only strings, numbers, and booleans:

```swift
AppMetricsKit.track(
    "Feature.used",
    payload: [
        "feature": "csv_export",
        "count": 3,
        "isPro": true
    ]
)
```

The SDK drops:

- Blocked keys such as `email`, `phone`, `name`, `idfa`, `ipAddress`, and location keys.
- Values that look like email addresses, phone numbers, or credit card numbers.
- Keys not present in `allowedPayloadKeys`, when an allowlist is configured.
- Invalid event names.
- Non-finite numeric values.

Example strict configuration:

```swift
AppMetricsKit.configure(
    AppMetricsConfiguration(
        ingestURL: URL(string: "https://appmetricskit.com/api/ingest")!,
        ingestKey: "amk_live_...",
        allowedPayloadKeys: ["plan", "source", "feature", "price"],
        blockedPayloadKeys: ["email", "phone", "name"]
    )
)
```

## Offline queue and retries

Events are persisted to disk and flushed in batches. Defaults:

- `batchSize`: 25 events
- `flushInterval`: 30 seconds
- `maxQueueSize`: 10,000 events
- backend max batch size: 500 events

The SDK retries network errors, `408`, `429`, and `5xx` responses with exponential
backoff. It drops the current batch on non-retryable `400`, `401`, `403`, and
`413` responses to avoid retry loops.

Manually flush:

```swift
let result = await AppMetricsKit.flush()
print(result.delivered)
```

Pause or resume collection:

```swift
AppMetricsKit.setCollectionEnabled(false)
AppMetricsKit.setCollectionEnabled(true)
```

## Test mode

Use test mode while instrumenting your app:

```swift
AppMetricsKit.configure(
    AppMetricsConfiguration(
        ingestURL: URL(string: "https://appmetricskit.com/api/ingest")!,
        ingestKey: "amk_test_...",
        testMode: true
    )
)
```

Test events are marked with `isTestMode: true` so they can be separated from
production analytics.

## SwiftUI button example

```swift
import AppMetricsKit
import SwiftUI

struct PaywallView: View {
    var body: some View {
        Button("Start annual plan") {
            AppMetricsKit.track(
                "Paywall.ctaTapped",
                payload: ["plan": "annual", "placement": "hero"]
            )
        }
    }
}
```

## StoreKit example

```swift
import AppMetricsKit
import StoreKit

func handlePurchase(product: Product) async {
    AppMetricsKit.track(
        "Purchase.started",
        payload: ["productId": product.id]
    )

    do {
        let result = try await product.purchase()
        switch result {
        case .success:
            AppMetricsKit.track(
                "Purchase.completed",
                payload: ["productId": product.id],
                floatValue: NSDecimalNumber(decimal: product.price).doubleValue
            )
        case .userCancelled:
            AppMetricsKit.track(
                "Purchase.failed",
                payload: ["productId": product.id, "reason": "cancelled"]
            )
        default:
            AppMetricsKit.track(
                "Purchase.failed",
                payload: ["productId": product.id, "reason": "unknown"]
            )
        }
    } catch {
        AppMetricsKit.trackError(name: "purchase_error", message: error.localizedDescription)
    }
}
```

## Troubleshooting

- **No events in dashboard**: confirm the ingest key starts with `amk_live_` or
  `amk_test_`, and that the ingest URL points to your deployed SaaS:
  `https://your-domain.com/api/ingest`.
- **401 responses**: regenerate the app ingest key in AppMetricsKit and update
  your app configuration.
- **413 responses**: reduce custom payload size or batch size.
- **Payload values missing**: check `allowedPayloadKeys`, `blockedPayloadKeys`,
  and the privacy filters.

## Development

Run tests:

```bash
swift test
```

The package has no third-party dependencies.

## License

MIT. See [LICENSE](LICENSE).
