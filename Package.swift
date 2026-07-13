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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.24/DoorbellSDK_1_0_26.zip",
            checksum: "1bb1bafa6a77286978518804373c03a619cd55437e968124596cd875a5de2e3e"
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
