// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MultiTaskCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MultiTaskCore", targets: ["MultiTaskCore"])
    ],
    targets: [
        .target(
            name: "MultiTaskCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MultiTaskCoreTests",
            dependencies: ["MultiTaskCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
