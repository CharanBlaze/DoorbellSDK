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
            targets: ["DoorbellSDKWrapper"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/stasel/WebRTC.git",
            from: "147.0.0"
        )
    ],
    targets: [

        // Binary XCFramework
        .binaryTarget(
            name: "DoorbellSDK",
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.1/DoorbellSDK-1.0.1.zip",
            checksum: "52b51faa2833fe523e9219bdb2f7d5428f2f81f28a4957398a6fa6d8006dd978"
        ),

        // Wrapper target to expose dependencies
        .target(
            name: "DoorbellSDKWrapper",
            dependencies: [
                "DoorbellSDK",
                .product(name: "WebRTC", package: "WebRTC")
            ]
        )
    ]
)
