// swift-tools-version:6.0
// Peráta's SDK for Swift, written by sdk/generator; do not edit. The
// repository's root Package.swift builds these same sources, so SwiftPM can
// depend on https://github.com/perata-sh/sdk.
import PackageDescription

let package = Package(
    name: "Perata",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "Perata", targets: ["Perata"])
    ],
    targets: [
        .target(name: "Perata"),
        .testTarget(name: "PerataTests", dependencies: ["Perata"]),
    ]
)
