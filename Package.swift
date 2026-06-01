// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LookingGlass",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LookingGlass",
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
