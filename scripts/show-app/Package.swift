// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "show",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../canopy-native"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Show",
            dependencies: [
                .product(name: "CanopyUI", package: "canopy-native"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: ".",
            exclude: ["Package.swift", "Tests"],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(name: "ShowTests", dependencies: ["Show"], path: "Tests/ShowTests"),
    ],
    swiftLanguageModes: [.v5]
)
