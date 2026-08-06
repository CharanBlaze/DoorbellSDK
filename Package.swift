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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.32/DoorbellSDK_1_0_32.zip",
            checksum: "a2e7f0bbda18ad903250e6927cc60332434162276221c66818379d71bf2aeb8f"
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
