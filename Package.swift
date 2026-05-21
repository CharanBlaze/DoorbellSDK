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
            url: "https://github.com/CharanBlaze/DoorbellSDK/releases/download/1.1.0/DoorbellSDK.zip",
            checksum: "f8ca0d3c8971bbfaf6a927713677d68f2f1d4db7102b3f1af1f5dcba0235ed2d"
        )
    ]
)
