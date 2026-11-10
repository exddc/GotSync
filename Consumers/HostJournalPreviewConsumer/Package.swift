// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HostJournalPreviewConsumer",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "HostJournalPreviewConsumer", targets: ["HostJournalPreviewConsumer"])],
    dependencies: [.package(url: "https://github.com/exddc/GotSync.git", revision: "5844e76540f534030610225e69e28c6a41020b55")],
    targets: [
        .target(name: "HostJournalPreviewConsumer", dependencies: [.product(name: "GotSync", package: "GotSync")]),
        .testTarget(name: "HostJournalPreviewConsumerTests", dependencies: ["HostJournalPreviewConsumer"]),
    ]
)
