// swift-tools-version: 6.0
import PackageDescription
import Foundation

let hostWire = ProcessInfo.processInfo.environment["GOTSYNC_WIRE_HOST"]
let wireTargets: [Target] = hostWire.map { path in [
    .systemLibrary(name: "LibCoreCrypto", path: "Packages/WireCoreCrypto/HostFFI"),
    .target(name: "WireCoreCryptoUniffi", dependencies: ["LibCoreCrypto"], path: "Packages/WireCoreCrypto/HostSwift", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.unsafeFlags(["-L", path, "-lcore_crypto_ffi", "-Xlinker", "-rpath", "-Xlinker", path])]),
] } ?? [
    .binaryTarget(name: "WireCoreCryptoUniffi", url: "https://github.com/wireapp/core-crypto/releases/download/v10.5.4/WireCoreCryptoUniffi.xcframework.zip", checksum: "a7a24cd536c909ec30b2e00ac74e768dc97d132d7fd49f9708d87cfcde073550"),
]

let package = Package(
    name: "GotSync",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "GotSync", targets: ["GotSync"])],
    targets: wireTargets + [
        .target(name: "GotSync", dependencies: ["WireCoreCryptoUniffi"]),
        .testTarget(name: "GotSyncTests", dependencies: ["GotSync"], resources: [.copy("Fixtures")]),
    ]
)
