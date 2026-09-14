// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenCounter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenCounter", targets: ["TokenCounter"])],
    targets: [
        .executableTarget(name: "TokenCounter", resources: [.process("Resources")]),
        .testTarget(name: "TokenCounterTests", dependencies: ["TokenCounter"])
    ]
)
