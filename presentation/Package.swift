// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiPresentation",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "KenshikiPresentation", targets: ["KenshikiPresentation"])],
    targets: [
        .target(name: "KenshikiPresentation"),
        .testTarget(name: "KenshikiPresentationTests", dependencies: ["KenshikiPresentation"])
    ]
)
