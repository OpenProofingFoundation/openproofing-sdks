// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SensorsConsumer",
  platforms: [.macOS(.v13)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "SensorsConsumer",
      dependencies: [.product(name: "KenshikiSensors", package: "sensors")]
    )
  ]
)
