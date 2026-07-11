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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.24/DoorbellSDK_1_0_24.zip",
            checksum: "739c49c7cc81409c147d77af87e5d893fec1d62538a707ed3d0328f8e65842a5"
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
