// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Macouse", targets: ["MacouseApp"]),
        .executable(name: "macouse-cli", targets: ["macouse-cli"]),
    ],
    targets: [
        .target(
            name: "MacouseSPI",
            path: "Sources/MacouseSPI",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "MacouseCore",
            dependencies: ["MacouseSPI"]
        ),
        .executableTarget(
            name: "MacouseApp",
            dependencies: ["MacouseCore"]
        ),
        .executableTarget(
            name: "macouse-cli",
            dependencies: ["MacouseCore"]
        ),
        .testTarget(
            name: "MacouseCoreTests",
            dependencies: ["MacouseCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
