// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HostJournalPreviewConsumer",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "HostJournalPreviewConsumer", targets: ["HostJournalPreviewConsumer"])],
    dependencies: [.package(url: "https://github.com/exddc/GotSync.git", revision: "5e1923651ab92b990d81b9aec764544c1a1f2099")],
    targets: [
        .target(name: "HostJournalPreviewConsumer", dependencies: [.product(name: "GotSync", package: "GotSync")]),
        .testTarget(name: "HostJournalPreviewConsumerTests", dependencies: ["HostJournalPreviewConsumer"]),
    ]
)
