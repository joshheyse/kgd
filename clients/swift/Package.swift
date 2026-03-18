// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KgdClient",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "KgdClient", targets: ["KgdClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/a2/MessagePack.swift.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "KgdClient",
            dependencies: [
                .product(name: "MessagePack", package: "MessagePack.swift"),
            ]
        ),
        .testTarget(
            name: "KgdClientTests",
            dependencies: ["KgdClient"]
        ),
    ]
)
