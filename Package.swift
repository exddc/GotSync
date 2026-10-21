// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GotSync",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "GotSync", targets: ["GotSync"])],
    dependencies: [.package(path: "Packages/GotSyncMLS")],
    targets: [
        .target(name: "GotSync", dependencies: [.product(name: "GotSyncMLS", package: "GotSyncMLS")]),
        .testTarget(name: "GotSyncTests", dependencies: ["GotSync"]),
    ]
)
