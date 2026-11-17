// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "show",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../canopy-native")],
    targets: [
        .executableTarget(
            name: "Show",
            dependencies: [.product(name: "CanopyUI", package: "canopy-native")],
            path: ".",
            exclude: ["Package.swift", "Tests"],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(name: "ShowTests", dependencies: ["Show"], path: "Tests/ShowTests"),
    ],
    swiftLanguageModes: [.v5]
)
