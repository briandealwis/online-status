// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OnlineStatus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OnlineStatusCore", targets: ["OnlineStatusCore"]),
        .executable(name: "OnlineStatus", targets: ["OnlineStatus"]),
    ],
    targets: [
        // Platform-independent logic: samples, statistics, status evaluation, ICMP packets.
        .target(name: "OnlineStatusCore"),
        // The macOS menu bar app (AppKit + SwiftUI + Swift Charts).
        .executableTarget(
            name: "OnlineStatus",
            dependencies: ["OnlineStatusCore"]
        ),
        .testTarget(
            name: "OnlineStatusCoreTests",
            dependencies: ["OnlineStatusCore"]
        ),
    ]
)
