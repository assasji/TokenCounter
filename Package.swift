// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenBar", targets: ["TokenBar"])],
    targets: [
        .executableTarget(name: "TokenBar", resources: [.process("Resources")]),
        .testTarget(name: "TokenBarTests", dependencies: ["TokenBar"])
    ]
)
