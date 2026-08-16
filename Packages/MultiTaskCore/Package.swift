// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MultiTaskCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MultiTaskCore", targets: ["MultiTaskCore"]),
        .executable(name: "mtm", targets: ["mtm"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "MultiTaskCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mtm",
            dependencies: [
                "MultiTaskCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MultiTaskCoreTests",
            dependencies: ["MultiTaskCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
