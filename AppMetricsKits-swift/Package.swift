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
            path: "AppMetricsKits-swift"
        ),
        .testTarget(
            name: "AppMetricsKitTests",
            dependencies: ["AppMetricsKit"],
            path: "AppMetricsKits-swiftTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
