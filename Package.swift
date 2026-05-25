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

        // Binary XCFramework
        .binaryTarget(
            name: "DoorbellSDK",
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.2/DoorbellSDK_1_0_2.zip",
            checksum: "af0960e5a41f777a47822d8eb5ff9561733b686869642926b104fd450acb417b"
        ),

        // Wrapper target to expose dependencies
        .target(
            name: "DoorbellSDKWrapper",
            dependencies: [
                "DoorbellSDK",
                .product(name: "WebRTC", package: "WebRTC")
            ]
        )
    ]
)
