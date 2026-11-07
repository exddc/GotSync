// swift-tools-version: 6.0
import Foundation
import PackageDescription

let mlsBinary = (
    path: "Artifacts/gotsync_mlsFFI.xcframework",
    url: "https://github.com/exddc/GotSync/releases/download/mls-ffi-0.1.1-gotdone.1/gotsync_mlsFFI.xcframework.zip",
    checksum: "05c28414aff8b39b3b841b5134e5899f89dfdac99e90ddba6166e5457d1e7094"
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
