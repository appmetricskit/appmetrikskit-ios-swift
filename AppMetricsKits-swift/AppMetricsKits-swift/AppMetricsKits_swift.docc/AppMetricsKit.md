# ``AppMetricsKit``

Privacy-first mobile analytics for iOS apps.

## Overview

AppMetricsKit sends anonymous mobile analytics events to the AppMetricsKit SaaS
ingest endpoint. The SDK batches events, persists an offline queue, retries
safe failures, hashes user identifiers on device, and drops obvious personal
data before payloads leave the app.

Configure the SDK once when your app starts:

```swift
import AppMetricsKit

AppMetricsKit.configure(
    AppMetricsConfiguration(
        ingestURL: URL(string: "https://appmetricskit.com/api/ingest")!,
        ingestKey: "amk_live_..."
    )
)
```

Track events using `Namespace.action` names:

```swift
AppMetricsKit.track("Paywall.viewed", payload: ["plan": "annual"])
AppMetricsKit.trackPurchaseCompleted(plan: "annual", amount: 59.99)
```

## Topics

### Configuration

- ``AppMetricsConfiguration``

### Tracking

- ``AppMetricsKit``
- ``AppMetricsClient``
- ``AppMetricsEvent``
- ``AppMetricsValue``

### Flushing

- ``AppMetricsFlushResult``
