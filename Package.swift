// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ISurfSelect",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "ISurfSelectCore", targets: ["ISurfSelectCore"]),
    ],
    targets: [
        .target(name: "ISurfSelectCore"),
        .testTarget(name: "ISurfSelectCoreTests", dependencies: ["ISurfSelectCore"]),
    ]
)
