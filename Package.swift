// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MCPKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MCPKit", targets: ["MCPKit"]),
    ],
    targets: [
        .target(name: "MCPKit"),
        // A tiny server used by the end-to-end tests, and the smallest working example.
        .executableTarget(name: "mcpkit-example", dependencies: ["MCPKit"]),
        .testTarget(name: "MCPKitTests", dependencies: ["MCPKit"]),
    ]
)
