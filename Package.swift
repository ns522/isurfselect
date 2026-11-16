// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SurfSelect",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "SurfSelectCore", targets: ["SurfSelectCore"]),
    ],
    targets: [
        .target(name: "SurfSelectCore"),
        .testTarget(name: "SurfSelectCoreTests", dependencies: ["SurfSelectCore"]),
    ]
)
