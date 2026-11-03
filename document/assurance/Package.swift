// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DocumentRetainedReplayAssurance",
  platforms: [.macOS(.v13)],
  dependencies: [.package(path: "..")],
  targets: [
    .testTarget(
      name: "RetainedReplayTests",
      dependencies: [.product(name: "DocumentCaptureApple", package: "document")])
  ])
