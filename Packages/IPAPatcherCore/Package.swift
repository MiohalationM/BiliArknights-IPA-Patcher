// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPAPatcherCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Zip64Kit",
            targets: ["Zip64Kit"]
        ),
        .library(
            name: "IPAPatcherCore",
            targets: ["IPAPatcherCore"]
        ),
        .executable(
            name: "ipa-patcher-cli",
            targets: ["IPAPatcherCLI"]
        )
    ],
    targets: [
        .target(
            name: "Zip64Kit",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "IPAPatcherCore",
            dependencies: ["Zip64Kit"],
            resources: [
                .copy("Resources/Kits")
            ]
        ),
        .executableTarget(
            name: "IPAPatcherCLI",
            dependencies: ["IPAPatcherCore"]
        ),
        .testTarget(
            name: "Zip64KitTests",
            dependencies: ["Zip64Kit"]
        ),
        .testTarget(
            name: "IPAPatcherCoreTests",
            dependencies: ["IPAPatcherCore", "Zip64Kit"]
        )
    ]
)
