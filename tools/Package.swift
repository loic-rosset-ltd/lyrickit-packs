// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "realpack",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "/Users/lrosset/Projects/LyricKit"),
        .package(path: "/Users/lrosset/Projects/DragonArchive/library")
    ],
    targets: [.executableTarget(name: "realpack", dependencies: [
        .product(name: "LyricKit", package: "LyricKit"),
        .product(name: "LyricKitData", package: "LyricKit"),
        .product(name: "DragonArchive", package: "library")])]
)
