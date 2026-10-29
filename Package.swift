// swift-tools-version: 6.0
import Foundation
import PackageDescription

let mlsBinary = (
    path: "Artifacts/gotsync_mlsFFI.xcframework",
    url: "https://github.com/exddc/GotSync/releases/download/mls-ffi-0.1.0/gotsync_mlsFFI.xcframework.zip",
    checksum: "b418f2033ad6b9e3b603c2bbcabaa5201dd2577fb27034ba0013b95d9fe49851"
)
let mlsBinaryTarget: Target = FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\(mlsBinary.path)")
    ? .binaryTarget(name: "gotsync_mlsFFI", path: mlsBinary.path)
    : .binaryTarget(name: "gotsync_mlsFFI", url: mlsBinary.url, checksum: mlsBinary.checksum)

let package = Package(
    name: "GotSync",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "GotSync", targets: ["GotSync"])],
    targets: [
        .target(name: "GotSync", dependencies: ["GotSyncMLS"]),
        mlsBinaryTarget,
        .target(name: "GotSyncMLSBindings", dependencies: ["gotsync_mlsFFI"]),
        .target(name: "GotSyncMLS", dependencies: ["GotSyncMLSBindings"]),
        .testTarget(name: "GotSyncTests", dependencies: ["GotSync"]),
        .testTarget(name: "GotSyncMLSTests", dependencies: ["GotSyncMLS", "GotSyncMLSBindings"]),
    ]
)
