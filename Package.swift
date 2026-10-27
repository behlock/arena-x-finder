// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Are.na x Finder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ArenaFinder", targets: ["ArenaFinder"]),
        .library(name: "ArenaProvider", type: .static, targets: ["ArenaProvider"])
    ],
    targets: [
        .target(name: "ArenaCore"),
        .target(name: "ArenaProvider", dependencies: ["ArenaCore"]),
        .executableTarget(name: "ArenaFinder", dependencies: ["ArenaCore", "ArenaProvider"]),
        .testTarget(name: "ArenaProviderTests", dependencies: ["ArenaProvider"]),
        .testTarget(name: "ArenaCoreTests", dependencies: ["ArenaCore"]),
        .testTarget(name: "ArenaFinderTests", dependencies: ["ArenaFinder"])
    ]
)
