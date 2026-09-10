// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KubixCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KubixCore", targets: ["KubixCore"]),
        .library(name: "KubixRuntime", targets: ["KubixRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "KubixCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .target(name: "KubixRuntime", dependencies: ["KubixCore"]),
        .testTarget(
            name: "KubixCoreTests",
            dependencies: [
                "KubixCore",
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "KubixRuntimeTests", dependencies: ["KubixRuntime"]),
    ],
    swiftLanguageModes: [.v6]
)
