// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiSensors",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "KenshikiSensors", targets: ["KenshikiSensors"])],
    targets: [
        .target(name: "KenshikiSensors"),
        .testTarget(
            name: "KenshikiSensorsTests",
            dependencies: ["KenshikiSensors"],
            resources: [.process("Fixtures")]
        ),
    ]
)
