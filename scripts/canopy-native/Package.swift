// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "canopy-native",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Canopy", targets: ["Canopy"]),
        .library(name: "CanopyUI", targets: ["CanopyUI", "CanopyCore"]),
    ],
    // a terminal for Helix in the diff's new half (1.99 doesn't build with Swift 6.2)
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")],
    targets: [
        // No UI: transport, event stream, store, models, router, keys, runner. Fully unit-tested.
        .target(name: "CanopyCore"),
        // SwiftUI shell, theme, and one folder per page area under Pages/.
        .target(
            name: "CanopyUI",
            dependencies: ["CanopyCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Resources/Fonts")]
        ),
        .executableTarget(name: "Canopy", dependencies: ["CanopyCore", "CanopyUI"]),
        .testTarget(
            name: "CanopyCoreTests",
            dependencies: ["CanopyCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CanopyUITests", dependencies: ["CanopyCore", "CanopyUI"]),
    ],
    swiftLanguageModes: [.v5]
)
