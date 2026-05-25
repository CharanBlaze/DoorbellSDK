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

        .binaryTarget(
            name: "DoorbellSDK",
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.4/DoorbellSDK_1_0_4.zip",
            checksum: "a4571e3a465a699f0abb5edb223e7ada960e0e34a040de98dcb319d17ba50ef9"
        ),

        .target(
            name: "DoorbellSDKWrapper",
            dependencies: [
                "DoorbellSDK",
                .product(name: "WebRTC", package: "WebRTC")
            ]
        )
    ]
)
