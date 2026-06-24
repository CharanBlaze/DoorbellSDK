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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.17/DoorbellSDK_1_0_17.zip",
            checksum: "950d602dca8e72d91fc00dad862dafb51d517389facecdc19f9e07cbd5cb27b5"
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
