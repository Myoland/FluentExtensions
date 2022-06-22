// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FluentExtensions",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "FluentExtensions",
            targets: ["FluentExtensions"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.16.0"),
    ],
    targets: [
        .target(
            name: "FluentExtensions",
            dependencies: [
                .product(name: "FluentKit", package: "fluent-kit"),
            ]),
        .testTarget(
            name: "FluentExtensionsTests",
            dependencies: ["FluentExtensions"]),
    ]
)
