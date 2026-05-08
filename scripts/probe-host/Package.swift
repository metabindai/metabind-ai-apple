// swift-tools-version: 5.11
import PackageDescription

let package = Package(
    name: "probe-host",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "metabind-ai-apple", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "probe-host",
            dependencies: [
                .product(name: "MetabindAssistant", package: "metabind-ai-apple"),
            ],
            path: "."
        )
    ]
)
