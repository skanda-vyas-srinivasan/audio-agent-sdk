// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SonexisRuntime",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "sonexis-runtime", targets: ["SonexisRuntime"]),
        .executable(name: "sonexisctl", targets: ["Sonexisctl"])
    ],
    dependencies: [
        .package(path: "SonexisAudioEngine")
    ],
    targets: [
        .executableTarget(
            name: "SonexisRuntime",
            dependencies: [
                .product(name: "SonexisAudioEngine", package: "SonexisAudioEngine")
            ]
        ),
        .executableTarget(name: "Sonexisctl")
    ]
)
