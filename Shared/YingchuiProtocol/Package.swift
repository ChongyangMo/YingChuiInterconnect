// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YingchuiProtocol",
    platforms: [
        .iOS(.v17),
        .macOS(.v15)
    ],
    products: [
        .library(name: "YingchuiProtocol", targets: ["YingchuiProtocol"])
    ],
    targets: [
        .target(name: "YingchuiProtocol"),
        .testTarget(
            name: "YingchuiProtocolTests",
            dependencies: ["YingchuiProtocol"]
        )
    ]
)
