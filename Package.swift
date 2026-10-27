// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Are.na x Finder",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ArenaFinder", targets: ["ArenaFinder"])],
    targets: [
        .target(name: "ArenaCore"),
        .executableTarget(name: "ArenaFinder", dependencies: ["ArenaCore"]),
        .testTarget(name: "ArenaCoreTests", dependencies: ["ArenaCore"]),
        .testTarget(name: "ArenaFinderTests", dependencies: ["ArenaFinder"])
    ]
)
