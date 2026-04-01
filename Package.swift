// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SFmpeg",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SFmpeg",
            targets: ["SFmpeg"]
        ),
    ],
    targets: [
        // 1. Binary target for the xcframework
        .binaryTarget(
            name: "FFmpeg",
            path: "Frameworks/FFmpeg.xcframework.zip"
        ),

        // 2. C headers
        .target(
            name: "CFFmpeg",
            dependencies: ["FFmpeg"],
            cSettings: [
                .headerSearchPath("include"),
                .define("__STDC_CONSTANT_MACROS"),
            ],
            linkerSettings: [
                .linkedFramework("FFmpeg")
            ]
        ),

        // 3. the main Swift module
        .target(
            name: "SFmpeg",
            dependencies: ["CFFmpeg"]
        ),

        .testTarget(
            name: "SFmpegTests",
            dependencies: ["SFmpeg"]
        ),
    ]
)
