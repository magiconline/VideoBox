// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VideoBox",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VideoBox", targets: ["VideoBox"])
    ],
    targets: [
        .executableTarget(
            name: "VideoBox",
            path: "Sources/VideoBox",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage")
            ]
        ),
        .testTarget(
            name: "VideoBoxTests",
            dependencies: ["VideoBox"],
            path: "Tests/VideoBoxTests"
        )
    ]
)
