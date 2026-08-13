// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "maple-swift",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "MapleReplay", targets: ["MapleReplay"])
    ],
    targets: [
        .target(
            name: "MapleReplay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MapleReplayTests",
            dependencies: ["MapleReplay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
