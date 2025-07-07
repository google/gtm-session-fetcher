// swift-tools-version:5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "GTMSessionFetcher",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15),
        .tvOS(.v15),
        .watchOS(.v7)
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
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy")
            ],
            publicHeadersPath: "Public"
        ),
        .target(
            name: "GTMSessionFetcherFull",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Sources/Full",
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy")
            ],
            publicHeadersPath: "Public"
        ),
        .target(
            name: "GTMSessionFetcherLogView",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Sources/LogView",
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy")
            ],
            publicHeadersPath: "Public"
        ),
        .testTarget(
            name: "GTMSessionFetcherCoreTests",
            dependencies: ["GTMSessionFetcherFull", "GTMSessionFetcherCore"],
            path: "UnitTests",
            exclude: ["GTMSessionFetcherUserAgentTest.m"],
            cSettings: [
                .headerSearchPath("../Sources/Core")
            ]
        ),
        // This runs in its own target since it exercises global variable initialization.
        .testTarget(
            name: "GTMSessionFetcherUserAgentTests",
            dependencies: ["GTMSessionFetcherCore"],
            path: "UnitTests",
            sources: ["GTMSessionFetcherUserAgentTest.m"],
            cSettings: [
                .headerSearchPath("../Sources/Core")
            ]
        ),
        .testTarget(
            name: "swift-test",
            dependencies: [
                "GTMSessionFetcherCore",
                "GTMSessionFetcherFull",
                "GTMSessionFetcherLogView",
            ],
            path: "SwiftPMTests/SwiftImportTest"
        ),
        .testTarget(
            name: "objc-import-test",
            dependencies: [
                "GTMSessionFetcherCore",
                "GTMSessionFetcherFull",
                "GTMSessionFetcherLogView",
            ],
            path: "SwiftPMTests/ObjCImportTest"
        ),
    ]
)
