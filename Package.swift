// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "DoorbellSDK",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "DoorbellSDK",
            targets: ["DoorbellSDK"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "DoorbellSDK",
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.3/DoorbellSDK.zip",
            checksum: "de4730a3d550389d2b1539327893998748177e448d41d8f0f21b7211e980917b"
        )
    ]
)
