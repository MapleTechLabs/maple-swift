// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "maple-swift",
    platforms: [.iOS(.v16)],
    products: [
        // Both signals, one call. What an app should depend on.
        .library(name: "Maple", targets: ["Maple"]),
        // À la carte, for an app that wants only one of them.
        .library(name: "MapleReplay", targets: ["MapleReplay"]),
        .library(name: "MapleTracing", targets: ["MapleTracing"]),
    ],
    targets: [
        // The session/trace join, and the request plumbing both signals share.
        // Exists so `MapleReplay` and `MapleTracing` stay siblings: an app that wants
        // only tracing should not link a screenshot recorder to get it.
        .target(name: "MapleCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "MapleTracing",
            dependencies: ["MapleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MapleReplay",
            dependencies: ["MapleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "Maple",
            dependencies: ["MapleReplay", "MapleTracing"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MapleReplayTests",
            dependencies: ["MapleReplay", "MapleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MapleTracingTests",
            dependencies: ["MapleTracing", "MapleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
