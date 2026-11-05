// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Blinker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Blinker", path: "Sources/Blinker"),
        .testTarget(name: "BlinkerTests", dependencies: ["Blinker"], path: "Tests/BlinkerTests"),
    ]
)
