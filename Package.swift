// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoxType",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoxType", targets: ["VoxTypeApp"])
    ],
    targets: [
        .target(
            name: "CGZip",
            path: "Sources/CGZip",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "VoxTypeCore",
            dependencies: ["CGZip"],
            path: "Sources/VoxTypeCore"
        ),
        .executableTarget(
            name: "VoxTypeApp",
            dependencies: ["VoxTypeCore"],
            path: "Sources/VoxTypeApp"
        ),
        .testTarget(
            name: "VoxTypeCoreTests",
            dependencies: ["VoxTypeCore"],
            path: "Tests/VoxTypeCoreTests"
        )
    ]
)
