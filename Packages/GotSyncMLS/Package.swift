// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GotSyncMLS",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "GotSyncMLS", targets: ["GotSyncMLS"])],
    targets: [
        .binaryTarget(name: "gotsync_mlsFFI", path: "Artifacts/GotSyncMLSFFI.xcframework"),
        .target(name: "GotSyncMLSBindings", dependencies: ["gotsync_mlsFFI"]),
        .target(name: "GotSyncMLS", dependencies: ["GotSyncMLSBindings"]),
        .testTarget(name: "GotSyncMLSTests", dependencies: ["GotSyncMLS", "GotSyncMLSBindings"]),
    ]
)
