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
            ],
            linkerSettings: [
                // A command-line executable needs an embedded Info.plist for
                // macOS application-audio TCC attribution.  Keep this stable
                // across clean SwiftPM builds and development installs.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Distribution/Runtime-Embedded-Info.plist"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(name: "Sonexisctl"),
        .testTarget(name: "SonexisRuntimeTests", dependencies: ["SonexisRuntime"],
                    path: "Tests/RuntimeCapture")
    ]
)
