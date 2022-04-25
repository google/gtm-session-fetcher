// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "GTMSessionFetcher",
    platforms: [
        .iOS(.v9),
        .macOS(.v10_12),
        .tvOS(.v10),
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "GTMSessionFetcher",
            targets: ["GTMSessionFetcherCore", "GTMSessionFetcherFull"]
        ),
        .library(
            name: "GTMSessionFetcherCore",
            targets: ["GTMSessionFetcherCore"]
        ),
        .library(
            name: "GTMSessionFetcherFull",
            targets: ["GTMSessionFetcherFull"]
        ),
        .library(
            name: "GTMSessionFetcherLogView",
            targets: ["GTMSessionFetcherLogView"]
        )
    ],
    targets: [
        .target(
            name: "GTMSessionFetcherCore",
            path: "Sources/Core",
            publicHeadersPath: "Public"
        ),
        .target(
            name: "GTMSessionFetcherFull",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Sources/Full",
            publicHeadersPath: "Public"
        ),
        .target(
            name: "GTMSessionFetcherLogView",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Sources/LogView",
            publicHeadersPath: "Public"
        ),
        .testTarget(
            name: "GTMSessionFetcherCoreTests",
            dependencies: ["GTMSessionFetcherFull", "GTMSessionFetcherCore"],
            path: "UnitTests",
            // Resources not working as of Swfit 5.3
            // - https://forums.swift.org/t/5-3-resources-support-not-working-on-with-swift-test/40381
            // - https://bugs.swift.org/browse/SR-13560
            exclude: ["Data"]
        )
    ]
)
