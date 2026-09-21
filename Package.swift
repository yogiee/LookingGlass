// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LookingGlass",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        // Already in the graph via MarkdownUI — declared directly so the report
        // viewer can call cmark-gfm's HTML renderer itself.
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "LookingGlass",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
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
