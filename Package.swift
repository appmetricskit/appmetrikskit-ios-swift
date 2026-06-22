// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppMetricsKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "AppMetricsKit", targets: ["AppMetricsKit"]),
    ],
    targets: [
        .target(
            name: "AppMetricsKit",
            path: "AppMetricsKits-swift/AppMetricsKits-swift",
            resources: [
                // App Store privacy manifest — must ship inside the SDK bundle.
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "AppMetricsKitTests",
            dependencies: ["AppMetricsKit"],
            path: "AppMetricsKits-swift/AppMetricsKits-swiftTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
