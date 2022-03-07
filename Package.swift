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
            path: "Source",
            exclude:[
                "GTMGatherInputStream.m",
                "GTMMIMEDocument.m",
                "GTMReadMonitorInputStream.m",
                "GTMSessionFetcherLogViewController.m",
            ],
            sources:[
                "GTMSessionFetcher.h",
                "GTMSessionFetcher.m",
                "GTMSessionFetcherLogging.h",
                "GTMSessionFetcherLogging.m",
                "GTMSessionFetcherService.h",
                "GTMSessionFetcherService.m",
                "GTMSessionUploadFetcher.h",
                "GTMSessionUploadFetcher.m"
            ],
            publicHeadersPath: "SwiftPackage"
        ),
        .target(
            name: "GTMSessionFetcherFull",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Source",
            exclude:[
                "GTMSessionFetcher.m",
                "GTMSessionFetcherLogging.m",
                "GTMSessionFetcherLogViewController.m",
                "GTMSessionFetcherService.m",
                "GTMSessionUploadFetcher.m",
            ],
            sources: [
                "GTMGatherInputStream.h",
                "GTMGatherInputStream.m",
                "GTMMIMEDocument.h",
                "GTMMIMEDocument.m",
                "GTMReadMonitorInputStream.h",
                "GTMReadMonitorInputStream.m",
            ],
            publicHeadersPath: "SwiftPackage"
        ),
        .target(
            name: "GTMSessionFetcherLogView",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Source",
            exclude:[
                "GTMGatherInputStream.m",
                "GTMMIMEDocument.m",
                "GTMReadMonitorInputStream.m",
                "GTMSessionFetcherService.m",
                "GTMSessionFetcher.m",
                "GTMSessionFetcherLogging.m",
                "GTMSessionUploadFetcher.m",
            ],
            sources: [
                "GTMSessionFetcherLogViewController.h",
                "GTMSessionFetcherLogViewController.m"
            ],
            publicHeadersPath: "SwiftPackage"
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
