// swift-tools-version: 5.11
import PackageDescription

let package = Package(
    name: "metabind-ai-apple",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MCPAppsHost", targets: ["MCPAppsHost"]),
        .library(name: "MetabindAssistant", targets: ["MetabindAssistant"]),
    ],
    dependencies: [
        .package(url: "https://github.com/metabindai/bindjs-apple-binary.git", from: "1.1.4"),
    ],
    targets: [
        .target(
            name: "MCPAppsHost",
            dependencies: [
                .product(name: "BindJS", package: "bindjs-apple-binary"),
            ]
        ),
        .target(
            name: "MetabindAssistant",
            dependencies: ["MCPAppsHost"]
        ),
        .testTarget(
            name: "MCPAppsHostTests",
            dependencies: ["MCPAppsHost"]
        ),
        .testTarget(
            name: "MetabindAssistantTests",
            dependencies: ["MetabindAssistant"]
        ),
    ]
)
