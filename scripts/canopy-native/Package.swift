// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "canopy-native",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Canopy", targets: ["Canopy"]),
    ],
    targets: [
        // No UI: transport, event stream, store, models, router, keys, runner. Fully unit-tested.
        .target(name: "CanopyCore"),
        // SwiftUI shell, theme, and one folder per page area under Pages/.
        .target(
            name: "CanopyUI",
            dependencies: ["CanopyCore"],
            resources: [.copy("Resources/Fonts")]
        ),
        .executableTarget(name: "Canopy", dependencies: ["CanopyCore", "CanopyUI"]),
        .testTarget(
            name: "CanopyCoreTests",
            dependencies: ["CanopyCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CanopyUITests", dependencies: ["CanopyCore", "CanopyUI"]),
    ],
    swiftLanguageModes: [.v5]
)
