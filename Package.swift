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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.6/DoorbellSDK_1_0_6.zip",
            checksum: "18dbe32cd00b4fad8c7c5c5276b38a241ccbb5c5fe8f79158c32dc5a1328a312"
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
