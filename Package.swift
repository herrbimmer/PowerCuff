// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PowerCuff",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PowerCuff", targets: ["PowerCuff"])],
    targets: [
        .target(name: "PowerCuffCore"),
        .executableTarget(name: "PowerCuff", dependencies: ["PowerCuffCore"]),
        .testTarget(name: "PowerCuffCoreTests", dependencies: ["PowerCuffCore"]),
    ]
)
