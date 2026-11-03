// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiDesign",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "KenshikiDesign", targets: ["KenshikiDesign"])],
    targets: [
        .target(
            name: "KenshikiDesign",
            path: "generated/swift",
            resources: [.process("en.lproj"), .process("en-XA.lproj"), .process("ar-XB.lproj")]
        ),
        .testTarget(name: "KenshikiDesignTests", dependencies: ["KenshikiDesign"], path: "tests/KenshikiDesignTests")
    ]
)
