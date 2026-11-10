// swift-tools-version: 6.0
import PackageDescription

// Consumes GotSync from a copy of this repository without `Artifacts/`, so
// the MLS binary resolves by its pinned URL and checksum. A later commit
// pins GotSync by URL and revision instead.
let package = Package(
    name: "HostJournalPreviewConsumer",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "HostJournalPreviewConsumer", targets: ["HostJournalPreviewConsumer"])],
    dependencies: [.package(name: "GotSync", path: "../..")],
    targets: [
        .target(name: "HostJournalPreviewConsumer", dependencies: [.product(name: "GotSync", package: "GotSync")]),
        .testTarget(name: "HostJournalPreviewConsumerTests", dependencies: ["HostJournalPreviewConsumer"]),
    ]
)
