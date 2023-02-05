// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ToolsRunner",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "tools", targets: ["ToolsRunner"])
    ],
    targets: [
        .executableTarget(
            name: "ToolsRunner"
        )
    ]
)
