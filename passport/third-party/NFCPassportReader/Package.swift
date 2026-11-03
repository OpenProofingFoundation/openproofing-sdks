// swift-tools-version:5.4
// Vendored copy of AndyQ/NFCPassportReader 2.3.1 — see VENDORED.md for provenance and local patches.

import PackageDescription

let package = Package(
    name: "NFCPassportReader",
    platforms: [.iOS("15.0"), .macOS(.v10_15)],
    products: [
        .library(
            name: "NFCPassportReader",
            targets: ["NFCPassportReader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", .revision("71dbe0b4514cdaad95961470db72e8231f5943a6")),
    ],
    targets: [
        .target(
            name: "NFCPassportReader",
            dependencies: [
                .product(name: "OpenSSL", package: "OpenSSL-Package")
            ],
            resources: [
                .process("Resources")
            ]),
    ]
)
