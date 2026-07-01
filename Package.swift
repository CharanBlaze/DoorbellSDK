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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.19/DoorbellSDK_1_0_19.zip",
            checksum: "5a5c126ad1d61ecf90089a65672d6e2eb0b13a40a882c1557d6eb8d57882c704"
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
