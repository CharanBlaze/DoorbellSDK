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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.15/DoorbellSDK_1_0_15.zip",
            checksum: "460e6c74f462cc0844000b1bfebdddaf33423826f2755a6405e7c008b94c322f"
        ),
        .target(
            name: "DoorbellSDKWrapper",
            dependencies: [
                "DoorbellSDK", 
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources/DoorbellSDKWrapper"
        )
    ]
)
