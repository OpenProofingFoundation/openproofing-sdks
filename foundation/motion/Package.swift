// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "KenshikiMotion",
  platforms: [.iOS(.v18), .macOS(.v13)],
  products: [.library(name: "KenshikiMotion", targets: ["KenshikiMotion"])],
  targets: [
    .target(name: "KenshikiMotion"),
    .testTarget(name: "KenshikiMotionTests", dependencies: ["KenshikiMotion"])
  ]
)
