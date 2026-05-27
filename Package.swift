// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "DoorbellSDK",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "DoorbellSDK",
            targets: ["DoorbellSDKWrapper"] // Clients will link to this wrapper
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/stasel/WebRTC.git",
            from: "147.0.0"
        )
    ],
    targets: [
        // 1. The precompiled binary target.
        // This name must exactly match the name of the .xcframework folder inside your zip.
        .binaryTarget(
            name: "DoorbellSDK",
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.8/DoorbellSDK_1_0_8.zip",
            checksum: "cd55a7bbb8f71f576e1fbb8c568bdc687ae4e3692e073144e7a88de2f6d00f0c"
        ),
        // 2. The wrapper target which glues your binary and WebRTC together.
        .target(
            name: "DoorbellSDKWrapper",
            dependencies: [
                "DoorbellSDK", // References the binary target above
                .product(name: "WebRTC", package: "WebRTC") // References the WebRTC dependency
            ],
            path: "Sources/DoorbellSDKWrapper" // Explicit path for the wrapper
        )
    ]
)
