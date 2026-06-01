// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LookingGlass",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "LookingGlass",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "LookingGlass",
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
