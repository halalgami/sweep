// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .executable(name: "sweep", targets: ["sweep"]),
        .executable(name: "SweepAgent", targets: ["SweepAgent"]),
    ],
    targets: [
        .target(
            name: "SweepCore",
            resources: [.copy("Resources/rules.json")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "sweep", dependencies: ["SweepCore"]),
        .executableTarget(name: "SweepAgent", dependencies: ["SweepCore"]),
        .testTarget(
            name: "SweepCoreTests",
            dependencies: ["SweepCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
