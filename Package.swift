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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.10/DoorbellSDK_1_0_10.zip",
            checksum: "59b193b0168c4b15babefa5375c9d270bed83b6443278d3f71110074476401d2"
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
