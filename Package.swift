// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Are.na x Finder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ArenaFinder", targets: ["ArenaFinder"]),
        .library(name: "ArenaProvider", type: .static, targets: ["ArenaProvider"])
    ],
    dependencies: [.package(path: "../webloc-thumbnail-generator")],
    targets: [
        .target(name: "ArenaCore"),
        .target(name: "ArenaProvider", dependencies: ["ArenaCore"]),
        .executableTarget(name: "ArenaFinder", dependencies: ["ArenaCore", "ArenaProvider",
            .product(name: "ThumbnailCore", package: "webloc-thumbnail-generator"),
            .product(name: "ThumbnailCapture", package: "webloc-thumbnail-generator")]),
        .testTarget(name: "ArenaProviderTests", dependencies: ["ArenaProvider"]),
        .testTarget(name: "ArenaCoreTests", dependencies: ["ArenaCore"]),
        .testTarget(name: "ArenaFinderTests", dependencies: ["ArenaFinder"])
    ]
)
