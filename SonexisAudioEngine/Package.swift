// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SonexisAudioEngine",
    platforms: [.macOS("14.4")],
    products: [
        .library(
            name: "SonexisAudioEngine",
            type: .static,
            targets: ["SonexisAudioEngine", "SonexisAudioEngineC"]
        )
    ],
    targets: [
        .target(name: "SonexisAudioEngineC"),
        .target(
            name: "SonexisAudioEngine",
            dependencies: ["SonexisAudioEngineC"]
        ),
        .testTarget(
            name: "SonexisAudioEngineTests",
            dependencies: ["SonexisAudioEngine"]
        )
    ]
)
