// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PowerCuff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PowerCuff", targets: ["PowerCuff"]),
        .executable(name: "PowerCuffHelper", targets: ["PowerCuffHelper"]),
    ],
    targets: [
        .target(name: "PowerCuffCore", linkerSettings: [.linkedLibrary("IOReport")]),
        .executableTarget(name: "PowerCuff", dependencies: ["PowerCuffCore"]),
        .executableTarget(name: "PowerCuffHelper", dependencies: ["PowerCuffCore"]),
        .testTarget(name: "PowerCuffCoreTests", dependencies: ["PowerCuffCore"]),
    ]
)
