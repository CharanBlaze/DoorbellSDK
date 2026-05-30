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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.12/DoorbellSDK_1_0_12.zip",
            checksum: "7d3524558501c4c04fbcbde35d52956cba5e4f1e4c0ab78eb57a1936277992b9"
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
