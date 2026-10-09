// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "revu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "revu", targets: ["revu"]),
    ],
    targets: [
        .target(name: "RevuCore"),
        .executableTarget(name: "revu", dependencies: ["RevuCore"]),
        .testTarget(name: "RevuCoreTests", dependencies: ["RevuCore", "revu"]),
    ]
)
