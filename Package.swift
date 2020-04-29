// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "GTMSessionFetcher",
    platforms: [
        .macOS(.v10_10),
        .iOS(.v8),
        .tvOS(.v9),
        .watchOS(.v2)
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
            path: "Source/GTMSessionFetcher/Core",
            publicHeadersPath: "."
        ),
        .target(
            name: "GTMSessionFetcherFull",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Source/GTMSessionFetcher/Full",
            publicHeadersPath: "."
        ),
        .target(
            name: "GTMSessionFetcherLogView",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Source/GTMSessionFetcher/LogView",
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "GTMSessionFetcherCoreTests",
            dependencies: ["GTMSessionFetcherFull"],
            path: "Source/UnitTests"
        )
    ]
)
