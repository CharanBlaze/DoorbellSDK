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
            name: "DoorbellSDKBinary",
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.3/DoorbellSDK_1_0_3.zip",
            checksum: "9f06ebb9bbd4c56ffcfcd3972e9100af3b2d439f76035f585d0f3dfe33184dc2"
        ),

        .target(
            name: "DoorbellSDKWrapper",
            dependencies: [
                "DoorbellSDKBinary",
                .product(name: "WebRTC", package: "WebRTC")
            ]
        )
    ]
)
