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
            url: "https://github.com/livekit/webrtc-xcframework.git",
            from: "144.7559.11"
        )
    ],
    targets: [
        .binaryTarget(
            name: "DoorbellSDK",
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.30/DoorbellSDK_1_0_30.zip",
            checksum: "210dba50995484f83b035121044d29c16773ba78a3e6044368c2f4de2fc51059"
        ),
        .target(
            name: "DoorbellSDKWrapper",
            dependencies: [
                "DoorbellSDK",
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")
            ],
            path: "Sources/DoorbellSDKWrapper"
        )
    ]
)
