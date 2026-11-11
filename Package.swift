// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DLLC",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DLLC", targets: ["DLLC"]),
    ],
    targets: [
        .target(
            name: "DLLCCore",
            path: "Sources/DLLCCore"
        ),
        .executableTarget(
            name: "DLLC",
            dependencies: ["DLLCCore"],
            path: "Sources/DLLC",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DLLCCoreTests",
            dependencies: ["DLLCCore"],
            path: "Tests/DLLCCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
