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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.0.5/DoorbellSDK_1_0_5.zip",
            checksum: "9051031bcda26c9b29fadae564e8e55cfd44cce726cb56e5dffe79f110b7d4e9"
        )
    ]
)
