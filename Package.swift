// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GotSync",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "GotSync", targets: ["GotSync"])],
    targets: [
        .target(name: "GotSync"),
        .testTarget(name: "GotSyncTests", dependencies: ["GotSync"], resources: [.copy("Fixtures")]),
    ]
)
